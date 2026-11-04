// ue_load: what a D3D11 engine does while it loads a level, as Unreal Engine 4 titles do, in
// timed phases, each ended by waiting for the GPU (an event query):
//
//   hlsl       compiles SHADERS distinct vertex and pixel shader pairs (D3DCompile; an engine
//              ships them compiled, so this phase only prepares the next)
//   shaders    creates the shaders and their input layouts
//   uploads    creates TEXTURES textures of SIZE x SIZE with full mip chains and contents of
//              their own, and 32 MiB of immutable vertex and index buffers
//   pipelines  draws a loading screen: each frame first uses PER_FRAME new shader pairs, each
//              with a blend and rasterizer state of its own, until every pair has drawn
//   steady     draws 60 frames that use every pair again
//
//   ue_load.exe [SHADERS] [TEXTURES] [SIZE] [PER_FRAME]
//
// Prints "phase NAME ms=…" for each phase (pipelines also frames= and worst_frame_ms=), then
// "done total_ms=…", and "FAIL …" for a failed call. Build it with MinGW-w64 and run it with
// readback_profile.py (README.md, "GPU load at a phone's round-trip time"):
//
//   x86_64-w64-mingw32-g++-posix -O2 -std=c++17 -static -o ue_load.exe ue-load.cpp \
//       -ld3d11 -ld3dcompiler -ldxgi
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#define CHECK(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) { std::printf("FAIL %s: 0x%08lx (line %d)\n", #x, (unsigned long)hr_, __LINE__); std::fflush(stdout); ExitProcess(2); } } while (0)

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM a, LPARAM b) { return DefWindowProcA(w, m, a, b); }

static double nowMs() {
  static LARGE_INTEGER frequency = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f; }();
  LARGE_INTEGER t; QueryPerformanceCounter(&t);
  return double(t.QuadPart) * 1000.0 / double(frequency.QuadPart);
}

// A shader pair of its own: a vertex shader of the engine's usual shape, and a pixel shader
// that samples four textures and does an amount of arithmetic of its own.
static std::string source(int variant) {
  char head[512];
  std::snprintf(head, sizeof head,
    "cbuffer View : register(b0) { float4x4 viewProjection; float4 tint; };\n"
    "Texture2D t0 : register(t0); Texture2D t1 : register(t1); Texture2D t2 : register(t2); Texture2D t3 : register(t3);\n"
    "SamplerState s0 : register(s0); SamplerState s1 : register(s1);\n"
    "struct A { float3 pos : POSITION; float2 uv : TEXCOORD0; float3 normal : NORMAL; };\n"
    "struct V { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float3 normal : NORMAL; };\n"
    "static const float k = %d.0 / 977.0;\n", variant);
  std::string s = head;
  s += "V vs(A a) { V o; o.pos = mul(viewProjection, float4(a.pos * (1.0 + k), 1.0)); o.uv = a.uv + k; o.normal = a.normal; return o; }\n";
  s += "float4 ps(V i) : SV_TARGET {\n"
       "  float4 c = t0.Sample(s0, i.uv) * tint + t1.Sample(s1, i.uv * 2.0) * k;\n";
  const int steps = 4 + variant % 13;
  for (int step = 0; step < steps; ++step) {
    char line[256];
    std::snprintf(line, sizeof line,
      "  c = c * float4(%d.1, 0.9, 1.1, 1.0) * 0.25 + sin(c.yzwx * %d.3 + k) * 0.5 + t%d.Sample(s%d, i.uv + c.xy * 0.01);\n",
      1 + (variant + step) % 7, 1 + step, (variant + step) % 4, step % 2);
    s += line;
  }
  s += "  return c * saturate(dot(normalize(i.normal), float3(0.3, 0.8, 0.5)));\n}\n";
  return s;
}

