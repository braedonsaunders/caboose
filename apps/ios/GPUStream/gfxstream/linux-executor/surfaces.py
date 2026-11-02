"""The executor's surfaces: the phone's LiveGPUSurfaceController, LiveGPUIndexedSurface and
LiveGPUAcquireTask (CabooseKit) over the native presentation drafts, presenting offscreen.

Surface records are those of docs/gpu-live.md ("Surface records", "Indexed swapchain wire").
Every native call runs off the session's consumer worker exactly where the phone makes it.
"""
import ctypes
import errno
import itertools
import os
import queue
import struct
import threading
import time
import zlib

import native

U32, U64 = struct.Struct('<I'), struct.Struct('<Q')
STATUS = struct.Struct('<iIiI')
VK_SUCCESS, VK_NOT_READY, VK_TIMEOUT, VK_SUBOPTIMAL, VK_DEVICE_LOST = 0, 1, 2, 1000001003, -4
# Composite alpha (LiveGPUCompositeAlpha): a provider's POST_MULTIPLIED is offered as
# PRE_MULTIPLIED and created as POST_MULTIPLIED, as on the phone.
OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED = 0x1, 0x2, 0x4
# Frames native presentation keeps in flight per surface.
FRAMES_IN_FLIGHT, GUEST_FRAMES_IN_FLIGHT = 2, 8
TRACE = os.environ.get('CABOOSE_LINUX_EXECUTOR_TRACE') == '1'


def log(message):
    print('CABOOSE_LINUX_EXECUTOR ' + message, flush=True)


class ProtocolViolation(Exception):
    pass


class NativeError(Exception):
    def __init__(self, operation, code):
        super().__init__(f'{operation}: errno {code}')
        self.operation, self.code = operation, code


class Status:
    __slots__ = ('errno', 'vk')

    def __init__(self, error=0, vk=None):
        self.errno, self.vk = error, vk

    @property
    def succeeded(self):
        return self.errno == 0 and self.vk in (None, 0)

    @property
    def query_succeeded(self):
        return self.errno == 0 and self.vk == 0

    def pack(self):
        return STATUS.pack(self.errno, 0 if self.vk is None else 1, self.vk or 0, 0)

    @classmethod
    def of(cls, status):
        return cls(status.native_error, status.vulkan_result if status.has_vulkan_result == 1 else None)


def offered_alpha(native_alpha):
    return (native_alpha & OPAQUE) | (PRE_MULTIPLIED if native_alpha & POST_MULTIPLIED else 0)


def native_alpha(requested):
    return {OPAQUE: OPAQUE, PRE_MULTIPLIED: POST_MULTIPLIED}.get(requested, 0)


# One C callback serves every present; its context names a Python receiver.
_receivers = {}
_receiver_keys = itertools.count(1)
_receivers_lock = threading.Lock()


def _present_callback(context, serial, event, result):
    with _receivers_lock:
        receiver = _receivers.get(context or 0)
    if receiver:
        receiver(serial, event, result.native_error,
                 result.vulkan_result if result.has_vulkan_result == 1 else None)


PRESENT_CALLBACK = native.PRESENT_CALLBACK(_present_callback)


def _capture_callback(context, serial, token, pixels):
    with _receivers_lock:
        receiver = _receivers.get(context or 0)
    if receiver:
        receiver(serial, token, pixels.contents if pixels else None)


CAPTURE_CALLBACK = native.CAPTURE_CALLBACK(_capture_callback)
NO_CAPTURE = ctypes.cast(None, native.CAPTURE_CALLBACK)
# Bytes per texel of the presentable formats (B8G8R8A8 and R8G8B8A8, UNORM and SRGB).
FOUR_BYTE_FORMATS = frozenset((37, 43, 44, 50))


def checksum(pixels):
    """CRC-32 of a captured picture's rows, without row padding."""
    if pixels.vk_format not in FOUR_BYTE_FORMATS:
        return None
    crc, width = 0, pixels.width * 4
    for row in range(pixels.height):
        crc = zlib.crc32(ctypes.string_at(pixels.data + row * pixels.row_pitch, width), crc)
    return f'{crc:08x}'


def register_receiver(function):
    with _receivers_lock:
        key = next(_receiver_keys)
        _receivers[key] = function
    return key


def unregister_receiver(key):
    with _receivers_lock:
        _receivers.pop(key, None)


class SerialQueue:
    """A worker thread running submitted work in order, like a serial DispatchQueue."""

    def __init__(self, name, failed):
        self._queue = queue.Queue()
        self._failed = failed
        self._thread = threading.Thread(target=self._run, name=name, daemon=True)
        self._thread.start()

    def _run(self):
        while True:
            work = self._queue.get()
            if work is None:
                return
            try:
                work()
            except Exception as error:  # a broken invariant ends the executor, as on the phone
                self._failed(error)

    def submit(self, work):
        self._queue.put(work)

    def after(self, seconds, work):
        timer = threading.Timer(seconds, lambda: self.submit(work))
        timer.daemon = True
        timer.start()

    def sync(self, work):
        done, box = threading.Event(), {}

        def run():
            try:
                box['value'] = work()
            except Exception as error:
                box['error'] = error
            done.set()
        self.submit(run)
        done.wait()
        if 'error' in box:
            raise box['error']
        return box.get('value')

    def close(self):
        self._queue.put(None)


