"""Strict authenticated HTTP upgrade for the private GPU broker.

Call only on a socket passed by the authenticated compositor. The caller reads
at most MAX_REQUEST bytes through the end of headers, supplies the current
per-wake token, and sends the returned response. This module opens no listener.
"""
import base64
import hashlib
import hmac
import re
import uuid

MAX_REQUEST = 16 * 1024
PROTOCOL = 'caboose.gpu.live.v1'
_GUID = b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
_TOKEN = re.compile(rb"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")


class AdmissionError(ValueError):
    pass


def _headers(request):
    if len(request) > MAX_REQUEST or not request.endswith(b'\r\n\r\n'):
        raise AdmissionError('invalid request length or terminator')
    lines = request[:-4].split(b'\r\n')
    if not lines or lines[0] != b'GET /gpu HTTP/1.1':
        raise AdmissionError('invalid request line')
    headers = {}
    for line in lines[1:]:
        if b':' not in line:
            raise AdmissionError('invalid header')
        name, value = line.split(b':', 1)
        if not _TOKEN.fullmatch(name):
            raise AdmissionError('invalid header name')
        value = value.strip(b' \t')
        if any(c < 32 and c != 9 or c == 127 for c in value):
            raise AdmissionError('invalid header value')
        key = name.lower()
        if key in headers:
            raise AdmissionError('duplicate header')
        headers[key] = value
    return headers


def admit(request, per_wake_token):
    """Validate token before interpreting identity; return (computer, UUID, 101).

    The exact request excludes any subsequent WebSocket bytes. The caller must
    keep bytes read after its terminator for the WebSocket parser.
    """
    h = _headers(request)
    auth = h.get(b'authorization', b'')
    if not per_wake_token or not hmac.compare_digest(auth, b'Bearer ' + per_wake_token):
        raise AdmissionError('authentication failed')
    # Identity is interpreted only after successful per-wake authentication.
    computer = h.get(b'x-caboose-gpu-computer', b'')
    raw_executor = h.get(b'x-caboose-gpu-executor', b'')
    try:
        computer = computer.decode('ascii')
        executor = uuid.UUID(raw_executor.decode('ascii'))
    except (UnicodeError, ValueError) as error:
        raise AdmissionError('invalid executor identity') from error
    if not computer or len(computer) > 128 or not all(33 <= ord(c) <= 126 for c in computer) or not executor.int:
        raise AdmissionError('invalid executor identity')
    if (h.get(b'upgrade', b'').lower() != b'websocket' or
        b'upgrade' not in [x.strip().lower() for x in h.get(b'connection', b'').split(b',')] or
        h.get(b'sec-websocket-version') != b'13' or
        h.get(b'sec-websocket-protocol') != PROTOCOL.encode() or
        b'sec-websocket-extensions' in h):
        raise AdmissionError('unsupported WebSocket upgrade')
    try:
        key = h[b'sec-websocket-key']
        if len(base64.b64decode(key, validate=True)) != 16:
            raise ValueError('wrong key size')
    except (KeyError, ValueError) as error:
        raise AdmissionError('invalid WebSocket key') from error
    accept = base64.b64encode(hashlib.sha1(key + _GUID).digest())
    response = (b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                b'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept +
                b'\r\nSec-WebSocket-Protocol: ' + PROTOCOL.encode() + b'\r\n\r\n')
    return computer, executor, response
