#!/usr/bin/env python3
"""Fresh/cold/denied-password canonical keyring check in test-owned containers only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import uuid


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=5, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, **kwargs)


def inside(phase, check_id):
    assert Path('/.dockerenv').exists() and os.getuid() == 0
    assert os.environ.get('CABOOSE_KEYRING_DIAGNOSTIC') == check_id
    assert re.fullmatch('[a-f0-9]{32}', check_id)
    home = Path('/home/caboose')
    marker = home / '.caboose-keyring-check'
    if phase == 'seed':
        assert not list(home.iterdir())
        marker.write_text(check_id)
    else:
        assert phase in ('verify', 'denied') and marker.read_text() == check_id
    os.chown(home, 1000, 1000)
    for path, uid, mode in [('/run/user/1000', 1000, 0o700), ('/run/dbus', 0, 0o755)]:
        Path(path).mkdir(parents=True, exist_ok=True)
        os.chown(path, uid, uid)
        os.chmod(path, mode)
    owner = ['runuser', '-u', 'caboose', '--', 'env', 'HOME=/home/caboose',
             'XDG_RUNTIME_DIR=/run/user/1000', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus']
    run(['dbus-daemon', '--system', '--fork'])
    run(owner + ['dbus-daemon', '--session', '--address=unix:path=/run/user/1000/bus', '--fork'])
    version = subprocess.check_output(['dpkg-query', '-W', '-f=${Version}', 'gnome-keyring'], timeout=5, text=True)
    assert re.fullmatch('[0-9][a-zA-Z0-9.+:~_-]{0,60}', version)
    print('GNOME keyring package: ' + version, flush=True)
    password = sys.stdin.buffer.read(65)
    assert len(password) == 64 and all(c in b'0123456789abcdef' for c in password)
    if phase == 'denied':
        def fingerprint():
            directory = home / '.local/share/keyrings'
            return {p.name: hashlib.sha256(p.read_bytes()).digest() for p in directory.iterdir() if p.is_file()}
        before = fingerprint()
        assert before
        wrong = (b'b' if password[:1] != b'b' else b'a') + password[1:]
        result = subprocess.run(owner + ['/usr/bin/python3', '/opt/caboose/keyring/caboose-keyring'],
                                input=wrong, timeout=15, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert result.returncode == 3 and json.loads(result.stdout) == {'state': 'migration-required'}
        assert fingerprint() == before
        print('PASS: wrong password rejected; persistent keyring bytes preserved', flush=True)
    result = subprocess.run(owner + ['/usr/bin/python3', '/acceptance/check.py',
                            'seed' if phase == 'seed' else 'verify', check_id],
                            input=password, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert result.returncode == 0, 'Canonical synthetic item check failed'
    print('PASS: ' + phase + ': canonical item preserved, repeat preparation and daemon identity verified', flush=True)


def host(image):
    actual = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], timeout=5, text=True).strip()
    assert image.startswith('sha256:') and image == actual
    check_id = uuid.uuid4().hex
    volume = 'caboose-keyring-cold-' + check_id
    password = secrets.token_hex(32).encode()
    source = Path(__file__).resolve().parent
    run(['docker', 'volume', 'create', volume])
    try:
        for phase in ('seed', 'verify', 'denied'):
            name = volume + '-' + phase
            try:
                subprocess.run(['docker', 'run', '--name', name, '--init', '-i', '--network', 'none',
                    '--memory', '256m', '--cpus', '1', '--pids-limit', '64',
                    '--tmpfs', '/run:rw,nosuid,size=16m', '--tmpfs', '/tmp:rw,nosuid,size=16m',
                    '--env', 'CABOOSE_KEYRING_DIAGNOSTIC=' + check_id,
                    '--mount', 'type=volume,source=' + volume + ',target=/home/caboose,volume-nocopy',
                    '--mount', 'type=bind,source=' + str(source) + ',target=/acceptance,readonly',
                    '--mount', 'type=bind,source=' + str(source / 'caboose-keyring') + ',target=/opt/caboose/keyring/caboose-keyring,readonly',
                    '--entrypoint', '/usr/bin/python3', image, '/acceptance/check-preparation-cold.py', '--inside', phase, check_id],
                    input=password, check=True, timeout=45, stderr=subprocess.DEVNULL)
            finally:
                run(['docker', 'rm', '-f', name])
                assert subprocess.run(['docker', 'inspect', name], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
                print('PASS: ' + phase + ' container removed and absence verified', flush=True)
    finally:
        run(['docker', 'volume', 'rm', volume])
        assert subprocess.run(['docker', 'volume', 'inspect', volume], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
        print('PASS: test-owned home volume removed and absence verified', flush=True)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--inside']:
        inside(*sys.argv[2:])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--image', required=True)
        host(parser.parse_args().image)
