#!/usr/bin/python3
"""Persistent agent GUI home. Never inspect or seed from owner application state."""
import fcntl
import os
from pathlib import Path
import stat
import sys
import tempfile
import subprocess


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('agent state must be a private owned directory')


def environment(owner_home):
    root = Path(owner_home) / '.local/share/caboose/agent-seat'
    private_dir(root)
    fd = os.open(root / '.init.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        version = root / 'version'
        if version.exists() and version.read_text() != '1\n':
            raise RuntimeError('unsupported agent profile version; explicit migration required')
        home = root / 'home'
        for path in (home, home / '.config', home / '.local', home / '.local/share', home / '.cache', home / '.local/state'):
            private_dir(path)
        # No profile copying or lock removal. Browser-owned locks remain authoritative.
        if not version.exists():
            temp_fd, name = tempfile.mkstemp(prefix='.version-', dir=root)
            tmp = Path(name)
            with os.fdopen(temp_fd, 'w') as handle:
                handle.write('1\n')
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, version)
            directory_fd = os.open(root, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        return dict(HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                    XDG_DATA_HOME=str(home / '.local/share'), XDG_CACHE_HOME=str(home / '.cache'),
                    XDG_STATE_HOME=str(home / '.local/state'), CABOOSE_SEAT='agent',
                    MOZ_NO_REMOTE='1', VSCODE_IPC_HOOK_CLI='', VSCODE_PORTABLE='',
                    CHROME_CONFIG_HOME=str(home / '.config'), CHROME_USER_DATA_DIR='',
                    DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/agent-bus',
                    PATH=':'.join(['/usr/local/libexec/caboose-agent-seat-bin'] + [part for part in
                        os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin').split(':')
                        if part != '/usr/local/libexec/caboose-agent-seat-bin']))
    finally:
        os.close(fd)


GUI_APPS = {'chromium', 'google-chrome', 'google-chrome-stable', 'firefox', 'firefox-esr', 'code'}
PROFILE_FLAGS = {'--user-data-dir', '--profile', '-profile', '-P', '--profile-directory', '--extensions-dir'}


def gui_command(app, args):
    if app not in GUI_APPS or any(arg.split('=', 1)[0] in PROFILE_FLAGS for arg in args):
        raise RuntimeError('Agent GUI launch does not accept an alternate application profile')
    return ['/usr/bin/' + app, *args]


def main():
    app = Path(sys.argv[0]).name
    if app in GUI_APPS:
        command = gui_command(app, sys.argv[1:])
        subprocess.run(['sudo', '-n', '/usr/local/libexec/caboose-agent-seat'], check=True)
        os.execv('/bin/sh', ['sh', '-c',
            'set -a; . /run/caboose/agent-display.env; exec /usr/bin/python3 /opt/caboose/agent-profile.py exec "$@"',
            'caboose-agent-app', *command])
    values = environment('/home/caboose')
    if sys.argv[1:2] == ['exec'] and len(sys.argv) > 2:
        os.environ.update(values)
        # Inherited editor CLI IPC must never reach the owner instance.
        os.environ.pop('VSCODE_IPC_HOOK_CLI', None)
        os.execvp(sys.argv[2], sys.argv[2:])
    else:
        raise RuntimeError('expected exec COMMAND')


if __name__ == '__main__':
    main()
