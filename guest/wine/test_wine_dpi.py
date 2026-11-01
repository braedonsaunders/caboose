#!/usr/bin/env python3
"""Tests for caboose-wine-dpi: python3 -m unittest guest/wine/test_wine_dpi.py"""
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("wine_dpi", str(HERE / "caboose-wine-dpi"))
spec = importlib.util.spec_from_loader("wine_dpi", loader)
wine_dpi = importlib.util.module_from_spec(spec)
loader.exec_module(wine_dpi)

USER_REG = """WINE REGISTRY Version 2
;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

#arch=win64

[Control Panel\\\\Colors] 1730000000
#time=1db2a0b0c0d0e0f
"ActiveBorder"="212 208 200"

[Control Panel\\\\Desktop] 1730000000
#time=1db2a0b0c0d0e0f
"ActiveWndTrkTimeout"=dword:00000000
"FontSmoothing"="2"

[Software\\\\Wine] 1730000000
#time=1db2a0b0c0d0e0f
"Version"="win10"
"""


class Registry(unittest.TestCase):
    def test_adds_log_pixels_to_the_desktop_section(self):
        out = wine_dpi.with_log_pixels(USER_REG, 288)
        self.assertIn('"FontSmoothing"="2"\n"LogPixels"=dword:00000120\n\n[Software\\\\Wine]', out)
        self.assertEqual(out.replace('"LogPixels"=dword:00000120\n', ""), USER_REG)

    def test_replaces_and_keeps(self):
        once = wine_dpi.with_log_pixels(USER_REG, 288)
        self.assertEqual(wine_dpi.with_log_pixels(once, 288), once)
        twice = wine_dpi.with_log_pixels(once, 144)
        self.assertEqual(twice.count("LogPixels"), 1)
        self.assertIn('"LogPixels"=dword:00000090', twice)

    def test_adds_the_section_when_missing(self):
        text = USER_REG.replace("[Control Panel\\\\Desktop]", "[Control Panel\\\\Mouse]")
        out = wine_dpi.with_log_pixels(text, 192)
        self.assertTrue(out.startswith(text))
        self.assertTrue(out.endswith('\n\n[Control Panel\\\\Desktop] 0\n"LogPixels"=dword:000000c0\n'))
        self.assertEqual(wine_dpi.with_log_pixels(out, 192), out)

    def test_last_section_without_trailing_blank_line(self):
        text = "WINE REGISTRY Version 2\n\n[Control Panel\\\\Desktop] 1\n\"A\"=\"b\""
        out = wine_dpi.with_log_pixels(text, 96)
        self.assertEqual(out, text + '\n"LogPixels"=dword:00000060')


class GameDesktop(unittest.TestCase):
    def test_landscape_and_at_least_1920x1080(self):
        self.assertEqual(wine_dpi.game_desktop((932, 1356)), (1920, 1080))
        self.assertEqual(wine_dpi.game_desktop((1338, 911)), (1920, 1080))
        self.assertEqual(wine_dpi.game_desktop((1290, 2796)), (2796, 1290))
        self.assertEqual(wine_dpi.game_desktop((0, 0)), (1920, 1080))

    def test_only_below_1280x720(self):
        self.assertTrue(wine_dpi.needs_desktop((932, 1356)))
        self.assertTrue(wine_dpi.needs_desktop((1338, 700)))
        self.assertFalse(wine_dpi.needs_desktop((1338, 911)))
        self.assertFalse(wine_dpi.needs_desktop((1280, 720)))

    def test_no_desktop_removes_only_its_value(self):
        text = '[Software\\\\Wine\\\\Explorer] 1\n"Desktop"="Default"\n"Other"="x"\n\n[B] 1\n"Desktop"="keep"\n'
        out = wine_dpi.with_game_settings(text, None)
        self.assertIn('[Software\\\\Wine\\\\Explorer] 1\n"Other"="x"\n\n[B] 1\n"Desktop"="keep"\n', out)
        self.assertEqual(wine_dpi.with_game_settings(out, None), out)

    def test_sections_are_matched_whole(self):
        text = '[Software\\\\Wine\\\\Explorer\\\\Desktops] 1\n"Default"="800x600"\n'
        out = wine_dpi.with_game_settings(text, (1920, 1080))
        self.assertIn('[Software\\\\Wine\\\\Explorer\\\\Desktops] 1\n"Default"="1920x1080"\n', out)
        self.assertIn('[Software\\\\Wine\\\\Explorer] 0\n"Desktop"="Default"\n', out)
        self.assertEqual(wine_dpi.with_game_settings(out, (1920, 1080)), out)


