"""Run against the assembled guest sources; never launches a listener."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("install_live", HERE / "install-live.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstalledBrokerTests(unittest.TestCase):
    def test_installed_layout_ignores_working_directory_and_pythonpath(self):
        assembled = Path(os.environ.get("CABOOSE_GPU_TEST_SOURCE", HERE))
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-install-") as temporary:
            base = Path(temporary)
            source = base / "source"
            shutil.copytree(assembled, source)
            # The installer and launcher under test, independent of assembled branch.
            shutil.copyfile(HERE / "caboose-gpu-broker-launcher", source / "caboose-gpu-broker-launcher")
            for name in ("live_protocol.py", "live_surface_protocol.py"):
                shutil.copyfile(HERE / "broker" / name, source / "broker" / name)
            shutil.copyfile(HERE / "gfxstream/surface_local_protocol.py",
                            source / "gfxstream/surface_local_protocol.py")
            destination = base / "root"
            installer.install(source, destination)
            hostile = base / "untrusted"
            hostile.mkdir()
            (hostile / "executor_lease.py").write_text("raise RuntimeError('untrusted import')\n")
            launcher = destination / "usr/local/libexec/caboose-gpu-broker"
            result = subprocess.run([sys.executable, "-I", str(launcher), "--help"],
                                    cwd=hostile, env={**os.environ, "PYTHONPATH": str(hostile)},
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--control-fd", result.stdout)
            self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
            for name in installer.MODULES:
                module = launcher.parent / "caboose-gpu" / name
                self.assertEqual(module.read_bytes(), (source / "gfxstream" / name).read_bytes())
                self.assertEqual(module.stat().st_mode & 0o777, 0o644)

    def test_incomplete_bundle_does_not_install_entrypoint(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-incomplete-") as temporary:
            base = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                installer.install(base / "missing", base / "root")
            self.assertFalse((base / "root/usr/local/libexec/caboose-gpu-broker").exists())


class InstalledDriverTests(unittest.TestCase):
    def test_driver_and_manifest_name_each_other(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-driver-") as temporary:
            base = Path(temporary)
            library = base / "libvulkan_gfxstream.so"
            library.write_bytes(b"\x7fELF" + bytes(60))
            installer.install_driver(library, base / "root", machine="x86_64")
            directory = base / "root/usr/local/lib/caboose-gpu-live"
            self.assertEqual((directory / "libvulkan_gfxstream.so").read_bytes(), library.read_bytes())
            manifest = json.loads((directory / "icd.json").read_text())
            self.assertEqual(manifest["ICD"]["library_path"], "/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so")
            self.assertEqual(manifest["file_format_version"], "1.0.1")
            for name in ("icd.json", "libvulkan_gfxstream.so"):
                self.assertEqual((directory / name).stat().st_mode & 0o777, 0o644)
            self.assertEqual(sorted(p.name for p in directory.iterdir()), ["icd.json", "libvulkan_gfxstream.so"])

    def test_flatpak_applications_get_the_driver_and_the_sockets(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-flatpak-") as temporary:
            base = Path(temporary)
            library = base / "libvulkan_gfxstream.so"
            library.write_bytes(b"\x7fELF" + bytes(60))
            override = base / "root/var/lib/flatpak/overrides/global"
            override.parent.mkdir(parents=True)
            override.write_text("[Context]\nsockets=wayland;\nfilesystems=home;\n\n[Environment]\nA=1\n")
            installer.install_driver(library, base / "root", machine="x86_64")
            extension = base / "root/var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/x86_64/1.4"
            self.assertEqual((extension / "lib/libvulkan_gfxstream.so").read_bytes(), library.read_bytes())
            manifest = json.loads((extension / "vulkan/icd.d/caboose_gfxstream.json").read_text())
            self.assertEqual(manifest["ICD"]["library_path"], "/usr/lib/x86_64-linux-gnu/GL/host/lib/libvulkan_gfxstream.so")
            self.assertEqual(override.read_text(),
                             "[Context]\nsockets=wayland;\nfilesystems=home;xdg-run/caboose-gpu;\n\n[Environment]\nA=1\n")
            installer.install_driver(library, base / "root", machine="x86_64")
            self.assertEqual(override.read_text().count("caboose-gpu"), 1, "installing again changes nothing")

    def test_override_keyfiles_gain_the_socket_directory(self):
        self.assertEqual(installer.with_filesystem("", "x"), "[Context]\nfilesystems=x;\n")
        self.assertEqual(installer.with_filesystem("[Environment]\nA=1\n", "x"), "[Environment]\nA=1\n\n[Context]\nfilesystems=x;\n")
        self.assertEqual(installer.with_filesystem("[Context]\nshared=ipc;\n", "x"), "[Context]\nfilesystems=x;\nshared=ipc;\n")

    def test_executor_switch_layer_is_implicit_and_opt_in(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-layer-") as temporary:
            base = Path(temporary)
            layer = base / "libVkLayer_caboose_executor_switch.so"
            layer.write_bytes(b"\x7fELF" + bytes(60))
            installer.install_switch_layer(layer, base / "root", machine="aarch64")
            sandboxed = json.loads((base / "root/var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/aarch64/1.4"
                                    "/vulkan/implicit_layer.d/caboose_executor_switch.json").read_text())
            self.assertEqual(sandboxed["layer"]["library_path"],
                             "/usr/lib/aarch64-linux-gnu/GL/host/lib/libVkLayer_caboose_executor_switch.so")
            installed = base / "root/usr/local/lib/caboose-gpu-live/libVkLayer_caboose_executor_switch.so"
            self.assertEqual(installed.read_bytes(), layer.read_bytes())
            manifest = json.loads((base / "root/usr/local/share/vulkan/implicit_layer.d/caboose_executor_switch.json").read_text())
            self.assertEqual(manifest["layer"]["library_path"], "/" + str(installed.relative_to(base / "root")))
            self.assertEqual(manifest["layer"]["enable_environment"], {"CABOOSE_GPU_EXECUTOR_SWITCH": "1"})

    def test_refuses_what_is_not_a_library(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-driver-") as temporary:
            base = Path(temporary)
            (base / "driver").write_text("#!/bin/sh\n")
            with self.assertRaises(ValueError):
                installer.install_driver(base / "driver", base / "root")
            self.assertFalse((base / "root/usr/local/lib/caboose-gpu-live/icd.json").exists())


if __name__ == "__main__":
    unittest.main()
