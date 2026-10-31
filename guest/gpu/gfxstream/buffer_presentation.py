"""Phone-resident buffers shown in compositor windows (docs/gpu-buffers.md).

A process's Vulkan driver registers each phone-resident dma-buf it renders into with the
image that holds its pixels (CGLS kind 40 on the surface socket, the dma-buf itself in
SCM_RIGHTS; kind 41 forgets it). The compositor names a buffer a window committed by the
dma-buf's device and inode (CGB1 BUFFER_PRESENT). The broker binds the window to the
registering process and presents that image through the GPU stream's ordinary PRESENT,
one frame in flight per window, newest first: a commit that arrives while a frame is in
flight replaces the one waiting, and the replaced buffer is released unshown.
"""
from dataclasses import dataclass, field
import errno
import struct

REGISTER = 40
FORGET = 41
_REGISTER = struct.Struct('<QQQQIIII')
_FORGET = struct.Struct('<QQ')
# Native presentation runs one frame per surface; a present that arrives before the
# previous frame finished is refused with EBUSY and is retried after this long.
RETRY_SECONDS = 0.004
MAX_RETRIES = 64
MAX_BUFFERS_PER_PROCESS = 1024


@dataclass(frozen=True)
class Image:
    """A registered buffer's image, as host (boxed) Vulkan handles."""
    instance: int
    device: int
    queue: int
    image: int
    vk_format: int
    width: int
    height: int
    queue_family: int


def decode_register(body):
    if len(body) != _REGISTER.size:
        raise ValueError('invalid buffer registration size')
    value = Image(*_REGISTER.unpack(body))
    if not all((value.instance, value.device, value.queue, value.image, value.vk_format, value.width, value.height)):
        raise ValueError('invalid buffer registration')
    return value


def decode_forget(body):
    if len(body) != _FORGET.size:
        raise ValueError('invalid buffer forget size')
    device, inode = _FORGET.unpack(body)
    if not inode:
        raise ValueError('invalid buffer forget')
    return device, inode


def encode_register(image):
    return _REGISTER.pack(image.instance, image.device, image.queue, image.image, image.vk_format,
                          image.width, image.height, image.queue_family)


def present_body(serial, image):
    """A PRESENT record's fields after the surface identity: no waits, GENERAL layout."""
    return struct.pack('<QQQQIIIIII', serial, image.device, image.queue, image.image,
                       image.vk_format, image.width, image.height, 1, image.queue_family, 0)


class Registry:
    """Registered buffers by dma-buf identity; each belongs to one process's connection."""
    def __init__(self):
        self.buffers = {}

    def register(self, connection, process, identity, image):
        owned = sum(1 for entry in self.buffers.values() if entry[0] == connection)
        current = self.buffers.get(identity)
        if current is not None and current[0] != connection:
            raise ValueError('buffer registered by another process')
        if current is None and owned >= MAX_BUFFERS_PER_PROCESS:
            raise ValueError('buffer registration capacity')
        # A buffer is registered once, for the first image bound to it.
        if current is None:
            self.buffers[identity] = (connection, process, image)

    def forget(self, connection, identity):
        current = self.buffers.get(identity)
        if current is not None and current[0] == connection:
            del self.buffers[identity]

    def drop(self, connection):
        for identity in [key for key, entry in self.buffers.items() if entry[0] == connection]:
            del self.buffers[identity]

    def lookup(self, identity):
        """The registering process and image, or None."""
        entry = self.buffers.get(identity)
        return None if entry is None else (entry[1], entry[2])


@dataclass
class Frame:
    request: int
    process: int
    image: Image
    serial: int = 0
    retries: int = 0


@dataclass
class Window:
    """One window's presentation: its grant, the frame in flight and the frame waiting."""
    window: int
    process: int = 0
    extent: tuple = (0, 0)
    key: tuple = None          # the grant's (epoch, grant, generation) once bound
    bound: bool = False
    binding: bool = False
    retiring: bool = False
    in_flight: Frame = None
    waiting: Frame = None
    next_serial: int = 0
    released: list = field(default_factory=list)  # (request, status) to report

    def release(self, frame, status):
        if frame is not None:
            self.released.append((frame.request, status))

    def offer(self, frame):
        """A new commit. Returns 'bind', 'retire', 'send' or None for what to do next."""
        if self.retiring:
            self.release(self.waiting, errno.ECANCELED)
            self.waiting = frame
            return None
        if self.key is not None and (frame.process != self.process or
                                     (frame.image.width, frame.image.height) != self.extent):
            # Another process or size needs a new grant: retire this one first.
            self.release(self.waiting, errno.ECANCELED)
            self.waiting = frame
            self.retiring = True
            return 'retire'
        self.release(self.waiting, errno.ECANCELED)
        self.waiting = frame
        if self.key is None:
            if self.binding:
                return None
            self.binding = True
            self.process, self.extent = frame.process, (frame.image.width, frame.image.height)
            return 'bind'
        return self.next_present()

    def next_present(self):
        if not self.bound or self.retiring or self.in_flight is not None or self.waiting is None:
            return None
        self.in_flight, self.waiting = self.waiting, None
        self.next_serial += 1
        self.in_flight.serial = self.next_serial
        return 'send'

    def bind_finished(self, key, bound):
        self.binding = False
        self.key, self.bound = key, bound
        if not bound:
            self.release(self.waiting, errno.EIO)
            self.waiting = None
            if key is not None:
                self.retiring = True
                return 'retire'
            return None
        return self.next_present()

    def result(self, serial, rejected, error):
        """A submission result for the frame in flight. Returns 'send', 'retry' or None."""
        frame = self.in_flight
        if frame is None or frame.serial != serial:
            return None
        if not rejected:
            return None
        if error == errno.EBUSY and self.waiting is None and frame.retries < MAX_RETRIES:
            # The previous frame is still being shown; offer the same buffer again.
            frame.retries += 1
            self.in_flight = None
            self.waiting = frame
            return 'retry'
        self.in_flight = None
        self.release(frame, error or errno.EIO)
        return self.next_present()

    def source_released(self, serial):
        frame = self.in_flight
        if frame is None or frame.serial != serial:
            return None
        self.in_flight = None
        self.release(frame, 0)
        return self.next_present()

    def retired(self):
        """The grant is gone. Returns 'bind' when a waiting frame needs a new one."""
        self.release(self.in_flight, errno.ECANCELED)
        self.in_flight = None
        self.key, self.bound, self.retiring = None, False, False
        if self.waiting is None:
            return None
        self.binding = True
        self.process, self.extent = self.waiting.process, (self.waiting.image.width, self.waiting.image.height)
        return 'bind'

    def take_released(self):
        released, self.released = self.released, []
        return released
