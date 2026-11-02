#!/usr/bin/env python3
"""Tests for caboose-wine-dpi: python3 -m unittest guest/wine/test_wine_dpi.py"""
import importlib.machinery
import importlib.util
import os
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
    def test_adds_96_dpi_to_the_desktop_section(self):
        out = wine_dpi.with_settings(USER_REG, None)
        self.assertIn('"FontSmoothing"="2"\n"LogPixels"=dword:00000060\n\n[Software\\\\Wine]', out)
        self.assertEqual(out.replace('"LogPixels"=dword:00000060\n', ""), USER_REG)
        self.assertEqual(wine_dpi.with_settings(out, None), out)

    def test_replaces_another_dpi(self):
        text = USER_REG.replace('"FontSmoothing"="2"', '"FontSmoothing"="2"\n"LogPixels"=dword:000000c0')
        out = wine_dpi.with_settings(text, None)
        self.assertEqual(out.count("LogPixels"), 1)
        self.assertIn('"LogPixels"=dword:00000060', out)

    def test_adds_the_section_when_missing(self):
        text = USER_REG.replace("[Control Panel\\\\Desktop]", "[Control Panel\\\\Mouse]")
        out = wine_dpi.with_settings(text, None)
        self.assertTrue(out.endswith('\n\n[Control Panel\\\\Desktop] 0\n"LogPixels"=dword:00000060\n'))


class VirtualDesktop(unittest.TestCase):
    def test_landscape_and_at_least_1920x1080(self):
        self.assertEqual(wine_dpi.virtual_desktop((932, 1356)), (1920, 1080))
        self.assertEqual(wine_dpi.virtual_desktop((1290, 2796)), (2796, 1290))

    def test_only_below_1280x720(self):
        self.assertTrue(wine_dpi.needs_desktop((932, 1356)))
        self.assertTrue(wine_dpi.needs_desktop((1338, 700)))
        self.assertFalse(wine_dpi.needs_desktop((1338, 911)))
        self.assertFalse(wine_dpi.needs_desktop((1280, 720)))

    def test_no_desktop_removes_only_its_value(self):
        text = '[Software\\\\Wine\\\\Explorer] 1\n"Desktop"="Default"\n"Other"="x"\n\n[B] 1\n"Desktop"="keep"\n'
        out = wine_dpi.with_settings(text, None)
        self.assertIn('[Software\\\\Wine\\\\Explorer] 1\n"Other"="x"\n\n[B] 1\n"Desktop"="keep"\n', out)

    def test_sections_are_matched_whole(self):
        text = '[Software\\\\Wine\\\\Explorer\\\\Desktops] 1\n"Default"="800x600"\n'
        out = wine_dpi.with_settings(text, (1920, 1080))
        self.assertIn('[Software\\\\Wine\\\\Explorer\\\\Desktops] 1\n"Default"="1920x1080"\n', out)
        self.assertIn('[Software\\\\Wine\\\\Explorer] 0\n"Desktop"="Default"\n', out)
        self.assertEqual(wine_dpi.with_settings(out, (1920, 1080)), out)


class Prefixes(unittest.TestCase):
    def make_prefix(self, path):
        path.mkdir(parents=True)
        (path / "user.reg").write_text(USER_REG)
        return path

    def test_every_prefix_gets_the_same_settings(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as elsewhere:
            home = Path(home)
            wine = self.make_prefix(home / ".wine")
            tricks = self.make_prefix(home / ".local/share/wineprefixes/office")
            seen = self.make_prefix(Path(elsewhere) / "game/pfx")
            (Path(elsewhere) / "unmade").mkdir()  # named by a process, no user.reg yet
            known = {seen, Path(elsewhere) / "unmade"}
            self.assertEqual(wine_dpi.prefixes(home, known), [wine, tricks, seen])
            self.assertEqual(wine_dpi.apply_all(home, (932, 1356), known), [wine, tricks, seen])
            for prefix in (wine, tricks, seen):
                text = (prefix / "user.reg").read_text()
                self.assertIn('"LogPixels"=dword:00000060', text)
                self.assertIn('[Software\\\\Wine\\\\Explorer\\\\Desktops] 0\n"Default"="1920x1080"\n', text)
            self.assertEqual(wine_dpi.apply_all(home, (932, 1356), known), [])
            self.assertEqual(wine_dpi.apply_all(home, (1338, 911), known), [wine, tricks, seen])
            for prefix in (wine, tricks, seen):
                self.assertNotIn('"Desktop"=', (prefix / "user.reg").read_text())

    def test_prefixes_are_remembered(self):
        with tempfile.TemporaryDirectory() as home:
            wine_dpi.remember(home, {Path("/a/pfx"), Path("/b")})
            self.assertEqual(wine_dpi.remembered(home), {Path("/a/pfx"), Path("/b")})

    def test_running_processes_name_their_prefixes(self):
        with tempfile.TemporaryDirectory() as proc:
            for pid, environ in (("10", b"HOME=/h\0WINEPREFIX=/games/x/pfx\0"), ("11", b"WINEPREFIX=relative\0"),
                                 ("self", b"WINEPREFIX=/not/a/pid\0")):
                Path(proc, pid).mkdir()
                Path(proc, pid, "environ").write_bytes(environ)
            self.assertEqual(wine_dpi.running_prefixes(proc), {Path("/games/x/pfx")})

    def test_keeps_the_file_mode(self):
        with tempfile.TemporaryDirectory() as home:
            prefix = self.make_prefix(Path(home) / ".wine")
            (prefix / "user.reg").chmod(0o600)
            self.assertTrue(wine_dpi.apply(prefix))
            self.assertEqual((prefix / "user.reg").stat().st_mode & 0o777, 0o600)

    def test_display_environment(self):
        with tempfile.TemporaryDirectory() as d:
            env = Path(d, "display.env")
            env.write_text("WAYLAND_DISPLAY='w'\nDISPLAY=':110'\nXAUTHORITY='/run/x/Xauthority'\n")
            self.assertEqual(wine_dpi.display_environment(env), {"DISPLAY": ":110", "XAUTHORITY": "/run/x/Xauthority"})


if __name__ == "__main__":
    unittest.main()
