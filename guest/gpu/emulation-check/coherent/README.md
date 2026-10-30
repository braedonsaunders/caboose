# Coherent mapped-memory litmus

This standalone Vulkan client tests a host-visible, host-coherent allocation on
one real Vulkan device. It uses no `vkFlushMappedMemoryRanges` or
`vkInvalidateMappedMemoryRanges`. It checks host writes consumed by a GPU copy,
GPU writes visible after a host-read barrier and fence, polling and a finite
fence timeout while a host-set Vulkan event holds the queue, and simultaneous
CPU/GPU writes to distinct words on the same mapped page. A later GPU copy
checks that the CPU update remains visible. Guard bytes catch unexpected writes.
The two threads of execution touch distinct bytes; the host event makes the
pending window deterministic.

Build with a C++17 compiler, CMake, and Vulkan headers and loader:

```sh
cmake -S guest/gpu/emulation-check/coherent -B /tmp/caboose-coherent-build -G Ninja
cmake --build /tmp/caboose-coherent-build -j2
python3 guest/gpu/emulation-check/coherent/run.py /tmp/caboose-coherent-build/caboose_coherent --timeout 20
```

The runner generates a fresh random challenge, supervises a separate process
group, and reports `PASS`, `FAIL`, or `UNSUPPORTED` (exit 77). `--icd` selects a
private loader manifest; the socket ICD's current gate is expected to report
unsupported. A native pass is a reference control only. The test does not
prove Caboose socket coherent memory, a physical-phone executor, or Vulkan
conformance. It does not install or enable an ICD.
