// d3d11_stress: a multi-threaded D3D11 load for the DXVK check (deferred contexts on worker
// threads, many descriptor sets per frame, dynamic constant buffers, per-frame resource churn,
// copies into staging buffers read back on the CPU, occlusion and timestamp queries).
//
//   d3d11_stress.exe [SECONDS] [THREADS] [DRAWS_PER_THREAD]
//
// Prints "frames=N fps=F" every 5 s and "done frames=N" at the end, and "FAIL …" for a failed
// call or a wrong readback. Build it with MinGW-w64 and run it with check-dxvk.sh (APP):
//
//   x86_64-w64-mingw32-g++-posix -O2 -std=c++17 -static -o d3d11_stress.exe d3d11-stress.cpp \
//       -ld3d11 -ld3dcompiler -ldxgi
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static const char kShader[] = R"(
cbuffer Draw : register(b0) { float4 offset; float4 tint; };
cbuffer Frame : register(b1) { float4 time; };
Texture2D t0 : register(t0); Texture2D t1 : register(t1); Texture2D t2 : register(t2);
SamplerState s0 : register(s0); SamplerState s1 : register(s1);
struct V { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
V vs(uint id : SV_VertexID) {
  V o; float2 p = float2((id << 1) & 2, id & 2);
  o.uv = p; o.pos = float4(p * 0.1 + offset.xy - 1.0, 0.5, 1.0); return o;
}
float4 ps(V i) : SV_TARGET {
  return tint * t0.Sample(s0, i.uv) + t1.Sample(s1, i.uv) * 0.5 + t2.Sample(s0, i.uv.yx) * time.x;
}
RWByteAddressBuffer outb : register(u0);
[numthreads(64,1,1)] void cs(uint3 id : SV_DispatchThreadID) { outb.Store(id.x * 4, id.x + asuint(time.y)); }
)";

#define CHECK(x) do { HRESULT hr_ = (x); if (FAILED(hr_)) { std::printf("FAIL %s: 0x%08lx (line %d)\n", #x, (unsigned long)hr_, __LINE__); std::fflush(stdout); ExitProcess(2); } } while (0)

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM a, LPARAM b) { return DefWindowProcA(w, m, a, b); }

static ID3DBlob* compile(const char* entry, const char* target) {
  ID3DBlob* code = nullptr; ID3DBlob* errors = nullptr;
  HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "stress", nullptr, nullptr, entry, target, 0, 0, &code, &errors);
  if (FAILED(hr)) { std::printf("FAIL compile %s: %s\n", entry, errors ? (const char*)errors->GetBufferPointer() : "?"); std::fflush(stdout); ExitProcess(2); }
  return code;
}

