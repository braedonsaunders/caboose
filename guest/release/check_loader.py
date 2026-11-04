#!/usr/bin/env python3
"""Checks, in a computer with a release installed, that the Vulkan loader loads the release's
driver from its manifest and lists both implicit layers when the seat enables them (the
switches caboose-display sets): the 64-bit computer-side half of the GPU stack, without a
phone or an executor (README.md, "The GPU stack").

usage: check_loader.py"""
import ctypes
import os
import subprocess
import sys

DRIVER = "/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so"
LAYERS = ("VK_LAYER_CABOOSE_executor_switch", "VK_LAYER_CABOOSE_gpu_routing")


class LayerProperties(ctypes.Structure):
    _fields_ = [("layerName", ctypes.c_char * 256), ("specVersion", ctypes.c_uint32),
                ("implementationVersion", ctypes.c_uint32), ("description", ctypes.c_char * 256)]


def probe():
    """In a child with the loader's debug output on: the layer names it lists, then enumerates
    the instance extensions, which loads each driver."""
    vulkan = ctypes.CDLL("libvulkan.so.1")
    count = ctypes.c_uint32()
    vulkan.vkEnumerateInstanceLayerProperties(ctypes.byref(count), None)
    layers = (LayerProperties * count.value)()
    vulkan.vkEnumerateInstanceLayerProperties(ctypes.byref(count), layers)
    for layer in layers[:count.value]:
        print("LAYER", layer.layerName.decode())
    vulkan.vkEnumerateInstanceExtensionProperties(None, ctypes.byref(count), None)


def main():
    if sys.argv[1:] == ["--probe"]:
        probe()
        return 0
    env = {**os.environ, "VK_DRIVER_FILES": "/usr/local/lib/caboose-gpu-live/icd.json", "VK_LOADER_DEBUG": "driver,layer",
           "CABOOSE_GPU_ROUTING": "1", "CABOOSE_GPU_EXECUTOR_SWITCH": "1"}
    result = subprocess.run([sys.executable, "-I", __file__, "--probe"], env=env, capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    listed = {line.split(" ", 1)[1] for line in result.stdout.splitlines() if line.startswith("LAYER ")}
    problems = [f"the loader does not list {name}" for name in LAYERS if name not in listed]
    if DRIVER not in output:
        problems.append(f"the loader never named {DRIVER}")
    problems += [line.strip() for line in output.splitlines() if DRIVER in line and ("fail" in line.lower() or "error" in line.lower())]
    if result.returncode:
        problems.append(f"the probe exited {result.returncode}")
    for problem in problems:
        print(f"FAIL GPU stack loader: {problem}")
    if problems:
        print(output[-4000:], file=sys.stderr)
        return 1
    print("PASS GPU stack loader: the release's driver loads and both implicit layers are listed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