class Receipts:
    """A legacy present's receipts: its submission result precedes every completion."""

    def __init__(self, serial, emit, failed):
        self.serial, self.emit, self.failed = serial, emit, failed
        self.lock = threading.Lock()
        self.pending, self.admitted, self.poisoned = [], False, False

    def receive(self, body):
        try:
            with self.lock:
                if self.poisoned:
                    return
                if self.admitted:
                    self.emit(*body)
                elif len(self.pending) < 3:
                    self.pending.append(body)
                else:
                    raise ProtocolViolation('surface callback capacity')
        except Exception as error:
            self.poison(error)

    def submit(self, status, disposition):
        with self.lock:
            if self.poisoned:
                raise ProtocolViolation('surface callback failed before admission')
            self.emit(21, U64.pack(self.serial) + status.pack() + struct.pack('<II', disposition, 0))
            if disposition == 0 and self.pending:
                raise ProtocolViolation('rejected submission emitted completion')
            self.admitted = True
            for body in self.pending:
                self.emit(*body)
            self.pending.clear()

    def poison(self, error):
        with self.lock:
            if self.poisoned:
                return
            self.poisoned = True
            self.pending.clear()
        self.failed(error)


class FrameLog:
    """Presented frames per window and swapchain. A PRESENT_RETIRED means the native copy into
    the offscreen swapchain image and its present both completed; a frame whose picture was
    captured also has the CRC-32 of the picture the application presented."""

    class _Swapchain:
        def __init__(self):
            self.frames = self.captured = 0
            self.chain = 0
            self.distinct = set()

    def __init__(self, every):
        self.every = every
        self.lock = threading.Lock()
        self.swapchains = {}
        self.checksums = {}

    def captured(self, window, serial, value):
        with self.lock:
            self.checksums[(window, serial)] = value

    def presented(self, window, swapchain, serial):
        with self.lock:
            entry = self.swapchains.setdefault((window, swapchain), self._Swapchain())
            entry.frames += 1
            value = self.checksums.pop((window, serial), None)
            if value:
                entry.captured += 1
                entry.chain = zlib.crc32(value.encode(), entry.chain)
                entry.distinct.add(value)
            count = entry.frames
        if count == 1 or count % self.every == 0:
            extra = f' checksum={value}' if value else ''
            log(f'presented window={window:#x} swapchain={swapchain} frames={count} serial={serial}{extra}')

    def retired(self, window, swapchain):
        with self.lock:
            entry = self.swapchains.pop((window, swapchain), self._Swapchain())
        log(f'swapchain retired window={window:#x} swapchain={swapchain} frames={entry.frames} '
            f'captured={entry.captured} distinct={len(entry.distinct)} chain={entry.chain:08x}')


