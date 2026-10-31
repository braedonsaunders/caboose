import errno
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'broker'))
import buffer_presentation as b
from live_surface_protocol import validate_surface


IMAGE = b.Image(instance=1, device=2, queue=3, image=4, vk_format=44, width=1280, height=720, queue_family=0)


def frame(request, process=7, image=IMAGE):
    return b.Frame(request, process, image)


class RecordTests(unittest.TestCase):
    def test_registration_round_trip_and_rejection(self):
        self.assertEqual(b.decode_register(b.encode_register(IMAGE)), IMAGE)
        for bad in (IMAGE.__class__(0, 2, 3, 4, 44, 1, 1, 0), IMAGE.__class__(1, 2, 3, 4, 44, 0, 1, 0)):
            with self.assertRaises(ValueError): b.decode_register(b.encode_register(bad))
        with self.assertRaises(ValueError): b.decode_register(b.encode_register(IMAGE)[:-1])
        self.assertEqual(b.decode_forget(bytes(8) + (9).to_bytes(8, 'little')), (0, 9))
        with self.assertRaises(ValueError): b.decode_forget(bytes(16))

    def test_present_body_is_a_valid_plain_present(self):
        identity = b'e' * 16 + b'g' * 16 + (3).to_bytes(8, 'little')
        validate_surface(20, identity + b.present_body(5, IMAGE))


class RegistryTests(unittest.TestCase):
    def test_buffers_belong_to_their_registering_connection(self):
        registry = b.Registry()
        registry.register('a', 7, (1, 9), IMAGE)
        self.assertEqual(registry.lookup((1, 9)), (7, IMAGE))
        # The first image bound to a buffer stays its image.
        registry.register('a', 7, (1, 9), IMAGE.__class__(1, 2, 3, 5, 44, 1280, 720, 0))
        self.assertEqual(registry.lookup((1, 9))[1].image, 4)
        with self.assertRaises(ValueError): registry.register('b', 8, (1, 9), IMAGE)
        registry.forget('b', (1, 9))
        self.assertIsNotNone(registry.lookup((1, 9)))
        registry.register('a', 7, (1, 10), IMAGE)
        registry.drop('a')
        self.assertIsNone(registry.lookup((1, 9)))
        self.assertIsNone(registry.lookup((1, 10)))

    def test_registrations_are_bounded_per_connection(self):
        registry = b.Registry()
        for inode in range(b.MAX_BUFFERS_PER_PROCESS):
            registry.register('a', 7, (1, inode + 1), IMAGE)
        with self.assertRaises(ValueError): registry.register('a', 7, (1, 0), IMAGE)
        registry.register('b', 8, (2, 1), IMAGE)


class WindowTests(unittest.TestCase):
    def bound(self):
        window = b.Window(5)
        self.assertEqual(window.offer(frame(1)), 'bind')
        self.assertEqual(window.bind_finished(('k',), True), 'send')
        self.assertEqual(window.in_flight.request, 1)
        return window

    def test_one_frame_in_flight_newest_waiting(self):
        window = self.bound()
        self.assertIsNone(window.offer(frame(2)))
        self.assertIsNone(window.offer(frame(3)))
        # The replaced commit is released unshown.
        self.assertEqual(window.take_released(), [(2, errno.ECANCELED)])
        self.assertEqual(window.source_released(1), 'send')
        self.assertEqual(window.take_released(), [(1, 0)])
        self.assertEqual((window.in_flight.request, window.in_flight.serial), (3, 2))
        self.assertIsNone(window.source_released(1))  # stale serial
        self.assertIsNone(window.source_released(2))
        self.assertEqual(window.take_released(), [(3, 0)])

    def test_busy_native_surface_retries_the_same_frame_unless_superseded(self):
        window = self.bound()
        self.assertEqual(window.result(1, True, errno.EBUSY), 'retry')
        self.assertEqual(window.next_present(), 'send')
        self.assertEqual((window.in_flight.request, window.in_flight.serial, window.in_flight.retries), (1, 2, 1))
        window.offer(frame(2))
        # A newer commit replaces a busy frame instead of retrying it.
        self.assertEqual(window.result(2, True, errno.EBUSY), 'send')
        self.assertEqual(window.take_released(), [(1, errno.EBUSY)])
        self.assertEqual(window.in_flight.request, 2)
        self.assertEqual(window.result(3, True, errno.EINVAL), None)
        self.assertEqual(window.take_released(), [(2, errno.EINVAL)])
        self.assertIsNone(window.in_flight)

    def test_retries_are_bounded(self):
        window = self.bound()
        for _ in range(b.MAX_RETRIES):
            self.assertEqual(window.result(window.in_flight.serial, True, errno.EBUSY), 'retry')
            window.next_present()
        self.assertIsNone(window.result(window.in_flight.serial, True, errno.EBUSY))
        self.assertEqual(window.take_released(), [(1, errno.EBUSY)])

    def test_accepted_submission_waits_for_source_release(self):
        window = self.bound()
        self.assertIsNone(window.result(1, False, 0))
        self.assertIsNotNone(window.in_flight)
        self.assertEqual(window.take_released(), [])

    def test_new_process_or_size_retires_and_rebinds(self):
        window = self.bound()
        resized = IMAGE.__class__(1, 2, 3, 6, 44, 1920, 1080, 0)
        self.assertEqual(window.offer(frame(2, image=resized)), 'retire')
        self.assertIsNone(window.offer(frame(3, image=resized)))
        self.assertEqual(window.take_released(), [(2, errno.ECANCELED)])
        self.assertEqual(window.retired(), 'bind')
        self.assertEqual(window.take_released(), [(1, errno.ECANCELED)])
        self.assertEqual(window.extent, (1920, 1080))
        self.assertEqual(window.bind_finished(('k2',), True), 'send')
        self.assertEqual(window.in_flight.request, 3)

    def test_failed_bind_releases_and_retires_its_grant(self):
        window = b.Window(5)
        window.offer(frame(1))
        self.assertIsNone(window.offer(frame(2)))  # still binding
        self.assertEqual(window.bind_finished(('k',), False), 'retire')
        self.assertEqual(window.take_released(), [(1, errno.ECANCELED), (2, errno.EIO)])
        self.assertIsNone(window.retired())
        window = b.Window(6)
        window.offer(frame(3))
        self.assertIsNone(window.bind_finished(None, False))
        self.assertEqual(window.take_released(), [(3, errno.EIO)])


if __name__ == '__main__': unittest.main()
