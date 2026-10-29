import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch, MagicMock
import os
import socket
import struct
import stat

loader = importlib.machinery.SourceFileLoader('keyring', str(Path(__file__).with_name('caboose-keyring')))
spec = importlib.util.spec_from_loader(loader.name, loader)
k = importlib.util.module_from_spec(spec)
loader.exec_module(k)

class Policy(unittest.TestCase):
    def test_fresh(self):
        self.assertEqual(k.action('/', '/', [k.ROOT + '/collection/session'], []), 'create')
    def test_existing(self):
        self.assertEqual(k.action('/login', '/login', ['/login'], ['login.keyring']), 'unlock')
    def test_preserve_ambiguous_state(self):
        for default, login, collections, files in [('/', '/', [], ['orphan.keyring']),
                ('/', '/login', ['/login'], []), ('/other', '/login', ['/other', '/login'], []),
                ('/', '/', ['/other'], [])]:
            with self.subTest(default=default, login=login, files=files):
                with self.assertRaises(k.MigrationRequired):
                    k.action(default, login, collections, files)
    def test_nonempty_random_credential_only(self):
        self.assertEqual(k.credential(b'a' * 64 + b'\n'), b'a' * 64)
        for value in (b'', b'\n', b'a' * 63, b'a' * 65, b'g' * 64, b'a' * 63 + b'\x00'):
            with self.assertRaises(ValueError): k.credential(value)

class Control(unittest.TestCase):
    def peer(self, response, pid=42):
        peer = MagicMock()
        peer.__enter__.return_value = peer
        peer.getsockopt.return_value = struct.pack('3i', pid, os.getuid(), 1000)
        peer.recv.side_effect = [response[:3], response[3:]]
        return peer

    def test_exact_protocol_and_fragmented_reply(self):
        peer = self.peer(struct.pack('!II', 8, 0))
        info = MagicMock(st_mode=stat.S_IFSOCK, st_uid=os.getuid())
        with patch.object(k.socket, 'socket', return_value=peer), patch.object(k.Path, 'lstat', return_value=info), patch.object(k.socket, 'SO_PEERCRED', 17, create=True):
            k.unlock('/runtime', b'a' * 64, 42)
        self.assertEqual([c.args[0] for c in peer.sendall.call_args_list], [b'\0', struct.pack('!III', 76, 1, 64) + b'a' * 64])

    def test_wrong_peer_receives_no_password(self):
        peer = self.peer(b'', pid=99)
        info = MagicMock(st_mode=stat.S_IFSOCK, st_uid=os.getuid())
        with patch.object(k.socket, 'socket', return_value=peer), patch.object(k.Path, 'lstat', return_value=info), patch.object(k.socket, 'SO_PEERCRED', 17, create=True):
            with self.assertRaises(RuntimeError): k.unlock('/runtime', b'a' * 64, 42)
        peer.sendall.assert_not_called()

    def test_denied_password_is_migration(self):
        peer = self.peer(struct.pack('!II', 8, 1))
        info = MagicMock(st_mode=stat.S_IFSOCK, st_uid=os.getuid())
        with patch.object(k.socket, 'socket', return_value=peer), patch.object(k.Path, 'lstat', return_value=info), patch.object(k.socket, 'SO_PEERCRED', 17, create=True):
            with self.assertRaises(k.MigrationRequired): k.unlock('/runtime', b'a' * 64, 42)

    def test_dbus_names_are_distinct(self):
        self.assertEqual(k.SERVICE, 'org.freedesktop.secrets')
        self.assertEqual(k.INTERFACE, 'org.freedesktop.Secret')
        backend = k.Keyring.__new__(k.Keyring)
        backend.owner = ':1.42'
        backend.call = MagicMock(return_value=('/',))
        backend.alias('login')
        self.assertEqual(backend.call.call_args.args[2], 'org.freedesktop.Secret.Service')

if __name__ == '__main__': unittest.main()
