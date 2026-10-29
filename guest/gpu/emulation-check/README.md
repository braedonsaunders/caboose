# Offscreen Vulkan feature checks

`run.py` compiles five small shaders, validates their SPIR-V, builds one renderer and
checks actual128×64 RGBA8 image readbacks against `expected.json`. It links an explicitly
selected, SHA256-verified macOS arm64 MoltenVK archive. It does not create a window or
swapchain, change a profile, or launch Steam or a game.

Requirements: Xcode, Python3, Vulkan-Headers, `glslangValidator`, `spirv-val`, and the
macOS arm64 `libMoltenVK.a` from the GPU stream player's pinned release. No dependency
is downloaded or installed. Run one compiler job at a time:

```sh
python3 guest/gpu/emulation-check/run.py \
  --headers /path/to/Vulkan-Headers/include \
  --moltenvk /path/to/macos/libMoltenVK.a \
  --moltenvk-sha256 THE_VERIFIED_ARCHIVE_SHA256 \
  --output /tmp/caboose-offscreen-check
```

The output directory must be new. `--developer-dir` selects Xcode; `--case` selects one
or more named cases. The runner rejects Vulkan, MoltenVK and capture environment
overrides. Its renderer uses the first physical device and records its name and features.
Each native renderer is a separate owned process group, bounded to15seconds; its fence
wait is5seconds. A timeout kills and reaps only that process group. Builds are serial,
with30second shader-tool bounds and a60second native compile/link bound.

`results.json` records inputs, exact commands, elapsed times and each expected/actual
sample. A rendered case also writes raw tightly packed `.rgba` and a `.ppm` of that
readback. Per-case stdout/stderr logs retain driver diagnostics. The runner returns
nonzero for a compile, render, timeout or sample failure. **UNSUPPORTED is separate from
PASS:** a suite with unsupported cases does not establish those features work.

| Case | Required feature | Expected result |
| --- | --- | --- |
| `control` | None beyond basic graphics | Both triangles green, gap black |
| `cull_mixed_sign` | `shaderCullDistance` | Whole mixed-sign left triangle green; all-negative right triangle absent |
| `geometry_direct` | `geometryShader` | Offscreen point becomes an onscreen blue triangle |
| `geometry_indirect` | `geometryShader` | Same triangle through an indirect draw |
| `geometry_indexed_indirect` | `geometryShader` | Same triangle through an indexed indirect draw |

Features are queried before device/pipeline creation. An absent required feature yields
exit77 and an UNSUPPORTED report without a readback. Only the features actually required
by that case are enabled. The source contains no feature override or unsupported-feature
removal. It uses explicit render-pass/transfer/host synchronization, flushes upload
memory, waits for the fence, invalidates readback memory, and destroys owned Vulkan
objects before exit. All samples use positive Vulkan viewport/image row coordinates;
they are interior pixels, not edge-coverage tests.

## Semantic boundary

The cull test uses distances[-1e30,+1,+1] for one triangle. Vulkan retains that whole
primitive: it culls only when a cull half-space is negative at every vertex. Mapping those
values to clip distances clips a partially negative primitive instead and is incorrect.
See [CullDistance](https://docs.vulkan.org/refpages/latest/refpages/source/CullDistance.html).

The excluded [Metalsharp SPIRV-Cross patch at8504cc0](https://github.com/metalsharp/VKD3D-Proton-MacOS/blob/8504cc001c092f902ae03209ae9302a6f80bea8d/patches/spirv-cross/metalsharp.diff)
replaces nonnegative cull values with1e20 and uses clip distances. The large negative
value in this fixture makes that approximation visibly fail at the green interior samples.

[UTM MoltenVK atb5680e3](https://github.com/utmapp/MoltenVK/blob/b5680e33d7dca891667adea0b4c35ffe905d1a66/MoltenVK/MoltenVK/Commands/MVKCmdDraw.mm)
has geometry-shader handling for direct draws but explicitly rejects indirect and indexed
indirect geometry draws. The three cases remain separate; passing direct geometry is not
proof of indirect support. This runner neither builds nor selects that fork automatically.

Offscreen Mac results do not establish phone presentation, GFXReconstruct replay,
Halo shader compatibility, or Vulkan conformance. Those require their own checks.
