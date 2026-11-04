#!/usr/bin/env python3
"""Tests stage-gpu-stack.sh and check_gpu_stack.py with stand-in builds."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
spec = importlib.util.spec_from_file_location("check_gpu_stack", HERE / "check_gpu_stack.py")
check_gpu_stack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_gpu_stack)


def elf(machine: int) -> bytes:
    return b"\x7fELF" + bytes(14) + machine.to_bytes(2, "little") + bytes(44)


class StageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.driver, self.layers, self.warmup = base / "driver", base / "layers", base / "warmup"
        for directory in (self.driver / "i386", self.layers / "i386", self.warmup):
            directory.mkdir(parents=True)
        (self.driver / "libvulkan_gfxstream.so").write_bytes(elf(62))
        (self.driver / "i386/libvulkan_gfxstream.so").write_bytes(elf(3))
        (self.driver / "caboose-driver.json").write_text('{"mesa": "x"}\n')
        for name in ("libVkLayer_caboose_executor_switch.so", "libVkLayer_caboose_gpu_routing.so"):
            (self.layers / name).write_bytes(elf(62))
            (self.layers / "i386" / name).write_bytes(elf(3))
        (self.warmup / "caboose-gpu-warmup").write_bytes(elf(62))
        self.gbm = base / "vgem_gbm.so"
        self.gbm.write_bytes(elf(62))
        self.out = base / "out"

    def tearDown(self):
        self.temporary.cleanup()

    def stage(self):
        return subprocess.run(["sh", str(HERE / "stage-gpu-stack.sh"), str(REPO), str(self.driver), str(self.layers),
                               str(self.warmup), str(self.gbm), str(self.out)], capture_output=True, text=True)

    def test_staged_stack_is_complete(self):
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS GPU stack", result.stdout)
        self.assertEqual(check_gpu_stack.problems(self.out), [])
        icd = self.out / "var/lib/flatpak/extension/org.freedesktop.Platform.GL32.host/x86_64/1.4/vulkan/icd.d/caboose_gfxstream.json"
        self.assertIn("/usr/lib/i386-linux-gnu/GL/host/lib/libvulkan_gfxstream.so", icd.read_text())
        self.assertTrue((self.out / "usr/local/lib/caboose-gpu-live/icd.json").is_file())
        self.assertEqual((self.out / "usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so").stat().st_mode & 0o777, 0o755)

    def test_missing_input_stops_staging(self):
        (self.layers / "i386/libVkLayer_caboose_gpu_routing.so").unlink()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_check_finds_a_missing_manifest_and_a_wrong_architecture(self):
        self.assertEqual(self.stage().returncode, 0)
        host32 = self.out / "var/lib/flatpak/extension/org.freedesktop.Platform.GL32.host/x86_64/1.4"
        (host32 / "vulkan/implicit_layer.d/caboose_gpu_routing_32.json").unlink()
        (host32 / "lib/libvulkan_gfxstream.so").write_bytes(elf(62))
        found = check_gpu_stack.problems(self.out)
        self.assertTrue(any("caboose_gpu_routing_32.json" in p for p in found), found)
        self.assertTrue(any("not built for ELF machine 3" in p for p in found), found)

    def test_an_empty_root_lacks_everything(self):
        empty = Path(self.temporary.name) / "empty"
        empty.mkdir()
        found = check_gpu_stack.problems(empty)
        self.assertTrue(any("icd.json" in p for p in found))
        self.assertTrue(any("GBM_BACKENDS_PATH" in p for p in found))


if __name__ == "__main__":
    unittest.main()
