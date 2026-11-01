"""caboose-steam-adopt: python3 -m unittest guest/flatpak/test_steam_adopt.py"""
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import os
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
loader = SourceFileLoader("adopt", str(HERE / "caboose-steam-adopt"))
adopt = module_from_spec(spec_from_loader("adopt", loader))
loader.exec_module(adopt)

MANIFEST = '''"AppState"
{
\t"appid"\t\t"976730"
\t"name"\t\t"Halo: The Master Chief Collection"
\t"StateFlags"\t\t"4"
\t"installdir"\t\t"Halo The Master Chief Collection"
\t"InstalledDepots"
\t{
\t\t"976731"
\t\t{
\t\t\t"manifest"\t\t"4956458579120161185"
\t\t\t"size"\t\t"17126952679"
\t\t}
\t\t"976733"
\t\t{
\t\t\t"manifest"\t\t"886692270880710564"
\t\t\t"size"\t\t"9896534807"
\t\t\t"dlcappid"\t\t"1064221"
\t\t}
\t\t"976738"
\t\t{
\t\t\t"manifest"\t\t"5942743121382725562"
\t\t\t"size"\t\t"9007725781"
\t\t\t"dlcappid"\t\t"1064271"
\t\t}
\t}
\t"UserConfig"
\t{
\t\t"language"\t\t"english"
\t\t"optionaldlc"\t\t"1064272,1097222,1064221,1064271"
\t}
\t"MountedConfig"
\t{
\t\t"language"\t\t"english"
\t\t"optionaldlc"\t\t"1064272,1097222,1064221,1064271"
\t}
}
'''


class Manifest(unittest.TestCase):
    def test_an_adopted_game_is_brought_up_to_date(self):
        text = adopt.adopted_manifest(MANIFEST)
        self.assertEqual(adopt.value(text, ("AppState",), "StateFlags"), "1026")
        # Everything else is as it was.
        self.assertEqual(text.replace('"1026"', '"4"', 1), MANIFEST)

    def test_kept_dlc_choose_the_installed_depots(self):
        text = adopt.adopted_manifest(MANIFEST, [1064221, 1080080])
        depots = sorted(p[2] for p in adopt.blocks(text) if len(p) == 3 and p[1] == "InstalledDepots")
        self.assertEqual(depots, ["976731", "976733"], "the base and Halo CE stay; Halo 3 goes")
        for config in ("UserConfig", "MountedConfig"):
            self.assertEqual(adopt.value(text, ("AppState", config), "optionaldlc"), "1064221,1080080")
        self.assertEqual(adopt.value(text, ("AppState",), "installdir"), "Halo The Master Chief Collection")
        adopt.blocks(text)  # still balanced

    def test_an_absent_value_is_added_to_its_block(self):
        text = adopt.with_value('"A"\n{\n\t"x"\t\t"1"\n}\n', ("A",), "y", "2")
        self.assertEqual(adopt.value(text, ("A",), "y"), "2")
        self.assertEqual(adopt.value(text, ("A",), "x"), "1")

    def test_malformed_manifests_are_refused(self):
        for text in ('"A"\n{\n', '"A"\n}\n', '{\n}\n'):
            with self.assertRaises(ValueError):
                adopt.blocks(text)


class Redistributables(unittest.TestCase):
    def test_directx_is_recorded_as_run_in_both_registry_views(self):
        text = '[Software\\\\Valve\\\\Steam\\\\Apps\\\\976730] 1\n"InstallCount"=dword:00000001\n'
        for key in adopt.DIRECTX_KEYS:
            text = adopt.with_registry_dword(text, key, "dxsetup", 1)
        self.assertIn('[Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010]\n"dxsetup"=dword:00000001', text)
        self.assertIn('[Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010]\n"dxsetup"=dword:00000001', text)
        self.assertIn('"InstallCount"=dword:00000001', text)

    def test_an_existing_value_is_replaced_and_marking_twice_changes_nothing(self):
        key = adopt.DIRECTX_KEYS[1]
        text = f'[{key}] 1\n#time=1\n"dxsetup"=dword:00000000\n\n[Other] 1\n"x"=dword:00000002\n'
        once = adopt.with_registry_dword(text, key, "dxsetup", 1)
        self.assertIn('"dxsetup"=dword:00000001', once)
        self.assertNotIn('"dxsetup"=dword:00000000', once)
        self.assertEqual(adopt.with_registry_dword(once, key, "dxsetup", 1), once)
        self.assertIn('[Other] 1\n"x"=dword:00000002', once)

    def test_a_prefix_is_marked_once(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "system.reg").write_text("WINE REGISTRY Version 2\n")
            self.assertTrue(adopt.mark_redistributables(d))
            self.assertFalse(adopt.mark_redistributables(d))
            self.assertFalse(adopt.mark_redistributables(Path(d) / "missing"))


class Adopt(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.steamapps = self.home / ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"
        (self.steamapps / "common").mkdir(parents=True)
        (self.steamapps / "appmanifest_976730.acf").write_text(MANIFEST)
        # A read-only farm: real files, and a link into another library.
        farm, other = root / "farm", root / "windows"
        (farm / "MCC").mkdir(parents=True)
        (farm / "MCC" / "game.exe").write_bytes(b"MZ" * 1000)
        (other / "halo3").mkdir(parents=True)
        (other / "halo3" / "halo3.dll").write_bytes(b"h3")
        (farm / "halo3").symlink_to(other / "halo3")
        (farm / "halo1").mkdir()
        (farm / "halo1" / "a10.map").write_bytes(b"map")
        os.chmod(farm / "halo1" / "a10.map", 0o444)
        os.chmod(farm / "halo1", 0o555)
        (self.steamapps / "common" / "Halo The Master Chief Collection").symlink_to(farm)

    def tearDown(self):
        for d, _, files in os.walk(self.tmp.name):
            os.chmod(d, 0o755)
        self.tmp.cleanup()

    def test_a_linked_game_becomes_a_real_install(self):
        adopt.adopt(self.home, 976730, [1064221, 1080080], skip=("halo3",))
        game = self.steamapps / "common" / "Halo The Master Chief Collection"
        self.assertFalse(game.is_symlink())
        self.assertEqual((game / "MCC" / "game.exe").read_bytes(), b"MZ" * 1000)
        self.assertEqual((game / "halo1" / "a10.map").read_bytes(), b"map")
        self.assertTrue(os.access(game / "halo1" / "a10.map", os.W_OK), "Steam can update it")
        self.assertFalse((game / "halo3").exists(), "skipped")
        self.assertTrue((game.with_name("Halo The Master Chief Collection.farm")).is_symlink(), "the link is kept")
        manifest = (self.steamapps / "appmanifest_976730.acf").read_text()
        self.assertEqual(adopt.value(manifest, ("AppState",), "StateFlags"), "1026")
        backup = self.steamapps.parent / "caboose-adopted" / "appmanifest_976730.acf"
        self.assertEqual(backup.read_text(), MANIFEST)

    def test_a_real_install_is_left_alone(self):
        adopt.adopt(self.home, 976730)
        with self.assertRaises(SystemExit):
            adopt.adopt(self.home, 976730)

    def test_links_inside_the_farm_are_followed(self):
        adopt.adopt(self.home, 976730)
        game = self.steamapps / "common" / "Halo The Master Chief Collection"
        self.assertFalse((game / "halo3").is_symlink())
        self.assertEqual((game / "halo3" / "halo3.dll").read_bytes(), b"h3")


if __name__ == "__main__":
    unittest.main()
