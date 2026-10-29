#!/usr/bin/python3
"""Real Debian Secret Service check; only creates/deletes a uniquely tagged synthetic item."""
import hashlib
import importlib.machinery
import importlib.util
import re
import subprocess
import sys

loader = importlib.machinery.SourceFileLoader('keyring_check_backend', '/opt/caboose/keyring/caboose-keyring')
spec = importlib.util.spec_from_loader(loader.name, loader)
k = importlib.util.module_from_spec(spec); loader.exec_module(k)
mode, check_id = sys.argv[1:]
if mode not in ('seed', 'verify', 'cleanup') or not re.fullmatch('[a-f0-9]{32}', check_id):
    raise SystemExit('Usage: check.py seed|verify|cleanup CHECK_ID (32 lowercase hex characters)')
password = k.credential(sys.stdin.buffer.read(66))
# Repeated provisioning must retain the service owner and require no graphical prompt.
before = k.Keyring()
for _ in range(2):
    result = subprocess.run(['/usr/bin/python3', '/opt/caboose/keyring/caboose-keyring'],
                            input=password, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=45)
    if result.returncode != 0: raise SystemExit('Keyring preparation failed')
backend = k.Keyring()
assert before.owner == backend.owner, 'Provisioning replaced the daemon'
collection = backend.alias('default')
assert collection != '/' and not backend.property(collection, k.INTERFACE + '.Collection', 'Locked')
_, session = backend.call(backend.owner, k.ROOT, k.INTERFACE + '.Service', 'OpenSession',
                          '(sv)', ('plain', backend.GLib.Variant('s', '')))
attributes = {'caboose-keyring-check': check_id}
value = hashlib.sha256(('caboose-test-' + check_id).encode()).digest()
try:
    if mode == 'seed':
        properties = {k.INTERFACE + '.Item.Label': backend.GLib.Variant('s', 'Caboose synthetic keyring check'),
                      k.INTERFACE + '.Item.Attributes': backend.GLib.Variant('a{ss}', attributes)}
        _, prompt = backend.call(backend.owner, collection, k.INTERFACE + '.Collection', 'CreateItem',
                                 '(a{sv}(oayays)b)', (properties, (session, [], list(value), 'application/octet-stream'), True))
        assert prompt == '/', 'Creating the synthetic item requested a prompt'
    unlocked, locked = backend.call(backend.owner, k.ROOT, k.INTERFACE + '.Service', 'SearchItems', '(a{ss})', (attributes,))
    assert len(unlocked) == 1 and not locked, 'Synthetic item missing, duplicated or locked'
    secret = backend.call(backend.owner, unlocked[0], k.INTERFACE + '.Item', 'GetSecret', '(o)', (session,))[0]
    assert bytes(secret[2]) == value, 'Synthetic item did not survive'
    if mode == 'cleanup':
        prompt = backend.call(backend.owner, unlocked[0], k.INTERFACE + '.Item', 'Delete')[0]
        assert prompt == '/', 'Deleting synthetic item requested a prompt'
finally:
    backend.call(backend.owner, session, k.INTERFACE + '.Session', 'Close')
print('PASS: default unlocked, daemon retained, synthetic secret preserved; no Secret Service prompt')
