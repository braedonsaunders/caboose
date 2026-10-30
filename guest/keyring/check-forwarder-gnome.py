#!/usr/bin/env python3
"""Real GNOME proxy/Close check in a bounded disposable container; no display."""
import argparse
import os
from pathlib import Path
import secrets
import subprocess
import sys
import uuid


def inside():
    assert Path('/.dockerenv').exists() and os.getuid() == 0
    assert os.environ.get('CABOOSE_FORWARDER_CHECK') == '1'
    home = Path('/home/caboose')
    assert not list(home.iterdir()), 'Refuse nonempty home'
    os.chown(home, 1000, 1000)
    for path, uid, mode in [('/run/user/1000', 1000, 0o700), ('/run/dbus', 0, 0o755)]:
        Path(path).mkdir(parents=True, exist_ok=True)
        os.chown(path, uid, uid)
        os.chmod(path, mode)
    owner = ['runuser', '-u', 'caboose', '--', 'env', 'HOME=/home/caboose',
             'XDG_RUNTIME_DIR=/run/user/1000', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus']
    # Install only the tested keyring source into this disposable container.
    subprocess.run(['sh', '/acceptance/install.sh'], check=True, timeout=5,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for args in [['dbus-daemon', '--system', '--fork'],
                 owner + ['dbus-daemon', '--session', '--address=unix:path=/run/user/1000/bus', '--fork'],
                 owner + ['dbus-daemon', '--config-file=/opt/caboose/keyring/agent-bus.conf', '--fork']]:
        subprocess.run(args, check=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check_id = uuid.uuid4().hex
    subprocess.run(owner + ['/usr/bin/python3', '/acceptance/check.py', 'seed', check_id],
                   input=secrets.token_hex(32).encode(), check=True, timeout=20,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Share the actual integrated acceptance oracle, including wire-level Close
    # and rejection of GetSecret using the closed session.
    subprocess.run(owner + ['/usr/bin/python3', '/acceptance/check-dual-seat.py', '--agent-secret', check_id],
                   check=True, timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('PASS: real GNOME agent OpenSession/SearchItems/GetSecret bytes; empty Close; closed session rejected')


def host(image):
    actual = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], timeout=5, text=True).strip()
    assert image.startswith('sha256:') and image == actual
    name = 'caboose-keyring-close-' + uuid.uuid4().hex
    try:
        return subprocess.run(['docker', 'run', '--name', name, '--init', '--network', 'none',
            '--memory', '256m', '--cpus', '1', '--pids-limit', '64',
            '--tmpfs', '/home/caboose:rw,nosuid,size=16m', '--tmpfs', '/run:rw,nosuid,size=16m',
            '--tmpfs', '/tmp:rw,nosuid,size=16m', '--env', 'CABOOSE_FORWARDER_CHECK=1',
            '--mount', 'type=bind,source=' + str(Path(__file__).resolve().parent) + ',target=/acceptance,readonly',
            '--entrypoint', '/usr/bin/python3', image, '/acceptance/check-forwarder-gnome.py', '--inside'],
            timeout=50, stderr=subprocess.DEVNULL).returncode
    finally:
        subprocess.run(['docker', 'rm', '-f', name], check=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert subprocess.run(['docker', 'inspect', name], timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
        print('PASS: GNOME proxy container removed; no persistent volume created')


if __name__ == '__main__':
    if sys.argv[1:] == ['--inside']:
        try:
            inside()
        except Exception:
            print('FAIL: disposable GNOME proxy check')
            sys.exit(1)
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--image', required=True)
        sys.exit(host(parser.parse_args().image))
