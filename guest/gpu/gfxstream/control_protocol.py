"""Bounded CGB1 compositor/broker control records, not Vulkan commands."""
from dataclasses import dataclass
import struct

_HEADER = struct.Struct('<4sHHII')
_BIND = struct.Struct('<4sHHIIQQIIQII')
_RESULT = struct.Struct('<4sHHIIQII16s16sQQ')
_REVOKE = struct.Struct('<4sHHII16s16sQQ')
_LIFECYCLE = struct.Struct('<4sHHII16sQQ')


class ControlError(ValueError):
    pass


# The namespace of a bind's object: a Wayland client's wl_surface protocol ID, or an
# X11 window ID on the display's Xwayland.
WAYLAND_SURFACE = 0
X11_WINDOW = 1


@dataclass(frozen=True)
class Bind:
    request: int
    process: int
    uid: int
    pid: int
    start_ticks: int
    object_id: int
    space: int = WAYLAND_SURFACE


@dataclass(frozen=True)
class BindResult:
    request: int
    status: int
    epoch: bytes
    grant: bytes
    window: int
    generation: int


@dataclass(frozen=True)
class RevokeGrant:
    epoch: bytes
    grant: bytes
    generation: int


@dataclass(frozen=True)
class GrantRetired:
    epoch: bytes
    grant: bytes
    generation: int


@dataclass(frozen=True)
class RevokeRequest:
    epoch: bytes
    grant: bytes
    generation: int


@dataclass(frozen=True)
class ExecutorLifecycle:
    kind: int  # 4 ready, 5 lost, 6 retired
    executor: bytes
    generation: int


def _nonzero(data):
    return len(data) == 16 and data != bytes(16)


def encode_bind(value):
    if not all((value.request, value.process, value.pid, value.start_ticks, value.object_id)):
        raise ControlError('invalid bind identity')
    if value.space not in (WAYLAND_SURFACE, X11_WINDOW):
        raise ControlError('invalid bind namespace')
    try:
        return _BIND.pack(b'CGB1', 1, 1, _BIND.size, 0, value.request, value.process,
                          value.uid, value.pid, value.start_ticks, value.object_id, value.space)
    except (struct.error, OverflowError) as error:
        raise ControlError('bind field out of range') from error


def encode_result(value):
    if not value.request or value.status not in (0, 1): raise ControlError('invalid bind result')
    good = _nonzero(value.epoch) and _nonzero(value.grant) and value.window and value.generation
    denied = value.epoch == bytes(16) and value.grant == bytes(16) and not value.window and not value.generation
    if not (good if value.status == 0 else denied): raise ControlError('invalid result identity')
    try:
        return _RESULT.pack(b'CGB1', 1, 2, _RESULT.size, 0, value.request, value.status, 0,
                            value.epoch, value.grant, value.window, value.generation)
    except (struct.error, OverflowError) as error:
        raise ControlError('result field out of range') from error


def encode_revoke(value):
    if not _nonzero(value.epoch) or not _nonzero(value.grant) or not value.generation:
        raise ControlError('invalid grant revoke')
    try:
        return _REVOKE.pack(b'CGB1', 1, 3, _REVOKE.size, 0, value.epoch, value.grant, value.generation, 0)
    except (struct.error, OverflowError) as error:
        raise ControlError('revoke field out of range') from error


def encode_grant_retired(value):
    if not _nonzero(value.epoch) or not _nonzero(value.grant) or not value.generation:
        raise ControlError('invalid grant retirement')
    try:
        return _REVOKE.pack(b'CGB1', 1, 7, _REVOKE.size, 0, value.epoch, value.grant, value.generation, 0)
    except (struct.error, OverflowError) as error:
        raise ControlError('retirement field out of range') from error


def encode_revoke_request(value):
    if not _nonzero(value.epoch) or not _nonzero(value.grant) or not value.generation:
        raise ControlError('invalid revoke request')
    try:
        return _REVOKE.pack(b'CGB1', 1, 8, _REVOKE.size, 0, value.epoch, value.grant, value.generation, 0)
    except (struct.error, OverflowError) as error:
        raise ControlError('revoke request field out of range') from error


def encode_lifecycle(value):
    if value.kind not in (4, 5, 6) or not _nonzero(value.executor) or not value.generation:
        raise ControlError('invalid executor lifecycle')
    try:
        return _LIFECYCLE.pack(b'CGB1', 1, value.kind, _LIFECYCLE.size, 0,
                               value.executor, value.generation, 0)
    except (struct.error, OverflowError) as error:
        raise ControlError('lifecycle field out of range') from error


def decode(data, fd_count):
    if data == b'G':
        if fd_count != 1: raise ControlError('handoff requires exactly one fd')
        return 'handoff'
    if len(data) < _HEADER.size: raise ControlError('truncated control header')
    magic, version, kind, length, reserved = _HEADER.unpack_from(data)
    if magic != b'CGB1' or version != 1 or reserved or length != len(data):
        raise ControlError('invalid control header')
    if kind == 1:
        if length != _BIND.size or fd_count != 1: raise ControlError('invalid bind record')
        _, _, _, _, _, request, process, uid, pid, start, obj, space = _BIND.unpack(data)
        value = Bind(request, process, uid, pid, start, obj, space)
        encode_bind(value)
        return value
    if kind == 2:
        if length != _RESULT.size or fd_count: raise ControlError('invalid result record')
        _, _, _, _, _, request, status, tail, epoch, grant, window, generation = _RESULT.unpack(data)
        if tail: raise ControlError('nonzero reserved field')
        value = BindResult(request, status, epoch, grant, window, generation)
        encode_result(value)
        return value
    if kind in (3, 7, 8):
        if length != _REVOKE.size or fd_count: raise ControlError('invalid revoke/retirement record')
        _, _, _, _, _, epoch, grant, generation, tail = _REVOKE.unpack(data)
        if tail: raise ControlError('nonzero reserved field')
        if kind == 3:
            value = RevokeGrant(epoch, grant, generation)
            encode_revoke(value)
        elif kind == 7:
            value = GrantRetired(epoch, grant, generation)
            encode_grant_retired(value)
        else:
            value = RevokeRequest(epoch, grant, generation)
            encode_revoke_request(value)
        return value
    if kind in (4, 5, 6):
        if length != _LIFECYCLE.size or fd_count: raise ControlError('invalid lifecycle record')
        _, _, _, _, _, executor, generation, tail = _LIFECYCLE.unpack(data)
        if tail: raise ControlError('nonzero reserved field')
        value = ExecutorLifecycle(kind, executor, generation)
        encode_lifecycle(value)
        return value
    raise ControlError('unknown control record')
