import copy
import ctypes as C
import unittest

from x11_scroll_xi2 import (BaselineConsumer, Cookie, DeviceChanged, DeviceEvent, DeviceInfo,
                            Mask, ScrollClass, ValuatorClass, ValuatorState,
                            assert_wheel_delta, pointer_mask, unpack_valuators, wheel_sample)


class XI2FixtureTests(unittest.TestCase):
    def setUp(self):
        self.devices = [dict(device=7, scroll=[dict(number=3, scroll_type=1, increment=1.0,
                                                   flags=2, source=7)], valuators={})]

    def motion(self, value):
        return dict(kind='XI', type=6, device=2, source=7, valuators={0: 64.0, 3: value})

    def switch(self, source):
        return dict(kind='changed', type=1, device=2, source=source, reason=1)

    def test_mask_has_no_keys_or_raw_events(self):
        self.assertEqual(pointer_mask(), bytes([0x72]))
        self.assertEqual([n for n in range(8) if pointer_mask()[0] & (1 << n)], [1, 4, 5, 6])

    def test_packed_valuator_order_across_mask_bytes(self):
        self.assertEqual(unpack_valuators(bytes([0x89, 0x02]), [1.5, -3, 7, 9]),
                         {0: 1.5, 3: -3, 7: 7, 9: 9})
        with self.assertRaises(AssertionError):
            unpack_valuators(bytes([0x08]), [])
        with self.assertRaises(AssertionError):
            unpack_valuators(bytes([0x08]), [float('nan')])

    def test_delta_uses_vertical_class_increment_and_event_values(self):
        first = wheel_sample([self.motion(25)], self.devices)
        second = wheel_sample([self.motion(26)], self.devices)
        self.assertEqual(assert_wheel_delta(first, second), 1)
        with self.assertRaises(AssertionError):
            assert_wheel_delta(first, wheel_sample([self.motion(27)], self.devices))
        with self.assertRaises(AssertionError):
            wheel_sample([self.motion(25), self.motion(26)], self.devices)
        changed = copy.deepcopy(second)
        changed['source'] = 6
        with self.assertRaises(AssertionError):
            assert_wheel_delta(first, changed)

    def test_switching_source_loses_every_delta_despite_advancing_valuator(self):
        consumer = BaselineConsumer(self.devices)
        for value in (25, 26, 27):
            self.assertEqual(consumer.consume([self.switch(6), self.switch(7), self.motion(value)]), [0])

    def test_stable_source_consumes_delta_after_initial_baseline(self):
        consumer = BaselineConsumer(self.devices)
        self.assertEqual(consumer.consume([self.switch(7), self.motion(25)]), [0])
        self.assertEqual(consumer.consume([self.motion(26)]), [-1])
        self.assertEqual(consumer.consume([self.motion(27)]), [-1])

    def test_lp64_layouts_match_xlib_and_xinput2(self):
        if C.sizeof(C.c_void_p) != 8:
            self.skipTest('LP64 ABI check')
        for cls, size in [(Cookie, 56), (Mask, 16), (ValuatorState, 24), (DeviceEvent, 200),
                          (DeviceChanged, 72), (DeviceInfo, 40), (ScrollClass, 32), (ValuatorClass, 56)]:
            self.assertEqual(C.sizeof(cls), size, cls.__name__)
        self.assertEqual(Cookie.data.offset, 48)
        self.assertEqual(DeviceEvent.event.offset, 72)
        self.assertEqual(DeviceEvent.valuators.offset, 144)
        self.assertEqual(DeviceEvent.source.offset, 52)
        self.assertEqual(DeviceChanged.classes.offset, 64)
        self.assertEqual(ScrollClass.increment.offset, 16)
        self.assertEqual(ValuatorClass.value.offset, 40)


if __name__ == '__main__':
    unittest.main()
