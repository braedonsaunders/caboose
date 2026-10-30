"""XI2 support for the disposable, owned-window scroll fixture only.

ctypes layouts follow XInput2.h and Xlib.h (LP64). No device names, keys,
window text or foreign-window selections are retained.
"""
import ctypes as C
import math

P, U, I, B = C.c_void_p, C.c_ulong, C.c_int, C.c_ubyte


class Cookie(C.Structure):
    _fields_ = [('type', I), ('serial', U), ('send', I), ('display', P),
                ('extension', I), ('evtype', I), ('cookie', C.c_uint), ('data', P)]


class Mask(C.Structure):
    _fields_ = [('device', I), ('length', I), ('mask', C.POINTER(B))]


class ButtonState(C.Structure):
    _fields_ = [('length', I), ('mask', C.POINTER(B))]


class ValuatorState(C.Structure):
    _fields_ = [('length', I), ('mask', C.POINTER(B)), ('values', C.POINTER(C.c_double))]


class Modifiers(C.Structure):
    _fields_ = [('base', I), ('latched', I), ('locked', I), ('effective', I)]


class DeviceEvent(C.Structure):
    _fields_ = [('type', I), ('serial', U), ('send', I), ('display', P),
                ('extension', I), ('evtype', I), ('time', U), ('device', I),
                ('source', I), ('detail', I), ('root', U), ('event', U), ('child', U),
                ('root_x', C.c_double), ('root_y', C.c_double),
                ('event_x', C.c_double), ('event_y', C.c_double), ('flags', I),
                ('buttons', ButtonState), ('valuators', ValuatorState),
                ('mods', Modifiers), ('group', Modifiers)]


class AnyClass(C.Structure):
    _fields_ = [('type', I), ('source', I)]


class ScrollClass(C.Structure):
    _fields_ = [('type', I), ('source', I), ('number', I), ('scroll_type', I),
                ('increment', C.c_double), ('flags', I)]


class ValuatorClass(C.Structure):
    _fields_ = [('type', I), ('source', I), ('number', I), ('label', U),
                ('min', C.c_double), ('max', C.c_double), ('value', C.c_double),
                ('resolution', I), ('mode', I)]


class DeviceInfo(C.Structure):
    _fields_ = [('device', I), ('name', P), ('use', I), ('attachment', I),
                ('enabled', I), ('nclasses', I), ('classes', C.POINTER(C.POINTER(AnyClass)))]


class DeviceChanged(C.Structure):
    _fields_ = [('type', I), ('serial', U), ('send', I), ('display', P),
                ('extension', I), ('evtype', I), ('time', U), ('device', I),
                ('source', I), ('reason', I), ('nclasses', I),
                ('classes', C.POINTER(C.POINTER(AnyClass)))]


def pointer_mask():
    # XI_DeviceChanged plus pointer buttons/motion; no key or raw events.
    return bytes([sum(1 << n for n in (1, 4, 5, 6))])