class Surface:
    """One bound window's native surface (LinkedLiveGPUSurface), attached to a headless surface."""

    def __init__(self, runtime, pointer, bind, frames):
        self.rt, self.pointer, self.bind, self.frames = runtime, pointer, bind, frames
        self.window = bind.identity.window_id
        self.lock = threading.Lock()
        self.callbacks = {}
        self.key = register_receiver(self._receive)
        self.capture_key = None

    def capture(self):
        """Captures every presented picture for its checksum (the phone's frame lab path)."""
        self.capture_key = register_receiver(self._captured)
        code = self.rt.surface_set_capture(self.pointer, CAPTURE_CALLBACK, self.capture_key)
        if code:
            unregister_receiver(self.capture_key)
            self.capture_key = None
            log(f'captures unavailable window={self.window:#x} errno={code}')

    def _captured(self, serial, token, pixels):
        if pixels:
            self.frames.captured(self.window, serial, checksum(pixels))
        self.rt.surface_release_capture(self.pointer, token)

    def query(self, physical):
        if not self.pointer:
            return Status(errno.ECANCELED), None
        snapshot, status = ctypes.c_void_p(), native.QueryStatus()
        code = self.rt.surface_query_variable_extent(self.pointer, physical, ctypes.byref(snapshot), ctypes.byref(status))
        try:
            actual = Status.of(status)
            view = self.rt.surface_capabilities_get(snapshot) if snapshot.value else None
            if code or not actual.query_succeeded or not view:
                return (Status(errno.EIO) if actual.query_succeeded else actual), None
            v = view.contents
            if max(v.format_count, v.present_mode_count, v.queue_family_count) > 4096:
                return Status(errno.EOVERFLOW), None
            fields = [v.min_image_count, v.max_image_count, v.current_width, v.current_height, v.min_width,
                      v.min_height, v.max_width, v.max_height, v.max_image_array_layers, v.supported_transforms,
                      v.current_transform, offered_alpha(v.supported_composite_alpha), v.supported_usage_flags,
                      v.format_count, v.present_mode_count, v.queue_family_count]
            data = struct.pack('<16I', *fields)
            data += b''.join(struct.pack('<II', v.formats[i].format, v.formats[i].color_space)
                             for i in range(v.format_count))
            data += b''.join(U32.pack(v.present_modes[i]) for i in range(v.present_mode_count))
            data += b''.join(struct.pack('<IIII', i, v.queue_families[i].queue_flags, v.queue_families[i].queue_count,
                                         1 if v.queue_families[i].present_supported == 1 else 0)
                             for i in range(v.queue_family_count))
            return actual, data
        finally:
            if snapshot.value:
                self.rt.surface_capabilities_release(snapshot)

    def present(self, request, event):
        """A plain present (kind 20) of a guest image into the surface's own swapchain."""
        if not self.pointer:
            return Status(errno.ECANCELED), 0
        serial, device, queue_, image, fmt, width, height, layout, family, waits = request
        info = native.PresentInfo()
        info.identity = self.bind.identity
        info.present_serial, info.boxed_device, info.boxed_queue, info.boxed_image = serial, device, queue_, image
        info.vk_format, info.width, info.height, info.vk_image_layout = fmt, width, height, layout
        info.queue_family, info.wait_semaphore_count = family, len(waits)
        array = native.u64_array(waits)
        info.boxed_wait_semaphores = array
        with self.lock:
            self.callbacks[serial] = event
        result = self.rt.surface_present(self.pointer, ctypes.byref(info), PRESENT_CALLBACK, self.key)
        disposition = result.disposition if result.disposition in (0, 1, 2) else 2
        with self.lock:
            if disposition == 0:
                self.callbacks.pop(serial, None)
            else:
                self.callbacks = {serial: event}
        return Status(result.native_error, result.vulkan_result if result.has_vulkan_result == 1 else None), disposition

    def _receive(self, serial, event, error, vk):
        with self.lock:
            callback = self.callbacks.get(serial)
        if not callback:
            return
        if event == native.SOURCE_RELEASED:
            callback((22, U64.pack(serial)))
        elif event == native.DEVICE_LOST:
            callback((21, U64.pack(serial) + Status(error, vk).pack() + struct.pack('<II', 2, 1)))
        elif event != native.PRESENT_RETIRED:
            callback((21, U64.pack(serial) + Status(error, vk).pack() + struct.pack('<II', 2, 2)))

    def create(self, request):
        """SWAPCHAIN_CREATE: the extent first (configure_extent), then the native swapchain."""
        if not self.pointer:
            return Status(errno.ECANCELED), None
        identity = native.Identity.from_buffer_copy(self.bind.identity)
        configured = self.rt.surface_configure_extent_headless(self.pointer, ctypes.byref(identity),
                                                               request['width'], request['height'])
        if configured:
            return Status(configured if configured > 0 else errno.EIO), None
        info = native.SwapchainCreateInfo()
        info.identity = self.bind.identity
        info.boxed_device, info.old_swapchain_id = request['device'], request['old']
        for name in ('create_flags', 'min_image_count', 'vk_format', 'color_space', 'width', 'height',
                     'image_array_layers', 'image_usage', 'pre_transform', 'present_mode', 'clipped', 'sharing_mode'):
            setattr(info, name, request[name])
        info.composite_alpha = native_alpha(request['composite_alpha'])
        families = request['families']
        info.queue_family_count = len(families)
        array = (ctypes.c_uint32 * max(1, len(families)))(*families)
        info.queue_families = array
        output, ident, count, status = ctypes.c_void_p(), ctypes.c_uint64(), ctypes.c_uint32(), native.QueryStatus()
        code = self.rt.virtual_swapchain_create(self.pointer, ctypes.byref(info), ctypes.byref(output),
                                                ctypes.byref(ident), ctypes.byref(count), ctypes.byref(status))
        actual = Status.of(status)
        value = Swapchain(self, output.value, ident.value, count.value) if output.value else None
        if code and actual.query_succeeded:
            return Status(errno.EIO), value
        return actual, value

    def wait_order(self, serial):
        return self.rt.runtime_wait_order(self.bind.identity.process_token, serial)

    def retire(self):
        if not self.pointer:
            return
        if self.capture_key:
            self.rt.surface_set_capture(self.pointer, NO_CAPTURE, None)
            unregister_receiver(self.capture_key)
            self.capture_key = None
        code = self.rt.surface_retire(self.pointer)
        if code:
            raise NativeError('surface retire', code)
        pointer = ctypes.c_void_p(self.pointer)
        code = self.rt.surface_detach_headless(ctypes.byref(pointer))
        if code or pointer.value:
            raise NativeError('surface detach', code if code > 0 else errno.EIO)
        self.pointer = None
        unregister_receiver(self.key)


class Swapchain:
    """One native indexed swapchain (LinkedLiveGPUIndexedSwapchain)."""

    def __init__(self, surface, pointer, ident, count):
        self.surface, self.rt, self.pointer, self.id, self.image_count = surface, surface.rt, pointer, ident, count
        self.lock = threading.Lock()
        self.callbacks = {}
        self.key = register_receiver(self._receive)

    def map(self, images, flags):
        if not self.pointer:
            return Status(errno.ESTALE)
        array = native.u64_array(images)
        if flags & 1:
            code = self.rt.virtual_swapchain_map_guest_images(self.pointer, array, len(images), 2 if flags & 2 else 0)
        else:
            code = self.rt.virtual_swapchain_map(self.pointer, array, len(images))
        return Status(code)

    def begin_acquire(self, info):
        if not self.pointer:
            return Status(errno.ESTALE), None
        request = native.AcquireInfo(info['semaphore'], info['fence'], info['mask'])
        output, status = ctypes.c_void_p(), native.QueryStatus()
        code = self.rt.acquire_begin(self.pointer, ctypes.byref(request), ctypes.byref(output), ctypes.byref(status))
        actual = Status.of(status)
        operation = AcquireOperation(self.rt, output.value) if output.value else None
        if code and actual.succeeded:
            return Status(errno.EIO), operation
        return actual, operation

    def present(self, info, event):
        if not self.pointer:
            return Status(errno.ESTALE), 0
        request = native.MappedPresentInfo()
        request.identity = self.surface.bind.identity
        request.present_serial, request.boxed_queue = info['serial'], info['queue']
        request.queue_family, request.image_index, request.vk_image_layout = info['family'], info['index'], info['layout']
        request.wait_semaphore_count = len(info['waits'])
        array = native.u64_array(info['waits'])
        request.boxed_wait_semaphores = array
        with self.lock:
            self.callbacks[info['serial']] = event
        result = self.rt.virtual_swapchain_present(self.pointer, ctypes.byref(request), PRESENT_CALLBACK, self.key)
        disposition = result.disposition if result.disposition in (0, 1, 2) else 2
        if disposition == 0:
            with self.lock:
                self.callbacks.pop(info['serial'], None)
        return Status(result.native_error, result.vulkan_result if result.has_vulkan_result == 1 else None), disposition

    def _receive(self, serial, event, error, vk):
        with self.lock:
            callback = self.callbacks.get(serial)
        if not callback:
            return
        if event == native.SOURCE_RELEASED:
            callback(('released', serial))
        elif event == native.PRESENT_RETIRED:
            callback(('retired', serial))
            with self.lock:
                self.callbacks.pop(serial, None)
        else:
            callback(('result', serial, Status(error, vk), 1 if event == native.DEVICE_LOST else 2))

    def retire(self):
        if not self.pointer:
            return Status()
        pointer, status = ctypes.c_void_p(self.pointer), native.QueryStatus()
        code = self.rt.virtual_swapchain_retire(ctypes.byref(pointer), ctypes.byref(status))
        actual = Status.of(status)
        if code == 0 and actual.succeeded and not pointer.value:
            self.pointer = None
            unregister_receiver(self.key)
            with self.lock:
                self.callbacks.clear()
            return actual
        return Status(code if code > 0 else errno.EIO) if actual.succeeded else actual