class Density(unittest.TestCase):
    def test_xft_dpi_to_log_pixels(self):
        self.assertEqual(wine_dpi.dpi_for(96 * 1024), 96)
        self.assertEqual(wine_dpi.dpi_for(288 * 1024), 288)
        self.assertEqual(wine_dpi.dpi_for(round(96 * 1.22 * 1024)), 117)
        self.assertEqual(wine_dpi.dpi_for(0), 96)
        self.assertEqual(wine_dpi.dpi_for(-1), 96)
        self.assertEqual(wine_dpi.dpi_for(10 ** 9), 480)


class Prefixes(unittest.TestCase):
    def make_prefix(self, path):
        path.mkdir(parents=True)
        (path / "user.reg").write_text(USER_REG)
        return path

    def test_finds_every_kind_and_writes_them(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as library:
            home = Path(home)
            wine = self.make_prefix(home / ".wine")
            tricks = self.make_prefix(home / ".local/share/wineprefixes/office")
            steam = home / wine_dpi.STEAM_ROOTS[0]
            game = self.make_prefix(steam / "steamapps/compatdata/976730/pfx")
            (steam / "steamapps/compatdata/1/pfx").mkdir(parents=True)  # not yet made: no user.reg
            other = self.make_prefix(Path(library) / "steamapps/compatdata/42/pfx")
            (steam / "steamapps/libraryfolders.vdf").write_text(
                '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n'
                % (steam, library))
            found = wine_dpi.prefixes(home)
            self.assertEqual(found, [(wine, False), (tricks, False), (game, True), (other, True)])
            # A game prefix the display's DPI reached earlier goes back to 96.
            wine_dpi.apply(game, 192)
            self.assertEqual(wine_dpi.apply_all(home, 288, (932, 1356)), [wine, tricks, game, other])
            for prefix in (wine, tricks):
                text = (prefix / "user.reg").read_text()
                self.assertIn('"LogPixels"=dword:00000120', text)
                self.assertNotIn("Explorer", text)
            for prefix in (game, other):
                text = (prefix / "user.reg").read_text()
                self.assertIn('"LogPixels"=dword:00000060', text)
                self.assertIn('[Software\\\\Wine\\\\Explorer] 0\n"Desktop"="Default"\n', text)
                self.assertIn('[Software\\\\Wine\\\\Explorer\\\\Desktops] 0\n"Default"="1920x1080"\n', text)
            self.assertEqual(wine_dpi.apply_all(home, 288, (932, 1356)), [])
            # On a display games accept, the virtual desktop goes; the DPI stays 96.
            self.assertEqual(wine_dpi.apply_all(home, 192, (1338, 911)), [wine, tricks, game, other])
            for prefix in (game, other):
                text = (prefix / "user.reg").read_text()
                self.assertNotIn('"Desktop"=', text)
                self.assertIn('"LogPixels"=dword:00000060', text)
            self.assertEqual(wine_dpi.apply_all(home, 192, (1338, 911)), [])

    def test_keeps_the_file_mode(self):
        with tempfile.TemporaryDirectory() as home:
            prefix = self.make_prefix(Path(home) / ".wine")
            (prefix / "user.reg").chmod(0o600)
            self.assertTrue(wine_dpi.apply(prefix, 192))
            self.assertEqual((prefix / "user.reg").stat().st_mode & 0o777, 0o600)

    def test_display_environment(self):
        with tempfile.TemporaryDirectory() as d:
            env = Path(d, "display.env")
            env.write_text("WAYLAND_DISPLAY='w'\nDISPLAY=':110'\nXAUTHORITY='/run/x/Xauthority'\n")
            self.assertEqual(wine_dpi.display_environment(env), {"DISPLAY": ":110", "XAUTHORITY": "/run/x/Xauthority"})


if __name__ == "__main__":
    unittest.main()
