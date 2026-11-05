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

    def test_mesa_loads_zink_for_vgem_on_the_computer_and_in_every_flatpak_sandbox(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-drirc-") as temporary:
            root = Path(temporary) / "root"
            override = root / "var/lib/flatpak/overrides/global"
            override.parent.mkdir(parents=True)
            override.write_text("[Context]\nfilesystems=xdg-run/caboose-gpu;\n")
            data = (HERE / "caboose-vgem.conf").read_bytes()
            self.assertIn(b'kernel_driver="vgem"', data)
            self.assertIn(b'<option name="dri_driver" value="zink" />', data)
            installer.install_drirc(data, root, machine="x86_64")
            extensions = root / "var/lib/flatpak/extension"
            for path in ("usr/share/drirc.d", "var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/x86_64/1.4/share/drirc.d",
                         "var/lib/flatpak/extension/org.freedesktop.Platform.GL32.host/x86_64/1.4/share/drirc.d"):
                self.assertEqual((root / path / "caboose-vgem.conf").read_bytes(), data, path)
            self.assertEqual(override.read_text(), "[Context]\nfilesystems=xdg-run/caboose-gpu;\n\n[Environment]\n"
                             "DRIRC_CONFIGDIR=/usr/lib/x86_64-linux-gnu/GL/default/share/drirc.d"
                             ":/usr/lib/x86_64-linux-gnu/GL/host/share/drirc.d"
                             ":/run/parent/usr/lib/x86_64-linux-gnu/GL/host/share/drirc.d\n")
            installer.install_drirc(data, root, machine="x86_64")
            self.assertEqual(override.read_text().count("DRIRC_CONFIGDIR"), 1, "installing again changes nothing")
            installer.install_drirc(data, root, machine="arm64")
            self.assertTrue((extensions / "org.freedesktop.Platform.GL.host/aarch64/1.4/share/drirc.d/caboose-vgem.conf").is_file())
            self.assertIn("DRIRC_CONFIGDIR=/usr/lib/aarch64-linux-gnu/GL/default", override.read_text())

    def test_flatpak_applications_get_the_gbm_backend_and_its_search_path(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-gbm-") as temporary:
            base = Path(temporary)
            root = base / "root"
            override = root / "var/lib/flatpak/overrides/global"
            override.parent.mkdir(parents=True)
            override.write_text("[Environment]\nA=1\n")
            backend = base / "vgem_gbm.so"
            backend.write_bytes(b"\x7fELF" + bytes(14) + (62).to_bytes(2, "little") + bytes(44))
            installer.install_gbm(backend, root, machine="x86_64")
            extensions = root / "var/lib/flatpak/extension"
            self.assertEqual((extensions / "org.freedesktop.Platform.GL.host/x86_64/1.4/lib/gbm/vgem_gbm.so").read_bytes(),
                             backend.read_bytes())
            self.assertEqual(override.read_text(), "[Environment]\nGBM_BACKENDS_PATH="
                             "/usr/lib/x86_64-linux-gnu/GL/host/lib/gbm:/run/parent/usr/lib/x86_64-linux-gnu/GL/host/lib/gbm"
                             ":/usr/lib/x86_64-linux-gnu/GL/default/lib/gbm"
                             ":/usr/lib/pressure-vessel/overrides/lib/x86_64-linux-gnu/gbm\nA=1\n")
            installer.install_gbm(backend, root, machine="x86_64")
            self.assertEqual(override.read_text().count("GBM_BACKENDS_PATH"), 1, "installing again changes nothing")
            # An i386 build goes to the GL32 extension, and the search path names both.
            backend32 = base / "vgem_gbm32.so"
            backend32.write_bytes(b"\x7fELF" + bytes(14) + (3).to_bytes(2, "little") + bytes(44))
            installer.install_gbm(backend32, root, machine="x86_64")
            self.assertTrue((extensions / "org.freedesktop.Platform.GL32.host/x86_64/1.4/lib/gbm/vgem_gbm.so").is_file())
            value = override.read_text().split("GBM_BACKENDS_PATH=")[1].split("\n")[0].split(":")
            self.assertEqual(value[:4], ["/usr/lib/x86_64-linux-gnu/GL/host/lib/gbm", "/run/parent/usr/lib/x86_64-linux-gnu/GL/host/lib/gbm",
                                         "/usr/lib/i386-linux-gnu/GL/host/lib/gbm", "/run/parent/usr/lib/i386-linux-gnu/GL/host/lib/gbm"])
            self.assertIn("/usr/lib/i386-linux-gnu/GL/default/lib/gbm", value)

    def test_override_keyfiles_gain_environment_entries(self):
        self.assertEqual(installer.with_environment("", "A", "1"), "[Environment]\nA=1\n")
        self.assertEqual(installer.with_environment("[Context]\nx=1;\n", "A", "1"), "[Context]\nx=1;\n\n[Environment]\nA=1\n")
        self.assertEqual(installer.with_environment("[Environment]\nA=0\nB=2\n", "A", "1"), "[Environment]\nA=1\nB=2\n")
        self.assertEqual(installer.with_environment("[Environment]\nB=2\n[Context]\n", "A", "1"), "[Environment]\nA=1\nB=2\n[Context]\n")

    def test_override_keyfiles_gain_the_socket_directory(self):
        self.assertEqual(installer.with_filesystem("", "x"), "[Context]\nfilesystems=x;\n")
        self.assertEqual(installer.with_filesystem("[Environment]\nA=1\n", "x"), "[Environment]\nA=1\n\n[Context]\nfilesystems=x;\n")
        self.assertEqual(installer.with_filesystem("[Context]\nshared=ipc;\n", "x"), "[Context]\nfilesystems=x;\nshared=ipc;\n")

    def test_executor_switch_layer_is_implicit_and_opt_in(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-layer-") as temporary:
            base = Path(temporary)
            layer = base / "libVkLayer_caboose_executor_switch.so"
            layer.write_bytes(b"\x7fELF" + bytes(60))
            installer.install_layer("executor-switch", layer, base / "root", machine="aarch64")
            sandboxed = json.loads((base / "root/var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/aarch64/1.4"
                                    "/vulkan/implicit_layer.d/caboose_executor_switch.json").read_text())
            self.assertEqual(sandboxed["layer"]["library_path"],
                             "/usr/lib/aarch64-linux-gnu/GL/host/lib/libVkLayer_caboose_executor_switch.so")
            installed = base / "root/usr/local/lib/caboose-gpu-live/libVkLayer_caboose_executor_switch.so"
            self.assertEqual(installed.read_bytes(), layer.read_bytes())
            manifest = json.loads((base / "root/usr/local/share/vulkan/implicit_layer.d/caboose_executor_switch.json").read_text())
            self.assertEqual(manifest["layer"]["library_path"], "/" + str(installed.relative_to(base / "root")))
            self.assertEqual(manifest["layer"]["enable_environment"], {"CABOOSE_GPU_EXECUTOR_SWITCH": "1"})

    def test_routing_layer_is_implicit_and_opt_in(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-layer-") as temporary:
            base = Path(temporary)
            layer = base / "libVkLayer_caboose_gpu_routing.so"
            layer.write_bytes(b"\x7fELF" + bytes(60))
            installer.install_layer("routing", layer, base / "root", machine="x86_64")
            manifest = json.loads((base / "root/usr/local/share/vulkan/implicit_layer.d/caboose_gpu_routing.json").read_text())
            self.assertEqual(manifest["layer"]["name"], "VK_LAYER_CABOOSE_gpu_routing")
            self.assertEqual(manifest["layer"]["library_path"], "/usr/local/lib/caboose-gpu-live/libVkLayer_caboose_gpu_routing.so")
            self.assertEqual(manifest["layer"]["enable_environment"], {"CABOOSE_GPU_ROUTING": "1"})

    def test_i386_builds_go_beside_the_64_bit_ones_for_32_bit_applications(self):
        def elf(machine: int) -> bytes:
            return b"\x7fELF" + bytes(14) + machine.to_bytes(2, "little") + bytes(44)
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-i386-") as temporary:
            base = Path(temporary)
            root = base / "root"
            for name, machine in (("64", 62), ("32", 3)):
                (base / name).mkdir()
                (base / name / "libvulkan_gfxstream.so").write_bytes(elf(machine))
                (base / name / "libVkLayer_caboose_gpu_routing.so").write_bytes(elf(machine) + b"routing")
                # The computer's architecture does not matter: the library's own does.
                installer.install_driver(base / name / "libvulkan_gfxstream.so", root, machine="x86_64")
                installer.install_layer("routing", base / name / "libVkLayer_caboose_gpu_routing.so", root,
                                        machine="x86_64")
            live = root / "usr/local/lib/caboose-gpu-live"
            self.assertEqual((live / "libvulkan_gfxstream.so").read_bytes(), elf(62))
            self.assertEqual((live / "i386/libvulkan_gfxstream.so").read_bytes(), elf(3))
            icd = json.loads((live / "i386/icd.json").read_text())
            self.assertEqual(icd["ICD"]["library_path"], "/usr/local/lib/caboose-gpu-live/i386/libvulkan_gfxstream.so")
            manifests = root / "usr/local/share/vulkan/implicit_layer.d"
            self.assertEqual(sorted(p.name for p in manifests.iterdir()),
                             ["caboose_gpu_routing.json", "caboose_gpu_routing_32.json"])
            layer = json.loads((manifests / "caboose_gpu_routing_32.json").read_text())["layer"]
            self.assertEqual(layer["name"], "VK_LAYER_CABOOSE_gpu_routing_32")
            self.assertEqual(layer["library_path"], "/usr/local/lib/caboose-gpu-live/i386/libVkLayer_caboose_gpu_routing.so")
            self.assertEqual(layer["enable_environment"], {"CABOOSE_GPU_ROUTING": "1"})
            self.assertEqual(json.loads((manifests / "caboose_gpu_routing.json").read_text())["layer"]["name"],
                             "VK_LAYER_CABOOSE_gpu_routing")
            gl32 = root / "var/lib/flatpak/extension/org.freedesktop.Platform.GL32.host/x86_64/1.4"
            self.assertEqual((gl32 / "lib/libvulkan_gfxstream.so").read_bytes(), elf(3))
            self.assertEqual(json.loads((gl32 / "vulkan/icd.d/caboose_gfxstream.json").read_text())["ICD"]["library_path"],
                             "/usr/lib/i386-linux-gnu/GL/host/lib/libvulkan_gfxstream.so")
            sandboxed = json.loads((gl32 / "vulkan/implicit_layer.d/caboose_gpu_routing_32.json").read_text())["layer"]
            self.assertEqual(sandboxed["library_path"], "/usr/lib/i386-linux-gnu/GL/host/lib/libVkLayer_caboose_gpu_routing.so")
            gl = root / "var/lib/flatpak/extension/org.freedesktop.Platform.GL.host/x86_64/1.4"
            self.assertEqual((gl / "lib/libvulkan_gfxstream.so").read_bytes(), elf(62))

    def test_refuses_a_library_of_an_unknown_architecture(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-arch-") as temporary:
            base = Path(temporary)
            (base / "driver").write_bytes(b"\x7fELF" + bytes(14) + (40).to_bytes(2, "little") + bytes(44))
            with self.assertRaises(ValueError):
                installer.install_driver(base / "driver", base / "root")

    def test_refuses_what_is_not_a_library(self):
        with tempfile.TemporaryDirectory(prefix="caboose-gpu-driver-") as temporary:
            base = Path(temporary)
            (base / "driver").write_text("#!/bin/sh\n")
            with self.assertRaises(ValueError):
                installer.install_driver(base / "driver", base / "root")
            self.assertFalse((base / "root/usr/local/lib/caboose-gpu-live/icd.json").exists())


if __name__ == "__main__":
    unittest.main()
