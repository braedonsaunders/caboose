#!/usr/bin/env python3
"""Tests for caboose-steam-defaults: python3 -m unittest guest/flatpak/test_steam_defaults.py"""
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("steam_defaults", str(HERE / "caboose-steam-defaults"))
spec = importlib.util.spec_from_loader("steam_defaults", loader)
steam_defaults = importlib.util.module_from_spec(spec)
loader.exec_module(steam_defaults)

CONFIG = '''"InstallConfigStore"
{
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"ShaderCacheManager"
\t\t\t\t{
\t\t\t\t\t"HasCurrentBucket"\t\t"1"
\t\t\t\t}
\t\t\t\t"CompatToolMapping"
\t\t\t\t{
\t\t\t\t}
\t\t\t}
\t\t}
\t}
\t"Music"
\t{
\t\t"LocalLibraryRoots"\t\t"{}"
\t}
}
'''


def steam_block(text):
    block = steam_defaults.parse(text)
    for key in steam_defaults.STEAM_PATH:
        block = block.blocks[key]
    return block


def value(text, key):
    start, end = steam_block(text).values[key]
    return text[start + 1:end - 1]


class WithDefaults(unittest.TestCase):
    def test_adds_the_value_inside_steam_keeping_everything_else(self):
        out = steam_defaults.with_defaults(CONFIG)
        self.assertEqual(value(out, "DisableShaderCache"), "1")
        self.assertIn('\t\t\t\t\t"DisableShaderCache"\t\t"1"\n\t\t\t\t}', out)
        self.assertEqual(out.replace('\t\t\t\t\t"DisableShaderCache"\t\t"1"\n', ""), CONFIG)
        self.assertEqual(steam_block(out).values.keys(), {"HasCurrentBucket", "DisableShaderCache"})

    def test_replaces_a_value_the_owner_changed(self):
        changed = steam_defaults.with_defaults(CONFIG).replace('"DisableShaderCache"\t\t"1"', '"DisableShaderCache"\t\t"0"')
        out = steam_defaults.with_defaults(changed)
        self.assertEqual(value(out, "DisableShaderCache"), "1")
        self.assertEqual(out.count("DisableShaderCache"), 1)

    def test_is_idempotent(self):
        once = steam_defaults.with_defaults(CONFIG)
        self.assertEqual(steam_defaults.with_defaults(once), once)

    def test_makes_missing_blocks(self):
        for text in ("", '"InstallConfigStore"\n{\n}\n', '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t}\n}\n',
                     '"InstallConfigStore" { "Software" { } }'):
            out = steam_defaults.with_defaults(text)
            self.assertEqual(value(out, "DisableShaderCache"), "1", text)
            self.assertEqual(steam_defaults.with_defaults(out), out)

    def test_braces_inside_strings_and_comments_are_not_blocks(self):
        text = '// a comment with { and "quotes\n' + CONFIG
        out = steam_defaults.with_defaults(text)
        self.assertEqual(value(out, "DisableShaderCache"), "1")
        self.assertTrue(out.startswith('// a comment with { and "quotes\n'))

    def test_refuses_malformed_files(self):
        for text in ('"a"\n{\n', '"a"\n}\n', '"a" "b" "c"', '"a\n'):
            with self.assertRaises(ValueError, msg=text):
                steam_defaults.with_defaults(text)


def fake_proc(root, programs):
    """A /proc with one process per program, owned by this user."""
    for pid, program in enumerate(programs, 100):
        Path(root, str(pid)).mkdir()
        Path(root, str(pid), "cmdline").write_bytes(program.encode() + b"\0-silent\0")
    Path(root, "self").mkdir()
    return Path(root)


class Apply(unittest.TestCase):
    def setUp(self):
        self.proc_dir = tempfile.TemporaryDirectory()
        self.proc = fake_proc(self.proc_dir.name, ["/usr/bin/bash"])

    def tearDown(self):
        self.proc_dir.cleanup()

    def test_leaves_a_running_steam_alone(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as proc:
            config = Path(home, steam_defaults.STEAM_DIRS[0], "config")
            config.mkdir(parents=True)
            (config / "config.vdf").write_text(CONFIG)
            running = fake_proc(proc, [f"{home}/{steam_defaults.STEAM_DIRS[0]}/steamrt64/steam"])
            self.assertTrue(steam_defaults.steam_running(home, running))
            steam_defaults.apply(home, running)
            self.assertEqual((config / "config.vdf").read_text(), CONFIG)
            # Another user's home, or a program that is not Steam, does not count.
            self.assertFalse(steam_defaults.steam_running("/home/other", running))
            self.assertFalse(steam_defaults.steam_running(home, self.proc))

    def test_writes_where_steam_has_a_config_directory(self):
        with tempfile.TemporaryDirectory() as home:
            flatpak = Path(home, steam_defaults.STEAM_DIRS[0], "config")
            flatpak.mkdir(parents=True)
            (flatpak / "config.vdf").write_text(CONFIG)
            self.assertEqual(steam_defaults.apply(home, self.proc), 0)
            self.assertEqual(value((flatpak / "config.vdf").read_text(), "DisableShaderCache"), "1")
            # No native Steam directory: nothing is made there.
            self.assertFalse(Path(home, steam_defaults.STEAM_DIRS[1]).exists())

    def test_a_config_directory_without_the_file_gets_one(self):
        with tempfile.TemporaryDirectory() as home:
            config = Path(home, steam_defaults.STEAM_DIRS[1], "config")
            config.mkdir(parents=True)
            steam_defaults.apply(home, self.proc)
            self.assertEqual(value((config / "config.vdf").read_text(), "DisableShaderCache"), "1")


if __name__ == "__main__":
    unittest.main()
