# Offscreen Vulkan feature checks

`run.py` compiles six small shaders, validates their SPIR-V, builds one renderer and
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
| `compute_indirect` | Graphics + compute queue; no optional feature bits | Compute generates the indirect command; both triangles green |
| `compute_cpu_feedback` | Graphics + compute queue; no optional feature bits | CPU reads and validates GPU output, derives a new indirect command; only right triangle green |

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

## GPU feedback boundary

The repository-owned `feedback.comp` shader uses the repository's AGPL-3.0 license.
It takes a 32-bit seed and writes five words: indirect draw arguments `[6,1,0,0]`
and cookie `seed ^ 0x6d2b79f5`. The runner chooses a fresh random seed whose low
two bits are 3 for each compute invocation, and checks the returned cookie against
that independently held challenge. Direct renderer invocations default to seed 19;
an optional final decimal argument supplies another seed. The output buffer starts
with zero draw arguments and a different cookie. `compute_indirect` uses a compute-write
to indirect-read barrier, then draws directly from that buffer in the same submission.
It requires no geometry shader, cull distance or GPU-to-CPU roundtrip before drawing.

`compute_cpu_feedback` submits compute first, waits for its fence (at most 5 seconds),
invalidates mapped memory and checks all five words. A missing, zero or stale result fails
before drawing. The CPU derives `[3,1,3,0]` from the observed result, writes and flushes
the buffer, then submits the draw. Rendering both triangles fails this case: only the
right triangle may remain. The report includes the words actually read by the CPU.
The final image still requires its own completed transfer and host readback.

These cases distinguish a GPU-only dependency from an application whose next command
depends on GPU data. Offline replay of a capture made on a real GPU can reproduce its
already-recorded CPU decision; that does **not** prove a live server application received
the phone's result. The current mock capture driver does not provide that return path.
Passing the feedback case on stock local MoltenVK establishes a reference, not a fix to
the remoting protocol or compatibility with an arbitrary game.

The acceptance oracle has pure negative tests (no driver, compiler or application):

```sh
python3 -m unittest discover -s guest/gpu/emulation-check -p test_verify.py -v
```

They reject zero results, a stale cookie (including a prior invocation's response), absent feedback, the unchanged two-triangle
image, an empty draw and a truncated readback. Their generated test bytes are never
used by the native runner and are not rendering evidence. Both compute cases are
selectable using `--case`; they do not modify the relay/player's separate vkcube fixture.

## Live client entry point

`CMakeLists.txt` defines a portable real-loader Vulkan executable and SPIR-V build
commands. It requires a Vulkan SDK, `glslangValidator`, `spirv-val`, CMake and a
C++20 compiler. It supports Linux Vulkan loaders, including Mesa lavapipe as a
software control.

```sh
cmake -S guest/gpu/emulation-check -B /absolute/private/acceptance-build -G Ninja
cmake --build /absolute/private/acceptance-build --parallel 1
python3 guest/gpu/emulation-check/run_live.py \
  --renderer /absolute/private/acceptance-build/caboose_vulkan_acceptance \
  --shaders /absolute/private/acceptance-build/shaders \
  --output /absolute/private/new-results
```

The live runner does not build or install anything. It runs the prebuilt client
with a fresh challenge and a 15-second bound per case. `--icd` selects an actual
driver manifest for that process; it does not change global registration. The
default case requires CPU feedback and a subsequent draw. The output records
binary and SPIR-V hashes, the issued challenge, returned words, image samples and
exit status. Capability-simulation and capture overrides are rejected.
For a Linux software control, pass `--icd /path/to/lvp_icd.json` and select
`--case control --case compute_indirect --case compute_cpu_feedback`. The ICD
manifest path depends on the Mesa installation. A software control does not
establish phone execution.

A client pass alone does not prove where its GPU work executed. Physical-phone
acceptance also requires independently matched executor/device evidence. The
experimental socket driver remains gated; this entry point does not enable it.