static ID3DBlob* compile(const std::string& text, const char* entry, const char* target) {
  ID3DBlob* code = nullptr; ID3DBlob* errors = nullptr;
  HRESULT hr = D3DCompile(text.data(), text.size(), "load", nullptr, nullptr, entry, target,
                          D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
  if (FAILED(hr)) { std::printf("FAIL compile %s: %s\n", entry, errors ? (const char*)errors->GetBufferPointer() : "?"); std::fflush(stdout); ExitProcess(2); }
  return code;
}

int main(int argc, char** argv) {
  const int shaders = argc > 1 ? std::atoi(argv[1]) : 1200;
  const int textures = argc > 2 ? std::atoi(argv[2]) : 96;
  const int size = argc > 3 ? std::atoi(argv[3]) : 512;
  const int perFrame = argc > 4 ? std::atoi(argv[4]) : 40;
  const double start = nowMs();
  WNDCLASSA wc = {}; wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "load";
  RegisterClassA(&wc);
  HWND window = CreateWindowA("load", "D3D11 load", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 640, 480, nullptr, nullptr, wc.hInstance, nullptr);
  DXGI_SWAP_CHAIN_DESC sd = {};
  sd.BufferCount = 2; sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 480;
  sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  sd.OutputWindow = window; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  IDXGISwapChain* swap = nullptr; ID3D11Device* dev = nullptr; ID3D11DeviceContext* imm = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  CHECK(D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1, D3D11_SDK_VERSION, &sd, &swap, &dev, nullptr, &imm));
  std::printf("phase device ms=%.0f\n", nowMs() - start); std::fflush(stdout);

  D3D11_QUERY_DESC qd = { D3D11_QUERY_EVENT, 0 };
  ID3D11Query* event; CHECK(dev->CreateQuery(&qd, &event));
  auto finish = [&] {
    imm->End(event);
    BOOL done = FALSE;
    while (imm->GetData(event, &done, sizeof done, 0) != S_OK) Sleep(0);
  };
  auto phase = [&](const char* name, double since) {
    std::printf("phase %s ms=%.0f\n", name, nowMs() - since); std::fflush(stdout);
  };

  double t = nowMs();
  std::vector<ID3DBlob*> vsCode(shaders), psCode(shaders);
  for (int i = 0; i < shaders; ++i) {
    const std::string text = source(i);
    vsCode[i] = compile(text, "vs", "vs_5_0");
    psCode[i] = compile(text, "ps", "ps_5_0");
  }
  phase("hlsl", t);

  t = nowMs();
  std::vector<ID3D11VertexShader*> vs(shaders);
  std::vector<ID3D11PixelShader*> ps(shaders);
  std::vector<ID3D11InputLayout*> layouts(shaders);
  const D3D11_INPUT_ELEMENT_DESC elements[] = {
    {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
    {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 20, D3D11_INPUT_PER_VERTEX_DATA, 0},
  };
  for (int i = 0; i < shaders; ++i) {
    CHECK(dev->CreateVertexShader(vsCode[i]->GetBufferPointer(), vsCode[i]->GetBufferSize(), nullptr, &vs[i]));
    CHECK(dev->CreatePixelShader(psCode[i]->GetBufferPointer(), psCode[i]->GetBufferSize(), nullptr, &ps[i]));
    CHECK(dev->CreateInputLayout(elements, 3, vsCode[i]->GetBufferPointer(), vsCode[i]->GetBufferSize(), &layouts[i]));
  }
  finish();
  phase("shaders", t);

  t = nowMs();
  uint64_t uploaded = 0;
  std::vector<ID3D11ShaderResourceView*> views(textures > 4 ? textures : 4);
  uint32_t seed = 12345;
  auto next = [&seed] { seed = seed * 1664525u + 1013904223u; return seed; };
  for (size_t i = 0; i < views.size(); ++i) {
    D3D11_TEXTURE2D_DESC td = {}; td.Width = td.Height = size; td.MipLevels = 0; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    int levels = 0; for (int s = size; s; s >>= 1) ++levels;
    std::vector<std::vector<uint32_t>> pixels(levels);
    std::vector<D3D11_SUBRESOURCE_DATA> init(levels);
    for (int l = 0; l < levels; ++l) {
      const int edge = size >> l > 0 ? size >> l : 1;
      pixels[l].resize(size_t(edge) * edge);
      for (auto& p : pixels[l]) p = next();
      init[l] = { pixels[l].data(), UINT(edge * 4), 0 };
      uploaded += pixels[l].size() * 4;
    }
    td.MipLevels = levels;
    ID3D11Texture2D* texture; CHECK(dev->CreateTexture2D(&td, init.data(), &texture));
    CHECK(dev->CreateShaderResourceView(texture, nullptr, &views[i])); texture->Release();
  }
  const UINT vertices = 1 << 20;  // 32 bytes each: 32 MiB with the indices below
  std::vector<float> vertexData(size_t(vertices) * 8);
  // Small triangles, as a scene's are: the load is the engine's, not the rasterizer's.
  float cx = 0, cy = 0;
  for (size_t v = 0; v < vertices; ++v) {
    float* p = &vertexData[v * 8];
    if (v % 3 == 0) { cx = float(int(next() % 1801) - 900) / 1000.0f; cy = float(int(next() % 1801) - 900) / 1000.0f; }
    p[0] = cx + float(next() % 100) / 2000.0f; p[1] = cy + float(next() % 100) / 2000.0f; p[2] = 0.5f;
    p[3] = float(next() % 1000) / 1000.0f; p[4] = float(next() % 1000) / 1000.0f; p[5] = 0; p[6] = 0; p[7] = 1;
  }
  D3D11_BUFFER_DESC vb = {}; vb.ByteWidth = vertices * 32; vb.Usage = D3D11_USAGE_IMMUTABLE; vb.BindFlags = D3D11_BIND_VERTEX_BUFFER;
  D3D11_SUBRESOURCE_DATA vinit = { vertexData.data(), 0, 0 };
  ID3D11Buffer* vertexBuffer; CHECK(dev->CreateBuffer(&vb, &vinit, &vertexBuffer));
  uploaded += vb.ByteWidth;
  finish();
  std::printf("phase uploads ms=%.0f bytes=%llu\n", nowMs() - t, (unsigned long long)uploaded); std::fflush(stdout);

  ID3D11SamplerState* samplers[2];
  for (int i = 0; i < 2; ++i) {
    D3D11_SAMPLER_DESC ss = {}; ss.Filter = i ? D3D11_FILTER_MIN_MAG_MIP_POINT : D3D11_FILTER_ANISOTROPIC; ss.MaxAnisotropy = 8;
    ss.AddressU = ss.AddressV = ss.AddressW = i ? D3D11_TEXTURE_ADDRESS_CLAMP : D3D11_TEXTURE_ADDRESS_WRAP; ss.MaxLOD = D3D11_FLOAT32_MAX;
    CHECK(dev->CreateSamplerState(&ss, &samplers[i]));
  }
  ID3D11BlendState* blends[4];
  for (int i = 0; i < 4; ++i) {
    D3D11_BLEND_DESC bd = {}; bd.RenderTarget[0].BlendEnable = i != 0;
    bd.RenderTarget[0].SrcBlend = i == 2 ? D3D11_BLEND_ONE : D3D11_BLEND_SRC_ALPHA;
    bd.RenderTarget[0].DestBlend = i == 3 ? D3D11_BLEND_ONE : D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD; bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO; bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    CHECK(dev->CreateBlendState(&bd, &blends[i]));
  }
  ID3D11RasterizerState* rasters[2];
  for (int i = 0; i < 2; ++i) {
    D3D11_RASTERIZER_DESC rd = {}; rd.FillMode = D3D11_FILL_SOLID; rd.CullMode = i ? D3D11_CULL_BACK : D3D11_CULL_NONE; rd.DepthClipEnable = TRUE;
    CHECK(dev->CreateRasterizerState(&rd, &rasters[i]));
  }
  D3D11_BUFFER_DESC cbd = {}; cbd.ByteWidth = 80; cbd.Usage = D3D11_USAGE_DYNAMIC; cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER; cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ID3D11Buffer* view; CHECK(dev->CreateBuffer(&cbd, nullptr, &view));
  ID3D11Texture2D* back; CHECK(swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back));
  ID3D11RenderTargetView* rtv; CHECK(dev->CreateRenderTargetView(back, nullptr, &rtv)); back->Release();
  D3D11_VIEWPORT vp = { 0, 0, 640, 480, 0, 1 };

  // One draw with pair `i`, in a state of its own.
  auto draw = [&](int i, int frame) {
    D3D11_MAPPED_SUBRESOURCE m; CHECK(imm->Map(view, 0, D3D11_MAP_WRITE_DISCARD, 0, &m));
    float* c = static_cast<float*>(m.pData);
    for (int e = 0; e < 16; ++e) c[e] = e % 5 == 0 ? 1.0f : 0.0f;
    c[16] = float(i % 7) / 7.0f; c[17] = float(frame % 11) / 11.0f; c[18] = 0.5f; c[19] = 1.0f;
    imm->Unmap(view, 0);
    imm->IASetInputLayout(layouts[i]);
    imm->VSSetShader(vs[i], nullptr, 0); imm->PSSetShader(ps[i], nullptr, 0);
    ID3D11ShaderResourceView* bound[4];
    for (int b = 0; b < 4; ++b) bound[b] = views[(size_t(i) * 4 + b) % views.size()];
    imm->PSSetShaderResources(0, 4, bound);
    imm->OMSetBlendState(blends[i % 4], nullptr, 0xffffffff);
    imm->RSSetState(rasters[(i / 4) % 2]);
    imm->Draw(3 * 64, UINT((size_t(i) * 3 * 64) % (vertices - 3 * 64)));
  };
  auto setup = [&] {
    imm->OMSetRenderTargets(1, &rtv, nullptr); imm->RSSetViewports(1, &vp);
    imm->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    const UINT stride = 32, offset = 0; imm->IASetVertexBuffers(0, 1, &vertexBuffer, &stride, &offset);
    imm->VSSetConstantBuffers(0, 1, &view); imm->PSSetConstantBuffers(0, 1, &view);
    imm->PSSetSamplers(0, 2, samplers);
    const float clear[4] = {0.1f, 0.1f, 0.2f, 1.0f}; imm->ClearRenderTargetView(rtv, clear);
  };

  t = nowMs();
  double worst = 0;
  int frames = 0;
  for (int first = 0; first < shaders; first += perFrame) {
    const double f = nowMs();
    setup();
    for (int i = first; i < first + perFrame && i < shaders; ++i) draw(i, frames);
    CHECK(swap->Present(0, 0));
    ++frames;
    const double took = nowMs() - f;
    if (took > worst) worst = took;
  }
  finish();
  std::printf("phase pipelines ms=%.0f frames=%d worst_frame_ms=%.0f\n", nowMs() - t, frames, worst); std::fflush(stdout);

  t = nowMs();
  for (int frame = 0; frame < 60; ++frame) {
    setup();
    for (int i = 0; i < shaders; i += 1 + shaders / 400) draw(i, frame);
    CHECK(swap->Present(0, 0));
  }
  finish();
  phase("steady", t);
  std::printf("done total_ms=%.0f\n", nowMs() - start); std::fflush(stdout);
  return 0;
}
