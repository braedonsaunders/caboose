#!/usr/bin/env python3
"""Check a private ICD rejects socket mode without connecting or publishing an instance."""
import ctypes
import json
import os
from pathlib import Path
import select
import socket
import sys
import tempfile


class InstanceCreateInfo(ctypes.Structure):
    _fields_ = [('sType', ctypes.c_uint32), ('pNext', ctypes.c_void_p),
                ('flags', ctypes.c_uint32), ('pApplicationInfo', ctypes.c_void_p),
                ('enabledLayerCount', ctypes.c_uint32), ('ppEnabledLayerNames', ctypes.c_void_p),
                ('enabledExtensionCount', ctypes.c_uint32), ('ppEnabledExtensionNames', ctypes.c_void_p)]


def check(library, temporary_root):
    library = Path(library).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='gate-', dir=temporary_root) as directory:
        path = str(Path(directory) / 'broker.sock')
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(path)
            os.chmod(path, 0o600)
            listener.listen(1)
            os.environ['CABOOSE_GFXSTREAM_SOCKET'] = path
            lib = ctypes.CDLL(str(library))
            negotiate = lib.vk_icdNegotiateLoaderICDInterfaceVersion
            negotiate.argtypes = [ctypes.POINTER(ctypes.c_uint32)]
            negotiate.restype = ctypes.c_int32
            version = ctypes.c_uint32(5)
            if negotiate(ctypes.byref(version)) != 0:
                raise RuntimeError('ICD loader negotiation failed')
            get_proc = lib.vk_icdGetInstanceProcAddr
            get_proc.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
            get_proc.restype = ctypes.c_void_p
            address = get_proc(None, b'vkCreateInstance')
            if not address:
                raise RuntimeError('ICD did not expose vkCreateInstance')
            create = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.POINTER(InstanceCreateInfo),
                                      ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p))(address)
            info = InstanceCreateInfo()
            info.sType = 1  # VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
            sentinel = 0x12345678
            instance = ctypes.c_void_p(sentinel)
            result = create(ctypes.byref(info), None, ctypes.byref(instance))
            if result != -9:  # VK_ERROR_INCOMPATIBLE_DRIVER
                raise RuntimeError(f'unexpected vkCreateInstance result {result}')
            if instance.value != sentinel:
                raise RuntimeError('ICD published or changed an instance handle')
            if select.select([listener], [], [], 0)[0]:
                raise RuntimeError('ICD connected to the socket while gated')
            return {'result': result, 'instance_unchanged': True, 'socket_connected': False,
                    'loader_interface': version.value}


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: check_instance_gate.py ICD_LIBRARY PRIVATE_TEMP_DIR')
    print(json.dumps(check(sys.argv[1], sys.argv[2])))