def unpack_valuators(mask, packed_values):
    axes = [n for n in range(len(mask) * 8) if mask[n // 8] & (1 << (n % 8))]
    assert len(axes) == len(packed_values), 'Valuator mask/value length mismatch'
    assert all(math.isfinite(v) for v in packed_values), 'Non-finite valuator'
    return dict(zip(axes, packed_values))


def wheel_sample(events, devices):
    """Extract one actual XI scroll value and its advertised increment."""
    samples = []
    for event in events:
        if event['kind'] != 'XI' or event['type'] != 6:
            continue
        device = next(d for d in devices if d['device'] == event['source'])
        for axis in device['scroll']:
            if axis['scroll_type'] != 1 or axis['number'] not in event['valuators']:
                continue
            number = axis['number']
            value = event['valuators'][number]
            increment = axis['increment']
            assert increment != 0 and math.isfinite(increment)
            samples.append(dict(device=event['device'], source=event['source'], axis=number,
                                increment=increment, value=value, flags=axis['flags']))
    assert len(samples) == 1, f'Expected exactly one vertical scroll motion, got {samples}'
    return samples[0]


def assert_wheel_delta(first, second):
    for key in ('device', 'source', 'axis', 'increment', 'flags'):
        assert first[key] == second[key], f'Scroll class/source changed: {key}'
    delta = second['value'] - first['value']
    assert math.isclose(delta, second['increment'], rel_tol=0, abs_tol=1e-6), (delta, second)
    return delta


class BaselineConsumer:
    """Chromium's SlaveSwitch invalidation and first-sample baseline semantics.

    Mirrors X11EventSource::OnEvent and ExtractAndUpdateScrollOffset, without
    depending on a browser or using its name to change compositor behavior.
    """
    def __init__(self, devices):
        self.axes = {d['device']: a for d in devices for a in d['scroll'] if a['scroll_type'] == 1}
        self.positions = {}

    def consume(self, events):
        offsets = []
        for e in events:
            if e['kind'] == 'changed' and e['reason'] == 1:  # XISlaveSwitch
                self.positions.pop(e['source'], None)
            elif e['kind'] == 'XI' and e['type'] == 6 and e['source'] in self.axes:
                axis = self.axes[e['source']]
                if axis['number'] in e['valuators']:
                    value = e['valuators'][axis['number']]
                    old = self.positions.get(e['source'], value)
                    offsets.append((old - value) / axis['increment'])
                    self.positions[e['source']] = value
        return offsets


class XI2:
    def __init__(self, xlib, display, owned_child):
        self.X, self.display, self.child = xlib, display, owned_child
        self.lib = C.CDLL('libXi.so.6')
        for lib, name, args, result in [
            (self.lib, 'XIQueryVersion', [P, C.POINTER(I), C.POINTER(I)], I),
            (self.lib, 'XISelectEvents', [P, U, C.POINTER(Mask), I], I),
            (self.lib, 'XIQueryDevice', [P, I, C.POINTER(I)], C.POINTER(DeviceInfo)),
            (self.lib, 'XIFreeDeviceInfo', [C.POINTER(DeviceInfo)], None),
            (self.X, 'XQueryExtension', [P, C.c_char_p, C.POINTER(I), C.POINTER(I), C.POINTER(I)], I),
            (self.X, 'XGetEventData', [P, C.POINTER(Cookie)], I),
            (self.X, 'XFreeEventData', [P, C.POINTER(Cookie)], None),
        ]:
            function = getattr(lib, name)
            function.argtypes, function.restype = args, result
        major, minor = I(2), I(1)
        assert self.lib.XIQueryVersion(display, C.byref(major), C.byref(minor)) == 0
        assert (major.value, minor.value) >= (2, 1), 'XI2 smooth scrolling unavailable'
        self.version = [major.value, minor.value]
        opcode, first, error = I(), I(), I()
        assert self.X.XQueryExtension(display, b'XInputExtension', C.byref(opcode),
                                     C.byref(first), C.byref(error))
        self.opcode = opcode.value

    def select_owned(self):
        bits = (B * 1).from_buffer_copy(pointer_mask())
        mask = Mask(1, len(bits), bits)  # XIAllMasterDevices, on our child only.
        assert self.lib.XISelectEvents(self.display, self.child, C.byref(mask), 1) == 0
        self.X.XSync(self.display, 0)

    def devices(self):
        count = I()
        devices = self.lib.XIQueryDevice(self.display, 0, C.byref(count))  # XIAllDevices
        assert devices and 0 < count.value <= 128
        result = []
        try:
            for j in range(count.value):
                d = devices[j]
                if d.use not in (1, 3):  # master/slave pointers only
                    continue
                row = dict(device=d.device, use=d.use, attachment=d.attachment,
                           enabled=bool(d.enabled), scroll=[], valuators={})
                assert 0 <= d.nclasses <= 256
                for k in range(d.nclasses):
                    c = d.classes[k]
                    if c.contents.type == 3:  # XIScrollClass
                        a = C.cast(c, C.POINTER(ScrollClass)).contents
                        row['scroll'].append(dict(source=a.source, number=a.number,
                                                  scroll_type=a.scroll_type,
                                                  increment=a.increment, flags=a.flags))
                    elif c.contents.type == 2:  # XIValuatorClass
                        a = C.cast(c, C.POINTER(ValuatorClass)).contents
                        row['valuators'][a.number] = dict(source=a.source, value=a.value, mode=a.mode)
                result.append(row)
        finally:
            self.lib.XIFreeDeviceInfo(devices)
        return result

    def event(self, event):
        cookie = C.cast(C.byref(event), C.POINTER(Cookie))
        if cookie.contents.extension != self.opcode or cookie.contents.evtype not in (1, 4, 5, 6):
            return None
        assert self.X.XGetEventData(self.display, cookie), 'XI cookie unavailable'
        try:
            if cookie.contents.evtype == 1:
                e = C.cast(cookie.contents.data, C.POINTER(DeviceChanged)).contents
                assert 0 <= e.nclasses <= 256
                classes = []
                for k in range(e.nclasses):
                    c = e.classes[k]
                    if c.contents.type == 3:
                        a = C.cast(c, C.POINTER(ScrollClass)).contents
                        classes.append(dict(source=a.source, number=a.number, scroll_type=a.scroll_type,
                                            increment=a.increment, flags=a.flags))
                return dict(kind='changed', type=1, time=e.time, device=e.device,
                            source=e.source, reason=e.reason, scroll=classes)
            e = C.cast(cookie.contents.data, C.POINTER(DeviceEvent)).contents
            assert e.event == self.child, 'XI event delivered outside owned child'
            v = e.valuators
            assert 0 <= v.length <= 32, 'Unexpected XI valuator mask length'
            mask = C.string_at(v.mask, v.length) if v.length else b''
            values = [v.values[k] for k in range(sum(b.bit_count() for b in mask))]
            return dict(kind='XI', type=e.evtype, time=e.time, button=e.detail,
                        recipient=e.event, child=e.child, device=e.device, source=e.source,
                        flags=e.flags, root_xy=[e.root_x, e.root_y], local_xy=[e.event_x, e.event_y],
                        valuators=unpack_valuators(mask, values))
        finally:
            self.X.XFreeEventData(self.display, cookie)