int main(int argc, char** argv) {
  const int seconds = argc > 1 ? std::atoi(argv[1]) : 60;
  const int threads = argc > 2 ? std::atoi(argv[2]) : 8;
  const int draws = argc > 3 ? std::atoi(argv[3]) : 200;
  WNDCLASSA wc = {}; wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(nullptr); wc.lpszClassName = "stress";
  RegisterClassA(&wc);
  HWND window = CreateWindowA("stress", "D3D11 stress", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 640, 480, nullptr, nullptr, wc.hInstance, nullptr);
  DXGI_SWAP_CHAIN_DESC sd = {};
  sd.BufferCount = 2; sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 480;
  sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  sd.OutputWindow = window; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
  IDXGISwapChain* swap = nullptr; ID3D11Device* dev = nullptr; ID3D11DeviceContext* imm = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  CHECK(D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1, D3D11_SDK_VERSION, &sd, &swap, &dev, nullptr, &imm));
  ID3DBlob* vsb = compile("vs", "vs_5_0"); ID3DBlob* psb = compile("ps", "ps_5_0"); ID3DBlob* csb = compile("cs", "cs_5_0");
  ID3D11VertexShader* vs; ID3D11PixelShader* ps; ID3D11ComputeShader* cs;
  CHECK(dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs));
  CHECK(dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &ps));
  CHECK(dev->CreateComputeShader(csb->GetBufferPointer(), csb->GetBufferSize(), nullptr, &cs));
  // A set of textures the draws pick from, so every draw binds a different combination.
  const int kTextures = 24;
  std::vector<ID3D11ShaderResourceView*> srvs(kTextures);
  for (int i = 0; i < kTextures; ++i) {
    D3D11_TEXTURE2D_DESC td = {}; td.Width = td.Height = 16 << (i % 3); td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    std::vector<uint32_t> px(td.Width * td.Height, 0xff000000u | (i * 0x0a0b0c));
    D3D11_SUBRESOURCE_DATA init = { px.data(), td.Width * 4, 0 };
    ID3D11Texture2D* t; CHECK(dev->CreateTexture2D(&td, &init, &t));
    CHECK(dev->CreateShaderResourceView(t, nullptr, &srvs[i])); t->Release();
  }
  ID3D11SamplerState* samplers[4];
  for (int i = 0; i < 4; ++i) {
    D3D11_SAMPLER_DESC ss = {}; ss.Filter = i & 1 ? D3D11_FILTER_MIN_MAG_MIP_POINT : D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    ss.AddressU = ss.AddressV = ss.AddressW = i & 2 ? D3D11_TEXTURE_ADDRESS_CLAMP : D3D11_TEXTURE_ADDRESS_WRAP; ss.MaxLOD = D3D11_FLOAT32_MAX;
    CHECK(dev->CreateSamplerState(&ss, &samplers[i]));
  }
  D3D11_BUFFER_DESC fb = {}; fb.ByteWidth = 16; fb.Usage = D3D11_USAGE_DYNAMIC; fb.BindFlags = D3D11_BIND_CONSTANT_BUFFER; fb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  ID3D11Buffer* frameCb; CHECK(dev->CreateBuffer(&fb, nullptr, &frameCb));
  std::vector<ID3D11DeviceContext*> deferred(threads);
  std::vector<ID3D11Buffer*> drawCb(threads);
  for (int t = 0; t < threads; ++t) {
    CHECK(dev->CreateDeferredContext(0, &deferred[t]));
    D3D11_BUFFER_DESC cb = fb; cb.ByteWidth = 32; CHECK(dev->CreateBuffer(&cb, nullptr, &drawCb[t]));
  }
  D3D11_BUFFER_DESC ub = {}; ub.ByteWidth = 64 * 64 * 4; ub.Usage = D3D11_USAGE_DEFAULT; ub.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
  ub.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
  ID3D11Buffer* uav; CHECK(dev->CreateBuffer(&ub, nullptr, &uav));
  D3D11_UNORDERED_ACCESS_VIEW_DESC ud = {}; ud.Format = DXGI_FORMAT_R32_TYPELESS; ud.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
  ud.Buffer.NumElements = 64 * 64; ud.Buffer.Flags = D3D11_BUFFER_UAV_FLAG_RAW;
  ID3D11UnorderedAccessView* uavView; CHECK(dev->CreateUnorderedAccessView(uav, &ud, &uavView));
  const int kStaging = 3;
  ID3D11Buffer* staging[kStaging];
  for (int i = 0; i < kStaging; ++i) {
    D3D11_BUFFER_DESC sb = {}; sb.ByteWidth = ub.ByteWidth; sb.Usage = D3D11_USAGE_STAGING; sb.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    CHECK(dev->CreateBuffer(&sb, nullptr, &staging[i]));
  }
  D3D11_QUERY_DESC qd = { D3D11_QUERY_OCCLUSION, 0 };
  ID3D11Query* occlusion[kStaging]; for (auto& q : occlusion) CHECK(dev->CreateQuery(&qd, &q));
  ID3D11Texture2D* back; CHECK(swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back));
  ID3D11RenderTargetView* rtv; CHECK(dev->CreateRenderTargetView(back, nullptr, &rtv)); back->Release();
  D3D11_VIEWPORT vp = { 0, 0, 640, 480, 0, 1 };

  std::vector<ID3D11CommandList*> lists(threads);
  std::atomic<int> frame{-1}, done{0};
  std::atomic<bool> stop{false};
  std::vector<std::thread> workers;
  for (int t = 0; t < threads; ++t) workers.emplace_back([&, t] {
    int seen = -1;
    while (!stop) {
      int f = frame.load();
      if (f == seen) { Sleep(0); continue; }
      seen = f;
      ID3D11DeviceContext* c = deferred[t];
      c->OMSetRenderTargets(1, &rtv, nullptr); c->RSSetViewports(1, &vp);
      c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
      c->VSSetShader(vs, nullptr, 0); c->PSSetShader(ps, nullptr, 0);
      c->PSSetConstantBuffers(1, 1, &frameCb);
      for (int d = 0; d < draws; ++d) {
        D3D11_MAPPED_SUBRESOURCE m;
        if (FAILED(c->Map(drawCb[t], 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) { std::printf("FAIL map\n"); ExitProcess(2); }
        float* p = (float*)m.pData; p[0] = (d % 20) * 0.1f; p[1] = (t * 3 + d / 20) * 0.08f; p[2] = p[3] = 0; p[4] = 1; p[5] = t / 8.0f; p[6] = d / 200.0f; p[7] = 1;
        c->Unmap(drawCb[t], 0);
        c->VSSetConstantBuffers(0, 1, &drawCb[t]); c->PSSetConstantBuffers(0, 1, &drawCb[t]);
        ID3D11ShaderResourceView* views[3] = { srvs[(d + t) % kTextures], srvs[(d * 7 + f) % kTextures], srvs[(d * 13 + t * 5) % kTextures] };
        c->PSSetShaderResources(0, 3, views);
        ID3D11SamplerState* ss[2] = { samplers[d & 3], samplers[(d >> 2) & 3] };
        c->PSSetSamplers(0, 2, ss);
        c->Draw(3, 0);
      }
      if (FAILED(c->FinishCommandList(FALSE, &lists[t]))) { std::printf("FAIL finish\n"); ExitProcess(2); }
      done.fetch_add(1);
    }
  });

  const DWORD start = GetTickCount(); DWORD last = start; int frames = 0, lastFrames = 0;
  while (GetTickCount() - start < DWORD(seconds) * 1000) {
    MSG msg; while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
    D3D11_MAPPED_SUBRESOURCE m; CHECK(imm->Map(frameCb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m));
    ((float*)m.pData)[0] = (frames % 60) / 60.0f; ((uint32_t*)m.pData)[1] = frames; imm->Unmap(frameCb, 0);
    const float clear[4] = { 0.1f, 0.2f, 0.3f, 1 };
    imm->ClearRenderTargetView(rtv, clear);
    done = 0; frame = frames;
    // Per-frame churn the workers do not see: a texture made, sampled and dropped.
    D3D11_TEXTURE2D_DESC td = {}; td.Width = td.Height = 32; td.MipLevels = 1; td.ArraySize = 1; td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D* churn; CHECK(dev->CreateTexture2D(&td, nullptr, &churn));
    ID3D11ShaderResourceView* churnView; CHECK(dev->CreateShaderResourceView(churn, nullptr, &churnView));
    imm->CSSetShader(cs, nullptr, 0); imm->CSSetConstantBuffers(1, 1, &frameCb);
    imm->CSSetUnorderedAccessViews(0, 1, &uavView, nullptr); imm->Dispatch(64, 1, 1);
    ID3D11UnorderedAccessView* none = nullptr; imm->CSSetUnorderedAccessViews(0, 1, &none, nullptr);
    const int slot = frames % kStaging;
    imm->CopyResource(staging[slot], uav);
    imm->Begin(occlusion[slot]);
    while (done.load() < threads) Sleep(0);
    for (int t = 0; t < threads; ++t) { imm->ExecuteCommandList(lists[t], FALSE); lists[t]->Release(); lists[t] = nullptr; }
    imm->OMSetRenderTargets(1, &rtv, nullptr); imm->RSSetViewports(1, &vp);
    imm->PSSetShaderResources(0, 1, &churnView); imm->Draw(3, 0);
    imm->End(occlusion[slot]);
    churnView->Release(); churn->Release();
    CHECK(swap->Present(0, 0));
    ++frames;
    // Read back the oldest staging copy and query (the CPU waits for the GPU here).
    if (frames >= kStaging) {
      const int old = frames % kStaging;
      D3D11_MAPPED_SUBRESOURCE r; CHECK(imm->Map(staging[old], 0, D3D11_MAP_READ, 0, &r));
      const uint32_t expect = 5u + uint32_t(frames - kStaging);
      const uint32_t got = ((uint32_t*)r.pData)[5];
      imm->Unmap(staging[old], 0);
      if (got != expect) { std::printf("FAIL readback frame %d: %u != %u\n", frames, got, expect); std::fflush(stdout); }
      UINT64 samples = 0; while (imm->GetData(occlusion[old], &samples, sizeof(samples), 0) == S_FALSE) Sleep(0);
    }
    const DWORD now = GetTickCount();
    if (now - last >= 5000) { std::printf("frames=%d fps=%.2f\n", frames, (frames - lastFrames) * 1000.0 / (now - last)); std::fflush(stdout); last = now; lastFrames = frames; }
  }
  stop = true; frame = -2;
  for (auto& w : workers) w.join();
  std::printf("done frames=%d\n", frames); std::fflush(stdout);
  return 0;
}
