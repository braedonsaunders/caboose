#!/usr/bin/env python3
"""Unit tests for caboose-gpu-run: CBOR, framing, the stream environment and the
architecture guard. No display, socket or Vulkan is needed."""
import importlib.machinery
import importlib.util
import os
import pathlib
import struct
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader('caboose_gpu_run', str(HERE / 'caboose-gpu-run'))
spec = importlib.util.spec_from_loader('caboose_gpu_run', loader)
run = importlib.util.module_from_spec(spec)
loader.exec_module(run)


def elf(machine):
    return b'\x7fELF' + bytes(14) + struct.pack('<H', machine) + bytes(44)


class Cbor(unittest.TestCase):
    def test_maps_are_canonical_and_round_trip(self):
        hello = {'version': 1, 'title': 'vkcube', 'app_id': 'vkcube', 'stream': '/run/user/1000/caboose-gpu/7.gfxr'}
        encoded = run.cbor(hello)
        # Shorter keys first, then bytewise: "title" (5) and "app_id" (6) before "stream" and "version".
        self.assertEqual(encoded[1:7], b'\x65title')
        self.assertEqual(run.uncbor(encoded)[0], hello)

    def test_a_message_is_type_length_payload(self):
        framed = run.message(run.HELLO, {'version': 1})
        self.assertEqual(framed[0], run.HELLO)
        self.assertEqual(struct.unpack_from('<I', framed, 1)[0], len(framed) - 5)


class Environment(unittest.TestCase):
    def test_the_stream_renders_nothing_here_and_uses_x11(self):
        with tempfile.TemporaryDirectory() as lib:
            with mock.patch.object(run, 'LIB', pathlib.Path(lib)), mock.patch.dict(os.environ, {'WAYLAND_DISPLAY': 'w'}):
                env = run.stream_env('/run/user/1000/caboose-gpu/7.gfxr')
        self.assertEqual(env['VK_ICD_FILENAMES'], f'{lib}/icd.json')
        self.assertEqual(env['GFXRECON_CAPTURE_FILE'], '/run/user/1000/caboose-gpu/7.gfxr')
        self.assertEqual(env['GFXRECON_CAPTURE_COMPRESSION_TYPE'], 'NONE')
        self.assertNotIn('WAYLAND_DISPLAY', env)
        self.assertNotIn('VK_KHRONOS_PROFILES_PROFILE_FILE', env)

    def test_an_installed_profile_shows_the_client_gpu(self):
        with tempfile.TemporaryDirectory() as lib:
            (pathlib.Path(lib) / 'profile.json').write_text('{}')
            with mock.patch.object(run, 'LIB', pathlib.Path(lib)):
                env = run.stream_env('/x.gfxr')
        self.assertTrue(env['VK_INSTANCE_LAYERS'].endswith(':VK_LAYER_KHRONOS_profiles'))
        self.assertEqual(env['VK_KHRONOS_PROFILES_PROFILE_FILE'], f'{lib}/profile.json')


class Architecture(unittest.TestCase):
    def check(self, machine, uname):
        with tempfile.TemporaryDirectory() as lib:
            if machine is not None:
                (pathlib.Path(lib) / 'libVkICD_mock_icd.so').write_bytes(elf(machine))
            with mock.patch.object(run.os, 'uname', return_value=mock.Mock(machine=uname)):
                return run.built_here(pathlib.Path(lib))

    def test_a_driver_for_this_machine_is_used(self):
        self.assertTrue(self.check(62, 'x86_64'))
        self.assertTrue(self.check(183, 'aarch64'))

    def test_a_driver_for_another_machine_or_none_is_not(self):
        self.assertFalse(self.check(183, 'x86_64'))
        self.assertFalse(self.check(62, 'aarch64'))
        self.assertFalse(self.check(None, 'x86_64'))
        self.assertFalse(self.check(62, 'riscv64'))


if __name__ == '__main__':
    unittest.main()