class AcquireOperation:
    def __init__(self, runtime, pointer):
        self.rt, self.pointer = runtime, pointer

    def poll(self):
        r = self.rt.acquire_poll(self.pointer)
        invalid = r.has_image_index > 1 or r.has_vulkan_result > 1 or r.local_reason > 3 or (
            r.has_vulkan_result == 0 and r.vulkan_result != 0)
        status = Status(r.native_error, r.vulkan_result if r.has_vulkan_result == 1 else None)
        return Acquisition(status, r.image_index if r.has_image_index == 1 else None, r.local_reason, invalid)

    def cancel(self):
        return self.rt.acquire_cancel(self.pointer)

    def observe(self):
        return Status.of(self.rt.acquire_observe(self.pointer))

    def release(self):
        if not self.pointer:
            return errno.EINVAL
        pointer = ctypes.c_void_p(self.pointer)
        code = self.rt.acquire_request_release(ctypes.byref(pointer))
        if code == 0 and not pointer.value:
            self.pointer = None
            return 0
        return code if code > 0 else errno.EIO


class Acquisition:
    def __init__(self, status, index, reason, invalid=False):
        self.status, self.index, self.reason, self.invalid = status, index, reason, invalid

    @property
    def acquired(self):
        return self.status.errno == 0 and self.status.vk in (VK_SUCCESS, VK_SUBOPTIMAL) and self.index is not None

    @property
    def pending(self):
        return self.status.errno == 0 and self.status.vk in (VK_NOT_READY, VK_TIMEOUT) and self.index is None

    def valid(self):
        if self.invalid:
            return False
        success = self.status.errno == 0 and self.status.vk in (VK_SUCCESS, VK_SUBOPTIMAL)
        if (self.index is not None) != success or (self.index is not None and self.index >= 256):
            return False
        if not (self.status.errno > 0 or self.status.vk is not None):
            return False
        return (self.reason == 0 and self.status.errno == 0) or (
            self.reason != 0 and self.status.errno > 0 and self.status.vk is None)


class AcquireTask:
    """One native acquire (LiveGPUAcquireTask): zero-timeout polls every millisecond until an
    image, a provider result, the guest's deadline or cancellation, then observation of the
    acquire's signal until it completes. An acquired index always wins over cancellation."""

    def __init__(self, operation, timeout_ns, completion, signal_ready, finished):
        self.operation, self.timeout = operation, timeout_ns
        self.completion, self.signal_ready, self.finished = completion, signal_ready, finished
        self.cancelled = threading.Event()
        self.thread = threading.Thread(target=self._run, name='caboose-acquire', daemon=True)

    def start(self):
        self.thread.start()

    def cancel(self):
        self.cancelled.set()

    def _run(self):
        started = time.monotonic_ns()

        def quarantine(reason):
            self.finished(reason)

        def complete_and_release(value):
            code = self.operation.release()
            if code:
                return quarantine(f'acquire release errno {code}')
            self.completion(value)
            self.finished(None)

        def resolve_cancellation(reason, zero=None):
            code = self.operation.cancel()
            if code == 0:
                if zero is not None:
                    return complete_and_release(zero)
                return complete_and_release(Acquisition(
                    Status(errno.ETIMEDOUT if reason == 1 else errno.ECANCELED), None, reason))
            if code not in (errno.EALREADY, errno.EIO):
                return quarantine(f'acquire cancel errno {code}')
            actual = self.operation.poll()
            if not actual.valid():
                return quarantine('contradictory acquire result')
            if actual.acquired:
                return actual
            if not actual.pending and code == errno.EIO:
                return complete_and_release(actual)
            return quarantine('contradictory acquire result')

        acquired = None
        while acquired is None:
            if self.cancelled.is_set():
                acquired = resolve_cancellation(2)
                if acquired is None:
                    return
                break
            value = self.operation.poll()
            if not value.valid():
                return quarantine('contradictory acquire result')
            if value.acquired:
                acquired = value
                break
            if not value.pending:
                return complete_and_release(value)
            if self.timeout == 0:
                acquired = resolve_cancellation(0, value)
                if acquired is None:
                    return
                break
            if self.timeout != 2**64 - 1 and time.monotonic_ns() - started >= self.timeout:
                acquired = resolve_cancellation(1)
                if acquired is None:
                    return
                break
            self.cancelled.wait(0.001)
        self.completion(acquired)
        observed = time.monotonic_ns()
        while True:
            status = self.operation.observe()
            if status.vk == VK_SUCCESS and status.errno == 0:
                code = self.operation.release()
                if code:
                    return quarantine(f'acquire release errno {code}')
                self.signal_ready(acquired.index)
                return self.finished(None)
            if status.vk == VK_NOT_READY and status.errno == 0:
                if time.monotonic_ns() - observed >= 10_000_000_000:
                    return quarantine('acquire signal deadline')
                time.sleep(0.001)
                continue
            if status.vk == VK_DEVICE_LOST:
                self.operation.release()
            return quarantine(f'acquire signal status errno={status.errno} vk={status.vk}')


