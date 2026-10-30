"""Bounded RECORD pointer metadata; does not select XI events on any window."""
import ctypes as C
import struct
import sys
import threading

P, U, I, B = C.c_void_p, C.c_ulong, C.c_int, C.c_ubyte

class Range8(C.Structure):
    _fields_ = [('first', B), ('last', B)]
class Range16(C.Structure):
    _fields_ = [('first', C.c_ushort), ('last', C.c_ushort)]
class ExtRange(C.Structure):
    _fields_ = [('major', Range8), ('minor', Range16)]
class Range(C.Structure):
    _fields_ = [('requests', Range8), ('replies', Range8), ('ext_requests', ExtRange),
                ('ext_replies', ExtRange), ('delivered', Range8), ('device', Range8),
                ('errors', Range8), ('started', I), ('died', I)]
class ClientInfo(C.Structure):
    _fields_ = [('client', U), ('nranges', U), ('ranges', C.POINTER(C.POINTER(Range)))]
class State(C.Structure):
    _fields_ = [('enabled', I), ('datum_flags', I), ('nclients', U),
                ('client_info', C.POINTER(C.POINTER(ClientInfo)))]
class Intercept(C.Structure):
    _fields_ = [('id_base', U), ('server_time', U), ('client_seq', U), ('category', I),
                ('client_swapped', I), ('data', C.POINTER(B)), ('data_len', U)]
Callback = C.CFUNCTYPE(None, P, C.POINTER(Intercept))


def pointer_header(header, endian='<', xi_opcode=131, recipients=None):
    """RECORD gives a32-byte xEvent, even for a longer advertised GenericEvent."""
    if len(header) != 32:
        return None
    typ = header[0] & 127
    if typ == 35:
        if header[1] != xi_opcode:
            return None
        subtype = struct.unpack_from(endian + 'H', header, 8)[0]
        if subtype not in (4, 5, 6):
            return None
        tm, button, _, recipient, child = struct.unpack_from(endian + 'IIIII', header, 12)
        row = dict(kind='XI', type=subtype, recipient=recipient, child=child, time=tm, button=button)
    elif typ in (4, 5, 6):
        tm, _, recipient, child = struct.unpack_from(endian + 'IIII', header, 4)
        row = dict(kind='core', type=typ, recipient=recipient, child=child, time=tm, button=header[1])
    else:
        return None
    if recipients is not None and recipient not in recipients and child not in recipients:
        return None
    return row


class Recorder:
    def __init__(self, resource, recipients=None):
        self.recipients = None if recipients is None else frozenset(recipients)
        self.X = C.CDLL('libX11.so.6')
        self.R = C.CDLL('libXtst.so.6')
        def bind(lib, name, args, result):
            f = getattr(lib, name)
            f.argtypes, f.restype = args, result
            return f
        self.open = bind(self.X, 'XOpenDisplay', [C.c_char_p], P)
        self.close_display = bind(self.X, 'XCloseDisplay', [P], I)
        self.sync = bind(self.X, 'XSync', [P, I], I)
        self.create = bind(self.R, 'XRecordCreateContext', [P,I,C.POINTER(U),I,C.POINTER(C.POINTER(Range)),I], U)
        self.get = bind(self.R, 'XRecordGetContext', [P,U,C.POINTER(C.POINTER(State))], I)
        self.free_state = bind(self.R, 'XRecordFreeState', [C.POINTER(State)], None)
        self.enable = bind(self.R, 'XRecordEnableContext', [P,U,Callback,P], I)
        self.disable = bind(self.R, 'XRecordDisableContext', [P,U], I)
        self.free_context = bind(self.R, 'XRecordFreeContext', [P,U], I)
        self.free_data = bind(self.R, 'XRecordFreeData', [C.POINTER(Intercept)], None)
        self.control = self.open(None)
        self.data = self.open(None)
        assert self.control and self.data
        query_extension = bind(self.X, 'XQueryExtension', [P,C.c_char_p,C.POINTER(I),C.POINTER(I),C.POINTER(I)], I)
        opcode, first_event, first_error = I(), I(), I()
        assert query_extension(self.control, b'XInputExtension', C.byref(opcode), C.byref(first_event), C.byref(first_error))
        self.xi_opcode = opcode.value
        self.events, self.errors, self.categories = [], [], {}
        self.ready = threading.Event()
        self.context = None
        self.thread = None
        self.callback = Callback(self.receive)
        try:
            core, generic = Range(), Range()
            core.delivered = Range8(4, 6)
            generic.delivered = Range8(35, 35)
            ranges = (C.POINTER(Range) * 2)(C.pointer(core), C.pointer(generic))
            client = U(resource)
            self.context = self.create(self.control, 0, C.byref(client), 1, ranges, 2)
            assert self.context
            self.sync(self.control, 0)
            state = C.POINTER(State)()
            assert self.get(self.control, self.context, C.byref(state))
            try:
                self.registered = []
                for k in range(state.contents.nclients):
                    c = state.contents.client_info[k].contents
                    self.registered.append({'client_base': c.client,
                        'delivered_ranges': [[c.ranges[j].contents.delivered.first,
                                              c.ranges[j].contents.delivered.last] for j in range(c.nranges)]})
            finally:
                self.free_state(state)
            self.thread = threading.Thread(target=lambda: self.enable(self.data, self.context, self.callback, None))
            self.thread.start()
            assert self.ready.wait(2), 'RECORD StartOfData missing'
        except BaseException:
            self.close()
            raise

    def receive(self, _, pointer):
        try:
            data = pointer.contents
            self.categories[data.category] = self.categories.get(data.category, 0) + 1
            if data.category == 4:
                self.ready.set()
            if data.category != 0 or data.data_len != 8:
                return
            endian = '<' if sys.byteorder == 'little' else '>'
            if data.client_swapped:
                endian = '>' if endian == '<' else '<'
            address = C.addressof(data.data.contents)
            typ = C.c_ubyte.from_address(address).value & 127
            allowed = typ in (4, 5, 6)
            if typ == 35 and C.c_ubyte.from_address(address + 1).value == self.xi_opcode:
                subtype = struct.unpack(endian + 'H', C.string_at(address + 8, 2))[0]
                allowed = subtype in (4, 5, 6)
            if allowed and len(self.events) < 256:
                row = pointer_header(C.string_at(address, 32), endian, self.xi_opcode, self.recipients)
                if row is None:
                    return
                row['client_base'] = data.id_base
                self.events.append(row)
        except Exception as e:
            if len(self.errors) < 4:
                self.errors.append(type(e).__name__)
        finally:
            self.free_data(pointer)

    def close(self):
        if self.context:
            self.disable(self.control, self.context)
            self.sync(self.control, 0)
        if self.thread:
            self.thread.join(2)
            assert not self.thread.is_alive(), 'RECORD thread did not exit'
        if self.context:
            self.free_context(self.control, self.context)
            self.context = None
        for name in ('data', 'control'):
            display = getattr(self, name, None)
            if display:
                self.close_display(display)
                setattr(self, name, None)
