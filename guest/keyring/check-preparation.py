#!/usr/bin/env python3
"""Bounded canonical preparation diagnostic, exclusively in a disposable empty home."""
import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import uuid


def inside():
    assert Path('/.dockerenv').exists() and os.getuid() == 0
    assert os.environ.get('CABOOSE_KEYRING_DIAGNOSTIC') == '1'
    home = Path('/home/caboose')
    assert not list(home.iterdir()), 'Refuse nonempty home'
    os.chown(home, 1000, 1000)
    for path, uid, mode in [('/run/user/1000', 1000, 0o700), ('/run/dbus', 0, 0o755)]:
        Path(path).mkdir(parents=True, exist_ok=True)
        os.chown(path, uid, uid)
        os.chmod(path, mode)
    env = ['runuser', '-u', 'caboose', '--', 'env', 'HOME=/home/caboose',
           'XDG_RUNTIME_DIR=/run/user/1000', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus']
    for args in [['dbus-daemon', '--system', '--fork'],
                 env + ['dbus-daemon', '--session', '--address=unix:path=/run/user/1000/bus', '--fork']]:
        subprocess.run(args, check=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run(env + ['/usr/bin/python3', __file__, '--probe'],
                            input=secrets.token_hex(32).encode(), timeout=40,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    # Only our fixed schema survives; never retain arbitrary subprocess output.
    try:
        rows = [json.loads(line) for line in result.stdout.splitlines()]
        for row in rows:
            assert set(row) <= {'state', 'stage', 'error'}
            assert row.get('state') in (None, 'ready', 'migration-required', 'unavailable')
            assert row.get('stage') in (None, 'activation', 'alias', 'property', 'collections', 'login-locked', 'default-locked', 'control-directory', 'peer-pid', 'control-unlock', 'set-alias', 'preparation')
            assert row.get('error') in (None, 'dbus-unknown-method', 'dbus-unknown-object', 'dbus-error', 'migration-required', 'timeout', 'os-error', 'runtime-error', 'other')
        assert rows
    except Exception:
        rows = [{'state': 'unavailable', 'stage': 'preparation', 'error': 'other'}]
    for row in rows:
        print(json.dumps(row))
    return result.returncode


def probe():
    loader = importlib.machinery.SourceFileLoader('diagnostic_keyring', '/opt/caboose/keyring/caboose-keyring')
    spec = importlib.util.spec_from_loader(loader.name, loader)
    k = importlib.util.module_from_spec(spec)
    loader.exec_module(k)
    stage = 'preparation'
    original_call, original_unlock, original_ensure = k.Keyring.call, k.unlock, k.Keyring.ensure
    def call(self, dest, path, interface, method, *args):
        nonlocal stage
        stage = {'StartServiceByName': 'activation', 'GetNameOwner': 'activation',
                 'ReadAlias': 'alias', 'Get': 'property', 'GetControlDirectory': 'control-directory',
                 'GetConnectionUnixProcessID': 'peer-pid', 'SetAlias': 'set-alias'}.get(method, 'preparation')
        if method == 'Get':
            stage = 'collections' if path == k.ROOT else 'login-locked'
        return original_call(self, dest, path, interface, method, *args)
    def unlock(*args):
        nonlocal stage
        stage = 'control-unlock'
        return original_unlock(*args)
    def ensure(self, password):
        try:
            return original_ensure(self, password)
        except Exception as error:
            from gi.repository import Gio, GLib
            if isinstance(error, k.MigrationRequired):
                kind = 'migration-required'
            elif isinstance(error, GLib.Error):
                remote = Gio.DBusError.get_remote_error(error)
                kind = {'org.freedesktop.DBus.Error.UnknownMethod': 'dbus-unknown-method',
                        'org.freedesktop.DBus.Error.UnknownObject': 'dbus-unknown-object'}.get(remote, 'dbus-error')
            else:
                kind = 'timeout' if isinstance(error, TimeoutError) else 'os-error' if isinstance(error, OSError) else 'runtime-error' if isinstance(error, RuntimeError) else 'other'
            print(json.dumps({'stage': stage, 'error': kind}))
            raise
    k.Keyring.call, k.Keyring.ensure, k.unlock = call, ensure, unlock
    return k.main()


def host(image):
    actual = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], timeout=5, text=True).strip()
    assert image.startswith('sha256:') and image == actual
    name = 'caboose-keyring-diagnostic-' + uuid.uuid4().hex
    try:
        return subprocess.run(['docker', 'run', '--name', name, '--init', '--network', 'none',
            '--memory', '256m', '--cpus', '1', '--pids-limit', '64',
            '--tmpfs', '/home/caboose:rw,nosuid,size=16m', '--tmpfs', '/run:rw,nosuid,size=16m',
            '--tmpfs', '/tmp:rw,nosuid,size=16m', '--env', 'CABOOSE_KEYRING_DIAGNOSTIC=1',
            '--mount', 'type=bind,source=' + str(Path(__file__).resolve().parent) + ',target=/acceptance,readonly',
            '--mount', 'type=bind,source=' + str(Path(__file__).resolve().with_name('caboose-keyring')) + ',target=/opt/caboose/keyring/caboose-keyring,readonly',
            '--entrypoint', '/usr/bin/python3', image, '/acceptance/check-preparation.py', '--inside'],
            timeout=45, stderr=subprocess.DEVNULL).returncode
    finally:
        subprocess.run(['docker', 'rm', '-f', name], check=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert subprocess.run(['docker', 'inspect', name], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
        print('PASS: diagnostic container removed; no persistent volume created')


if __name__ == '__main__':
    if sys.argv[1:] == ['--inside']:
        sys.exit(inside())
    if sys.argv[1:] == ['--probe']:
        sys.exit(probe())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    sys.exit(host(parser.parse_args().image))
