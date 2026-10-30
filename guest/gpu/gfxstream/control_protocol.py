"""Bounded CGB1 compositor/broker control records, not Vulkan commands."""
from dataclasses import dataclass
import struct

_HEADER = struct.Struct('<4sHHII')
_BIND = struct.Struct('<4sHHIIQQIIQII')
_RESULT = struct.Struct('<4sHHIIQII16s16sQQ')
_REVOKE = struct.Struct('<4sHHII16s16sQQ')


class ControlError(ValueError):
    pass


@dataclass(frozen=True)
class Bind:
    request: int
    process: int
    uid: int
    pid: int
    start_ticks: int
    object_id: int


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


def _nonzero(data):
    return len(data) == 16 and data != bytes(16)


def encode_bind(value):
    if not all((value.request, value.process, value.pid, value.start_ticks, value.object_id)):
        raise ControlError('invalid bind identity')
    try:
        return _BIND.pack(b'CGB1', 1, 1, _BIND.size, 0, value.request, value.process,
                          value.uid, value.pid, value.start_ticks, value.object_id, 0)
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
        _, _, _, _, _, request, process, uid, pid, start, obj, tail = _BIND.unpack(data)
        if tail: raise ControlError('nonzero reserved field')
        value = Bind(request, process, uid, pid, start, obj)
        encode_bind(value)
        return value
    if kind == 2:
        if length != _RESULT.size or fd_count: raise ControlError('invalid result record')
        _, _, _, _, _, request, status, tail, epoch, grant, window, generation = _RESULT.unpack(data)
        if tail: raise ControlError('nonzero reserved field')
        value = BindResult(request, status, epoch, grant, window, generation)
        encode_result(value)
        return value
    if kind == 3:
        if length != _REVOKE.size or fd_count: raise ControlError('invalid revoke record')
        _, _, _, _, _, epoch, grant, generation, tail = _REVOKE.unpack(data)
        if tail: raise ControlError('nonzero reserved field')
        value = RevokeGrant(epoch, grant, generation)
        encode_revoke(value)
        return value
    raise ControlError('unknown control record')
