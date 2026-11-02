#!/usr/bin/python3
"""Persistent agent GUI home. Never inspect or seed from owner application state."""
import fcntl
import os
from pathlib import Path
import stat
import sys
import tempfile


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
                    DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/1000/agent-bus')
    finally:
        os.close(fd)


def main():
    values = environment('/home/caboose')
    if sys.argv[1:2] == ['exec'] and len(sys.argv) > 2:
        os.environ.update(values)
        os.execvp(sys.argv[2], sys.argv[2:])
    else:
        raise RuntimeError('expected exec COMMAND')


if __name__ == '__main__':
    main()
