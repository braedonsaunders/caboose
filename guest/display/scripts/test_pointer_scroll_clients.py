import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    'pointer_scroll_clients', Path(__file__).with_name('check-pointer-scroll-clients.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class PointerScrollFixtureTests(unittest.TestCase):
    def test_encoded_frame_ack_preserves_identity_and_timestamp(self):
        self.assertEqual(fixture.frame_ack(0x10, dict(id=7, pts_us=123456)),
                         dict(id=7, pts_us=123456, decoded_us=0))

    def test_tile_without_timestamp_never_generates_frame_ack(self):
        self.assertIsNone(fixture.frame_ack(0x11, dict(
            id=7, rect=[0, 0, 32, 32], format='png', data=b'fixture')))

    def test_other_messages_never_generate_frame_ack(self):
        for kind in range(256):
            if kind != 0x10:
                self.assertIsNone(fixture.frame_ack(kind, dict(id=7, pts_us=123456)))


if __name__ == '__main__':
    unittest.main()