class IndexedSurface:
    """One surface's indexed swapchains (LiveGPUIndexedSurface), on a worker of its own."""

    class _Swap:
        def __init__(self, native_swapchain):
            self.native = native_swapchain
            self.mapped = self.guest_images = self.retiring = self.order_waiting = False
            self.count = 0
            self.polling = None
            self.last_completed = 0
            self.tasks = {}
            self.ready = set()
            self.pending = []
            self.frames = {}
            self.order_reached = 0

    def __init__(self, resource, emit, failed, frames):
        self.resource, self.emit_body, self.failed, self.frame_log = resource, emit, failed, frames
        self.queue = SerialQueue('caboose-indexed-surface', self._poison)
        self.order_queue = SerialQueue('caboose-present-order', self._poison)
        self.swaps = {}
        self.last_swapchain = 0
        self.revoking = False
        self.failure = None
        self.retirement = None

    def enqueue(self, control):
        self.queue.submit(lambda: self._guard(self._handle, control))

    def query(self, physical):
        def run():
            if self.revoking or self.failure:
                return Status(errno.ESTALE), None
            return self.resource.query(physical)
        return self.queue.sync(run)

    def _guard(self, function, *args):
        try:
            function(*args)
        except Exception as error:
            self._poison(error)

    def _output(self, kind, fields):
        try:
            self.emit_body(kind, fields)
        except Exception as error:
            if not self.revoking:
                self.failed(error)

    def _result(self, serial, status, disposition, event=0):
        self._output(21, U64.pack(serial) + status.pack() + struct.pack('<II', disposition, event))

    def _handle(self, control):
        if self.failure:
            raise self.failure
        if self.revoking:
            raise ProtocolViolation('control during retirement')
        kind = control['kind']
        if kind == 25:
            if len(self.swaps) >= 4:
                return self._output(26, struct.pack('<QQ', control['request'], 0) + Status(errno.ENOSPC).pack()
                                    + struct.pack('<II', 0, 0))
            status, swapchain = self.resource.create(control)
            if swapchain:
                if swapchain.id <= self.last_swapchain or swapchain.id in self.swaps:
                    raise ProtocolViolation('native reused swapchain identity')
                self.swaps[swapchain.id] = self._Swap(swapchain)
                self.last_swapchain = swapchain.id
                if not status.query_succeeded or not 1 <= swapchain.image_count <= 256:
                    raise ProtocolViolation('native create result/resources disagree')
                log(f'swapchain created window={self.resource.window:#x} swapchain={swapchain.id} '
                    f'{control["width"]}x{control["height"]} format={control["vk_format"]} images={swapchain.image_count}')
                self._output(26, struct.pack('<QQ', control['request'], swapchain.id) + status.pack()
                             + struct.pack('<II', swapchain.image_count, 0))
            else:
                if status.query_succeeded:
                    raise ProtocolViolation('missing native swapchain')
                log(f'swapchain refused window={self.resource.window:#x} errno={status.errno} vk={status.vk} '
                    f'{control["width"]}x{control["height"]} format={control["vk_format"]} '
                    f'images={control["min_image_count"]} mode={control["present_mode"]} '
                    f'alpha={control["composite_alpha"]} usage={control["image_usage"]:#x}')
                self._output(26, struct.pack('<QQ', control['request'], 0) + status.pack() + struct.pack('<II', 0, 0))
        elif kind == 27:
            swap = self._active(control['swapchain'])
            images, flags = control['images'], control['flags']
            guest = bool(flags & 1)
            if swap.mapped or not (1 <= len(images) <= 8 if guest else len(images) == swap.native.image_count):
                raise ProtocolViolation('map count/state')
            status = swap.native.map(images, flags)
            swap.mapped = status.succeeded
            swap.guest_images = guest and status.succeeded
            swap.count = len(images) if guest else swap.native.image_count
            self._output(28, U64.pack(control['swapchain']) + status.pack())
        elif kind == 29:
            swap = self._active(control['swapchain'])
            if not swap.mapped or swap.guest_images:
                raise ProtocolViolation('acquire before map, or with guest images')
            sid, request = control['swapchain'], control['request']
            if swap.polling is not None or len(swap.tasks) >= 256:
                return self._acquired(sid, request, Status(errno.EBUSY), None, 3)
            status, operation = swap.native.begin_acquire(control)
            if not operation:
                if status.succeeded:
                    raise ProtocolViolation('missing native acquire')
                swap.last_completed = request
                return self._acquired(sid, request, status, None, 3 if status.vk is None else 0)
            if not status.succeeded:
                raise ProtocolViolation('native acquire status/resources disagree')
            swap.polling = request

            def completion(result):
                def run():
                    swap.polling = None
                    swap.last_completed = request
                    self._acquired(sid, request, result.status, result.index, result.reason)
                self.queue.submit(lambda: self._guard(run))

            def signal_ready(index):
                def run():
                    if index >= swap.native.image_count:
                        raise ProtocolViolation('native acquire index')
                    swap.ready.add(index)
                self.queue.submit(lambda: self._guard(run))

            def finished(failure):
                def run():
                    if failure:
                        raise ProtocolViolation(failure)
                    swap.tasks.pop(request, None)
                    self._advance()
                self.queue.submit(lambda: self._guard(run))
            task = AcquireTask(operation, control['timeout'], completion, signal_ready, finished)
            swap.tasks[request] = task
            task.start()
        elif kind == 31:
            swap = self._active(control['swapchain'])
            task = swap.tasks.get(control['request'])
            if task:
                task.cancel()
            elif control['request'] != swap.last_completed:
                raise ProtocolViolation('stale acquire cancellation')
        elif kind in (34, 39):
            swap = self._active(control['swapchain'])
            if (not swap.mapped or control['index'] >= swap.count or len(swap.pending) >= 64 or
                    any(p['index'] == control['index'] for p in swap.pending)):
                raise ProtocolViolation('indexed present admission')
            swap.pending.append(control)
            self._advance()
        elif kind == 32:
            swap = self._active(control['swapchain'])
            swap.retiring = True
            for task in swap.tasks.values():
                task.cancel()
            self._reject_pending(swap)
            self._advance()
        else:
            raise ProtocolViolation('wrong-direction indexed control')

    def _acquired(self, swapchain, request, status, index, reason):
        self._output(30, struct.pack('<QQ', swapchain, request) + status.pack() +
                     struct.pack('<IIII', 0 if index is None else 1, index or 0, reason, 0))

    def _active(self, ident):
        swap = self.swaps.get(ident)
        if not swap or swap.retiring:
            raise ProtocolViolation('unknown/retiring swapchain')
        return swap

    def _advance(self):
        if self.failure:
            if self.retirement:
                self.retirement()
            return
        for ident, swap in list(self.swaps.items()):
            if swap.retiring or self.revoking:
                if swap.tasks or swap.frames:
                    continue
                status = swap.native.retire()
                if status.succeeded:
                    del self.swaps[ident]
                    self.frame_log.retired(self.resource.window, ident)
                elif self.revoking:
                    self.failure = NativeError('indexed retirement', status.errno if status.errno > 0 else errno.EIO)
                    if self.retirement:
                        self.retirement()
                    return
                else:
                    return self._poison(ProtocolViolation(f'swapchain retire errno={status.errno} vk={status.vk}'))
                if not self.revoking:
                    self._output(33, U64.pack(ident) + status.pack())
                continue
            if not swap.pending:
                continue
            info = swap.pending[0]
            if info['order'] > swap.order_reached:
                if not swap.order_waiting:
                    self._await_order(info['order'], swap)
                continue
            limit = GUEST_FRAMES_IN_FLIGHT if swap.guest_images else FRAMES_IN_FLIGHT
            if len(swap.frames) >= limit or not (swap.guest_images or info['index'] in swap.ready):
                continue
            swap.pending.pop(0)
            serial = info['serial']
            if TRACE:
                log(f'present kind={info["kind"]} serial={serial} order={info["order"]} reached={swap.order_reached} '
                    f'index={info["index"]} waits={[hex(w) for w in info["waits"]]}')
            swap.frames[serial] = {'index': info['index'], 'result': False, 'released': False}

            def event(body, ident=ident, serial=serial):
                self.queue.submit(lambda: self._guard(self._receive, body, ident, serial))
            status, disposition = swap.native.present(info, event)
            self._result(serial, status, disposition)
            if disposition == 0:
                swap.frames.pop(serial, None)
                if swap.pending:
                    self.queue.submit(lambda: self._guard(self._advance))
            else:
                swap.frames[serial]['result'] = True
                swap.ready.discard(info['index'])
        if self.revoking and not self.swaps and self.retirement:
            self.retirement()

    def _await_order(self, order, swap):
        swap.order_waiting = True

        def wait():
            code = self.resource.wait_order(order)

            def run():
                swap.order_waiting = False
                if code == 0:
                    swap.order_reached = max(swap.order_reached, order)
                elif swap.pending and swap.pending[0]['order'] == order:
                    head = swap.pending.pop(0)
                    self._result(head['serial'], Status(code), 0)
                self._advance()
            self.queue.submit(lambda: self._guard(run))
        self.order_queue.submit(wait)

    def _receive(self, body, ident, serial):
        swap = self.swaps.get(ident)
        frame = swap.frames.get(serial) if swap else None
        if not frame or not frame['result']:
            raise ProtocolViolation('callback without accepted indexed frame')
        if body[0] == 'released':
            if frame['released']:
                raise ProtocolViolation('duplicate source release')
            frame['released'] = True
            self._output(22, U64.pack(serial))
        elif body[0] == 'retired':
            if not frame['released']:
                raise ProtocolViolation('premature frame retirement')
            del swap.frames[serial]
            self.frame_log.presented(self.resource.window, ident, serial)
            self._output(36, struct.pack('<QQ', ident, serial))
            self._advance()
        else:
            _, _, status, event = body
            self._result(serial, status, 2, event)

    def _reject_pending(self, swap):
        pending, swap.pending = swap.pending, []
        for info in pending:
            self._result(info['serial'], Status(errno.ECANCELED), 0)

    def retire(self):
        """Retires every swapchain; called by the consumer during surface or process cleanup."""
        done = threading.Event()

        def run():
            self.revoking = True
            self.retirement = done.set
            for swap in self.swaps.values():
                swap.retiring = True
                for task in swap.tasks.values():
                    task.cancel()
                self._reject_pending(swap)
            self._advance()
        self.queue.submit(lambda: self._guard(run))
        if not done.wait(12):
            raise NativeError('indexed retirement', errno.ETIMEDOUT)
        failure = self.queue.sync(lambda: self.failure)
        self.queue.close()
        self.order_queue.close()
        if failure:
            raise failure

    def _poison(self, error):
        if self.failure:
            return
        self.failure = error
        for swap in self.swaps.values():
            for task in swap.tasks.values():
                task.cancel()
        if self.retirement:
            self.retirement()
        self.failed(error)


