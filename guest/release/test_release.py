"""Unit tests for caboose-release's releases: python3 -m unittest guest/release/test_release.py"""
import importlib.machinery
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("caboose_release", str(HERE / "caboose-release"))
spec = importlib.util.spec_from_loader("caboose_release", loader)
release = importlib.util.module_from_spec(spec)
loader.exec_module(release)
RUN_CHECK = release.run_check  # the real check, before the tests stand in for it


def keypair(directory, name):
    """A throwaway Ed25519 key and its public key, as the release key would be."""
    key, public = Path(directory) / f"{name}.key.pem", Path(directory) / f"{name}.pub.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(key)], check=True, capture_output=True)
    subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], check=True, capture_output=True)
    return key, public


class Releases(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        release.ROOT = Path(self.tmp.name) / "releases"
        self.source = Path(self.tmp.name) / "driver.so"
        self.source.write_bytes(b"driver")
        release.KEY, public = keypair(self.tmp.name, "release")
        os.environ["CABOOSE_RELEASE_PUB"] = str(public)
        release.CHECK_CONF = Path(self.tmp.name) / "check.conf"
        release.CHECK_CONF.write_text("repo=/r\nimage=caboose-computer:x\nwork=/w\n# a comment\nsync_check=/s\ncapability_probe=/c\ndxvk_computer=/k\ndxvk_bench=/b\nchaos_home=/h\n")
        self.checked = []
        release.run_check = self.passing_check

    def passing_check(self, directory, settings):
        self.checked.append((directory.name, settings))
        (directory / "check").mkdir(exist_ok=True)
        (directory / "check" / "vkcube.log").write_text("frames\n")
        return 0, "PASS sync-check: 12 cases\nPASS vkcube: frames=300\n"

    def tearDown(self):
        os.environ.pop("CABOOSE_RELEASE_PUB", None)
        self.tmp.cleanup()

    def test_a_sealed_release_lists_every_file_and_detects_changes(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so", "755"])
        release.main(["remove", "r1", "/etc/chromium.d/caboose-scroll"])
        release.main(["seal", "r1", "driver=cbV33", "display=66554e57"])
        directory = release.ROOT / "r1"
        manifest = (directory / "MANIFEST").read_text()
        self.assertIn("0755  files/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so", manifest)
        self.assertIn("notes", manifest)
        self.assertIn("remove", manifest)
        self.assertIn("sbom.spdx.json", manifest)
        self.assertNotIn("MANIFEST", manifest)
        release.verify(directory)
        release.verify_signature(directory)
        (directory / "files/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so").write_bytes(b"other")
        with self.assertRaises(release.Failure):
            release.verify(directory)

    def test_add_tree_adds_every_file_at_its_path_with_its_mode(self):
        root = Path(self.tmp.name) / "staged"
        (root / "usr/local/lib/caboose-gpu-live/i386").mkdir(parents=True)
        (root / "usr/local/lib/caboose-gpu-live/i386/libvulkan_gfxstream.so").write_bytes(b"i386")
        (root / "usr/local/lib/caboose-gpu-live/i386/libvulkan_gfxstream.so").chmod(0o755)
        (root / "usr/local/lib/caboose-gpu-live/icd.json").write_text("{}")
        (root / "usr/local/lib/caboose-gpu-live/icd.json").chmod(0o644)
        release.main(["new", "r1"])
        release.main(["add-tree", "r1", str(root)])
        files = release.ROOT / "r1/files/usr/local/lib/caboose-gpu-live"
        self.assertEqual((files / "i386/libvulkan_gfxstream.so").read_bytes(), b"i386")
        self.assertEqual((files / "i386/libvulkan_gfxstream.so").stat().st_mode & 0o7777, 0o755)
        self.assertEqual((files / "icd.json").stat().st_mode & 0o7777, 0o644)
        (root / "link").symlink_to("usr")
        with self.assertRaises(release.Failure):
            release.main(["add-tree", "r1", str(root)])

    def test_sealing_runs_the_executor_check_and_keeps_its_result(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        release.main(["seal", "r1", "first"])
        directory = release.ROOT / "r1"
        self.assertEqual(self.checked, [("r1", {"repo": "/r", "image": "caboose-computer:x", "work": "/w", "sync_check": "/s", "capability_probe": "/c", "dxvk_computer": "/k", "dxvk_bench": "/b", "chaos_home": "/h"})])
        self.assertEqual((directory / "check/result").read_text(), "PASS\nPASS sync-check: 12 cases\nPASS vkcube: frames=300\n")
        manifest = (directory / "MANIFEST").read_text()
        self.assertIn("check/result", manifest)
        self.assertIn("check/vkcube.log", manifest)

    def test_a_failed_check_leaves_the_release_open_with_its_logs(self):
        release.main(["new", "r1"])
        release.run_check = lambda directory, settings: (1, "FAIL vkcube: no swapchain retired\n")
        with self.assertRaises(release.Failure) as raised:
            release.main(["seal", "r1", "first"])
        self.assertIn("FAIL vkcube", str(raised.exception))
        directory = release.ROOT / "r1"
        self.assertFalse(release.sealed(directory))
        self.assertTrue((directory / "check/result").read_text().startswith("FAIL\n"))
        release.CHECK_CONF.write_text("repo=/r\n")
        with self.assertRaises(release.Failure):
            release.check_settings()

    def test_the_check_runs_the_release_driver(self):
        release.main(["new", "r1"])
        with self.assertRaises(release.Failure):
            RUN_CHECK(release.ROOT / "r1", release.check_settings())
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        script = Path(self.tmp.name) / "repo" / release.CHECK_SCRIPT
        script.parent.mkdir(parents=True)
        script.write_text('echo "args $1 $2 $3 $4"; echo log > "$5/sync-check.log"; exit 3\n')
        status, summary = RUN_CHECK(release.ROOT / "r1", {"repo": str(Path(self.tmp.name) / "repo"), "image": "i",
                                                          "work": "w", "sync_check": "s"})
        self.assertEqual(status, 3)
        self.assertEqual(summary, f"args i w {release.ROOT / 'r1' / 'files' / release.DRIVER} s\n")
        self.assertTrue((release.ROOT / "r1/check/sync-check.log").is_file())

    def test_packaged_start_failure_fails_check_after_executor_passes(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        repo = Path(self.tmp.name) / "repo"
        executor = repo / release.CHECK_SCRIPT
        executor.parent.mkdir(parents=True)
        executor.write_text('echo "PASS executor"; exit 0\n')
        packaged = repo / "guest/release/check-packaged.sh"
        packaged.parent.mkdir(parents=True)
        packaged.write_text('echo "FAIL packaged broker"; exit 1\n')
        status, summary = RUN_CHECK(release.ROOT / "r1", {
            "repo": str(repo), "image": "i", "work": "w", "sync_check": "s"})
        self.assertEqual(status, 1)
        self.assertIn("PASS executor", summary)
        self.assertIn("FAIL packaged broker", summary)

    def test_packaged_cache_failure_fails_seal_check(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        repo=Path(self.tmp.name)/"repo"
        for name,body in ((release.CHECK_SCRIPT,'echo "PASS executor"'),
                          ("guest/release/check-packaged.sh",'echo "PASS packaged"'),
                          ("apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh",
                           'echo "FAIL packaged cache"; exit 4')):
            script=repo/name; script.parent.mkdir(parents=True,exist_ok=True); script.write_text(body)
        status,summary=RUN_CHECK(release.ROOT/"r1",{"repo":str(repo),"image":"i","work":"w",
                                                       "sync_check":"s","capability_probe":"c"})
        self.assertEqual(status,4)
        self.assertIn("FAIL packaged cache",summary)

    def test_a_device_dxvk_cannot_use_fails_the_seal_check(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        repo = Path(self.tmp.name) / "repo"
        for name, body in ((release.CHECK_SCRIPT, 'echo "PASS executor"'),
                           ("guest/release/check-packaged.sh", 'echo "PASS packaged"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh", 'echo "PASS cache"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh",
                            'echo "args $1 $2 $3 $4"; echo "FAIL: phone: DXVK skipped the device"; exit 1')):
            script = repo / name; script.parent.mkdir(parents=True, exist_ok=True); script.write_text(body)
        status, summary = RUN_CHECK(release.ROOT / "r1", {"repo": str(repo), "image": "i", "work": "w", "sync_check": "s",
                                                          "capability_probe": "c", "dxvk_computer": "k", "dxvk_bench": "b"})
        self.assertEqual(status, 1)
        self.assertIn(f"args k w {release.ROOT / 'r1' / 'files' / release.DRIVER} b", summary)
        self.assertIn("DXVK skipped the device", summary)

    def test_a_stale_readback_under_the_dxvk_stress_fails_the_seal_check(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        repo = Path(self.tmp.name) / "repo"
        for name, body in ((release.CHECK_SCRIPT, 'echo "PASS executor"'),
                           ("guest/release/check-packaged.sh", 'echo "PASS packaged"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh", 'echo "PASS cache"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh",
                            '[ -z "${APP:-}" ] && { echo "PASS DXVK"; exit 0; }\n'
                            'echo "app $APP $APP_ARGS $APP_EXPECT $CASES $5"; echo "FAIL: phone: FAIL readback frame 3"; exit 1')):
            script = repo / name; script.parent.mkdir(parents=True, exist_ok=True); script.write_text(body)
        status, summary = RUN_CHECK(release.ROOT / "r1", {"repo": str(repo), "image": "i", "work": "w", "sync_check": "s",
                                                          "capability_probe": "c", "dxvk_computer": "k", "dxvk_bench": "b",
                                                          "dxvk_stress": "40 4 50"})
        self.assertEqual(status, 1)
        self.assertIn("PASS DXVK", summary)
        self.assertIn(f"app d3d11_stress.exe 40 4 50 frames= phone {release.ROOT / 'r1' / 'check' / 'dxvk-stress'}", summary)
        self.assertIn("FAIL readback frame 3", summary)

    def test_a_driver_that_presents_noise_after_a_loss_fails_the_seal_check(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        repo = Path(self.tmp.name) / "repo"
        for name, body in ((release.CHECK_SCRIPT, 'echo "PASS executor"'),
                           ("guest/release/check-packaged.sh", 'echo "PASS packaged"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh", 'echo "PASS cache"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh", 'echo "PASS DXVK"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-loss-pixels.sh",
                            'echo "args $1 $2 $3"; echo "FAIL: a fresh Chromium drew no real picture"; exit 1')):
            script = repo / name; script.parent.mkdir(parents=True, exist_ok=True); script.write_text(body)
        status, summary = RUN_CHECK(release.ROOT / "r1", {"repo": str(repo), "image": "i", "work": "w", "sync_check": "s",
                                                          "capability_probe": "c", "dxvk_computer": "k", "dxvk_bench": "b"})
        self.assertEqual(status, 1)
        self.assertIn("PASS DXVK", summary)
        self.assertIn(f"args k w {release.ROOT / 'r1' / 'files' / release.DRIVER}", summary)
        self.assertIn("a fresh Chromium drew no real picture", summary)

    def test_a_release_whose_apps_stop_drawing_after_a_loss_fails_the_seal_check(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/" + release.DRIVER, "755"])
        repo = Path(self.tmp.name) / "repo"
        for name, body in ((release.CHECK_SCRIPT, 'echo "PASS executor"'),
                           ("guest/release/check-packaged.sh", 'echo "PASS packaged"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-capabilities.sh", 'echo "PASS cache"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh", 'echo "PASS DXVK"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check-loss-pixels.sh", 'echo "PASS loss pixels"'),
                           ("apps/ios/GPUStream/gfxstream/linux-executor/check_chaos.py",
                            'import sys\nprint("args", *sys.argv[1:5])\nprint("PASS cycle 1/50 kill")\n'
                            'print("FAIL cycle 2/50 drop: no real picture from steam")\nsys.exit(1)\n')):
            script = repo / name; script.parent.mkdir(parents=True, exist_ok=True); script.write_text(body)
        status, summary = RUN_CHECK(release.ROOT / "r1", {"repo": str(repo), "image": "i", "work": "w", "sync_check": "s",
                                                          "capability_probe": "c", "dxvk_computer": "k", "dxvk_bench": "b",
                                                          "chaos_home": "h"})
        self.assertEqual(status, 1)
        self.assertIn(f"args k w {release.ROOT / 'r1'}", summary)
        self.assertNotIn("PASS cycle", summary)
        self.assertIn("FAIL cycle 2/50 drop", summary)

    def test_a_sealed_release_is_final_and_a_new_one_starts_from_it(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/bin/x"])
        release.main(["seal", "r1", "first"])
        with self.assertRaises(release.Failure):
            release.main(["add", "r1", str(self.source), "/usr/local/bin/y"])
        release.main(["new", "r2", "--from", "r1"])
        directory = release.ROOT / "r2"
        self.assertTrue((directory / "files/usr/local/bin/x").is_file())
        for name in ("MANIFEST", "MANIFEST.sig", "notes", "sbom.spdx.json", "check"):
            self.assertFalse((directory / name).exists(), name)

    def install_calls(self, paths):
        """The docker commands installing a release with files at PATHS runs, in order."""
        directory = Path(self.tmp.name) / "r-install"
        for path in paths:
            target = directory / "files" / path.lstrip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"x")
        calls = []
        saved = release.docker, release.game_running, release.steam_running
        release.docker = lambda *args, input_=None, check=True: calls.append(args) or subprocess.CompletedProcess(args, 0, b"", b"")
        release.game_running = lambda container: False
        release.steam_running = lambda container: False
        try:
            self.assertTrue(release.install_one(directory, "caboose-c-test", "r\n"))
        finally:
            release.docker, release.game_running, release.steam_running = saved
        return [" ".join(a for a in call if isinstance(a, str)) for call in calls]

    def test_an_install_that_changes_the_broker_restarts_the_gpu_service(self):
        calls = self.install_calls(["/usr/local/libexec/caboose-gpu/broker.py", "/usr/local/bin/caboose-display"])
        stop = calls.index("exec caboose-c-test caboose-session stop-gpu")
        self.assertLess(calls.index("exec caboose-c-test caboose-session stop-display"), stop)
        self.assertLess(stop, next(i for i, c in enumerate(calls) if "caboose-session start" in c))

    def test_an_install_without_broker_files_leaves_the_gpu_service_running(self):
        calls = self.install_calls(["/usr/local/bin/caboose-display"])
        self.assertNotIn("exec caboose-c-test caboose-session stop-gpu", calls)

    def test_paths_must_be_absolute_and_ids_plain(self):
        release.main(["new", "r1"])
        for path in ("relative/x", "/usr/../etc/x"):
            with self.assertRaises(release.Failure):
                release.main(["add", "r1", str(self.source), path])
        for id_ in ("../x", ".hidden", ""):
            with self.assertRaises(release.Failure):
                release.release(id_)

    def test_the_marker_names_the_release_its_manifest_and_notes(self):
        release.main(["new", "r4.2"])
        release.main(["add", "r4.2", str(self.source), "/usr/local/bin/x"])
        release.main(["seal", "r4.2", "driver=cbV33 (main 745bcc85)"])
        text = release.marker_text(release.ROOT / "r4.2")
        lines = text.splitlines()
        self.assertEqual(lines[0], "r4.2")
        self.assertTrue(lines[1].startswith("manifest_sha256=") and len(lines[1]) == len("manifest_sha256=") + 64)
        self.assertEqual(lines[2], "driver=cbV33 (main 745bcc85)")

    def test_a_release_is_signed_and_only_the_release_key_verifies_it(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/bin/x"])
        release.main(["seal", "r1", "first"])
        directory = release.ROOT / "r1"
        release.verify_signature(directory)
        # A changed MANIFEST, a signature by another key, or none at all are refused.
        manifest = (directory / "MANIFEST").read_bytes()
        (directory / "MANIFEST").write_bytes(manifest.replace(b"0644", b"0755"))
        with self.assertRaises(release.Failure):
            release.verify_signature(directory)
        (directory / "MANIFEST").write_bytes(manifest)
        other, _ = keypair(self.tmp.name, "other")
        signature = (directory / "MANIFEST.sig").read_text()
        with self.assertRaises(release.Failure):
            release.sign(directory, other)
        self.assertEqual((directory / "MANIFEST.sig").read_text(), signature, "a signature that does not verify is not kept")
        (directory / "MANIFEST.sig").unlink()
        with self.assertRaises(release.Failure):
            release.verify_signature(directory)
        release.main(["sign", "r1"])
        release.verify_signature(directory)

    def test_sealing_needs_the_signing_key(self):
        release.main(["new", "r1"])
        release.KEY = Path(self.tmp.name) / "missing.pem"
        with self.assertRaises(release.Failure):
            release.main(["seal", "r1", "first"])
        self.assertFalse(release.sealed(release.ROOT / "r1"))

    def test_the_sbom_lists_every_file_and_package(self):
        release.main(["new", "r1"])
        release.main(["add", "r1", str(self.source), "/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so", "755"])
        debs = release.ROOT / "r1" / "debs"
        debs.mkdir()
        (debs / "xwayland_24.1.6-1+caboose1_amd64.deb").write_bytes(b"deb")
        (release.ROOT / "r1" / "notes").write_text("driver=cbV34\n")
        text = release.sbom(release.ROOT / "r1", created="2026-11-02T00:00:00Z",
                            fields=lambda deb: ("xwayland", "2:24.1.6-1+caboose1", "amd64"))
        document = json.loads(text)
        self.assertEqual(document["spdxVersion"], "SPDX-2.3")
        self.assertEqual(document["packages"][0]["versionInfo"], "r1")
        self.assertEqual(document["packages"][0]["comment"], "driver=cbV34")
        (file,) = document["files"]
        self.assertEqual(file["fileName"], "./usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so")
        self.assertIn({"algorithm": "SHA256", "checksumValue": hashlib.sha256(b"driver").hexdigest()}, file["checksums"])
        deb = document["packages"][1]
        self.assertEqual((deb["name"], deb["versionInfo"]), ("xwayland", "2:24.1.6-1+caboose1"))
        self.assertEqual(deb["externalRefs"][0]["referenceLocator"], "pkg:deb/xwayland@2:24.1.6-1+caboose1?arch=amd64")
        contained = {r["relatedSpdxElement"] for r in document["relationships"] if r["relationshipType"] == "CONTAINS"}
        self.assertEqual(contained, {file["SPDXID"], deb["SPDXID"]})


if __name__ == "__main__":
    unittest.main()