def parse_surface(kind, payload):
    """A broker-to-phone surface record: (identity bytes, fields)."""
    identity, r = payload[:40], payload[40:]
    if kind == 16:
        window, instance, width, height = struct.unpack('<QQII', r)
        return identity, {'window': window, 'instance': instance, 'width': width, 'height': height}
    if kind == 18:
        request, physical = struct.unpack('<QQ', r)
        return identity, {'request': request, 'physical': physical}
    if kind == 20:
        serial, device, queue_, image, fmt, width, height, layout, family, count = struct.unpack_from('<4Q6I', r)
        waits = list(struct.unpack_from(f'<{count}Q', r, 56))
        return identity, (serial, device, queue_, image, fmt, width, height, layout, family, waits)
    if kind == 23:
        return identity, {}
    if kind == 25:
        request, device, old = struct.unpack_from('<3Q', r)
        f = struct.unpack_from('<14I', r, 24)
        families = list(struct.unpack_from(f'<{f[13]}I', r, 80))
        names = ('create_flags', 'min_image_count', 'vk_format', 'color_space', 'width', 'height',
                 'image_array_layers', 'image_usage', 'pre_transform', 'composite_alpha', 'present_mode',
                 'clipped', 'sharing_mode')
        fields = dict(zip(names, f[:13]))
        fields.update(kind=25, request=request, device=device, old=old, families=families)
        return identity, fields
    if kind == 27:
        swapchain, count, flags = struct.unpack_from('<QII', r)
        return identity, {'kind': 27, 'swapchain': swapchain, 'flags': flags,
                          'images': list(struct.unpack_from(f'<{count}Q', r, 16))}
    if kind == 29:
        swapchain, request, semaphore, fence, timeout, mask, _ = struct.unpack('<5QII', r)
        return identity, {'kind': 29, 'swapchain': swapchain, 'request': request, 'semaphore': semaphore,
                          'fence': fence, 'timeout': timeout, 'mask': mask}
    if kind == 31:
        swapchain, request = struct.unpack('<QQ', r)
        return identity, {'kind': 31, 'swapchain': swapchain, 'request': request}
    if kind == 32:
        return identity, {'kind': 32, 'swapchain': U64.unpack(r)[0]}
    if kind in (34, 39):
        if kind == 34:
            swapchain, serial, queue_ = struct.unpack_from('<3Q', r)
            order, offset = 0, 24
        else:
            swapchain, serial, queue_, order = struct.unpack_from('<4Q', r)
            offset = 32
        index, family, layout, count = struct.unpack_from('<4I', r, offset)
        waits = list(struct.unpack_from(f'<{count}Q', r, offset + 16))
        return identity, {'kind': kind, 'swapchain': swapchain, 'serial': serial, 'queue': queue_, 'order': order,
                          'index': index, 'family': family, 'layout': layout, 'waits': waits}
    raise ProtocolViolation(f'wrong-direction surface message {kind}')


class SurfaceController:
    """Every surface of one executor (LiveGPUSurfaceController), called by the serial consumer."""

    LIMIT = 32

    class _Entry:
        def __init__(self, process, identity, resource, retiring=False):
            self.process, self.identity, self.resource, self.retiring = process, identity, resource, retiring
            self.last_serial = self.last_request = 0
            self.indexed = None
            self.receipts = None

    def __init__(self, runtime, send, failed, extent, frames, checksums=True):
        self.rt, self.send, self.failed, self.extent, self.frames = runtime, send, failed, extent, frames
        self.checksums = checksums
        self.entries = {}

    def consume(self, kind, payload, process, token):
        identity, fields = parse_surface(kind, payload)
        grant = identity[16:32]

        def emit(reply_kind, body):
            self.send(reply_kind, process, identity + body)
        if kind == 16:
            if grant in self.entries:
                raise ProtocolViolation('duplicate grant')
            if len(self.entries) >= 256:
                raise ProtocolViolation('grant capacity')
            self.entries[grant] = self._Entry(process, identity, None, retiring=True)
            if len(self.entries) > self.LIMIT:
                return emit(17, Status(errno.ENOSPC).pack())
            status, resource = self._bind(identity, token, fields)
            if resource:
                entry = self._Entry(process, identity, resource, retiring=not status.succeeded)
                self.entries[grant] = entry
            return emit(17, status.pack())
        entry = self.entries.get(grant)
        if not entry or entry.identity != identity or entry.process != process:
            log(f'surface record for an unknown grant kind={kind} process={process}')
            return self._answer_stale(kind, fields, emit)
        if not entry.resource:
            if kind != 23:
                raise ProtocolViolation('work after failed bind')
            del self.entries[grant]
            return emit(24, Status().pack())
        if kind in (25, 27, 29, 31, 32, 34, 39):
            if entry.retiring:
                raise ProtocolViolation('indexed control during retirement')
            if kind in (25, 29):
                if fields['request'] <= entry.last_request:
                    raise ProtocolViolation('stale indexed request')
                entry.last_request = fields['request']
            elif kind in (34, 39):
                if fields['serial'] <= entry.last_serial:
                    raise ProtocolViolation('stale indexed present')
                entry.last_serial = fields['serial']
            if not entry.indexed:
                entry.indexed = IndexedSurface(entry.resource, emit, self.failed, self.frames)
            entry.indexed.enqueue(fields)
        elif kind == 18:
            if entry.retiring or fields['request'] <= entry.last_request:
                raise ProtocolViolation('query during retirement or stale request')
            entry.last_request = fields['request']
            status, caps = (entry.indexed or entry.resource).query(fields['physical'])
            if status.query_succeeded != (caps is not None):
                raise ProtocolViolation('incomplete native query')
            if caps:
                formats, modes = struct.unpack_from('<II', caps, 52)
                log(f'surface query window={entry.resource.window:#x} formats={formats} modes={modes} '
                    f'images={struct.unpack_from("<I", caps)[0]}-{struct.unpack_from("<I", caps, 4)[0]}')
            else:
                log(f'surface query window={entry.resource.window:#x} errno={status.errno} vk={status.vk}')
            emit(19, U64.pack(fields['request']) + status.pack() + (caps or b''))
        elif kind == 20:
            serial = fields[0]
            if entry.retiring or serial <= entry.last_serial:
                raise ProtocolViolation('stale present')
            receipts = Receipts(serial, emit, self.failed)
            status, disposition = entry.resource.present(fields, receipts.receive)
            entry.last_serial = serial
            if disposition:
                entry.receipts = receipts
            receipts.submit(status, disposition)
        elif kind == 23:
            entry.retiring = True
            try:
                if entry.indexed:
                    entry.indexed.retire()
                entry.resource.retire()
            except NativeError as error:
                if error.code > 0:
                    return emit(24, Status(error.code).pack())
                raise
            del self.entries[grant]
            log(f'surface retired window={entry.resource.window:#x}')
            emit(24, Status().pack())

    def _bind(self, identity, token, fields):
        width, height = fields['width'], fields['height']
        if not width:
            # No owner view: a window the guest has not sized takes the executor's display extent.
            width, height = self.extent
        bind = native.BindInfo()
        bind.identity = native.identity(token, identity[:16], fields['window'], U64.unpack_from(identity, 32)[0],
                                        identity[16:32])
        bind.boxed_instance, bind.width, bind.height = fields['instance'], width, height
        pointer = ctypes.c_void_p()
        code = self.rt.surface_prepare(ctypes.byref(bind), ctypes.byref(pointer))
        if code or not pointer.value:
            return Status(code if code > 0 else errno.EIO), None
        resource = Surface(self.rt, pointer.value, bind, self.frames)
        attached = self.rt.surface_attach_headless(pointer)
        if attached:
            try:
                resource.retire()
            except NativeError:
                return Status(attached), resource
            return Status(attached), None
        log(f'surface bound window={fields["window"]:#x} process_token={token} extent={width}x{height}')
        if self.checksums:
            resource.capture()
        return Status(), resource

    def answer_for_unknown_process(self, kind, payload, process):
        identity, fields = parse_surface(kind, payload)

        def emit(reply_kind, body):
            self.send(reply_kind, process, identity + body)
        if kind == 16:
            return emit(17, Status(errno.ESRCH).pack())
        self._answer_stale(kind, fields, emit)

    @staticmethod
    def _answer_stale(kind, fields, emit):
        stale = Status(errno.ESTALE)
        if kind == 23:
            emit(24, Status().pack())
        elif kind == 18:
            emit(19, U64.pack(fields['request']) + stale.pack())
        elif kind == 20:
            emit(21, U64.pack(fields[0]) + stale.pack() + struct.pack('<II', 0, 0))
        elif kind == 25:
            emit(26, struct.pack('<QQ', fields['request'], 0) + stale.pack() + struct.pack('<II', 0, 0))
        elif kind == 27:
            emit(28, U64.pack(fields['swapchain']) + stale.pack())
        elif kind == 29:
            emit(30, struct.pack('<QQ', fields['swapchain'], fields['request']) + stale.pack()
                 + struct.pack('<IIII', 0, 0, 3, 0))
        elif kind == 31:
            emit(30, struct.pack('<QQ', fields['swapchain'], fields['request']) + stale.pack()
                 + struct.pack('<IIII', 0, 0, 2, 0))
        elif kind == 32:
            emit(33, U64.pack(fields['swapchain']) + Status().pack())
        elif kind in (34, 39):
            emit(21, U64.pack(fields['serial']) + stale.pack() + struct.pack('<II', 0, 0))
        else:
            raise ProtocolViolation('wrong-direction surface message')

    def retire_process(self, process):
        """Before runtime finish: a bound surface holds its decoder instance's lease."""
        first = None
        for grant, entry in list(self.entries.items()):
            if entry.process != process:
                continue
            entry.retiring = True
            try:
                if entry.indexed:
                    entry.indexed.retire()
                if entry.resource:
                    entry.resource.retire()
                del self.entries[grant]
            except Exception as error:
                first = first or error
        if first:
            raise first
