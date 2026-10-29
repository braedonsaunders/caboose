#!/usr/bin/env python3
"""Acquire the host's advisory lock and exec a process retaining fd 3."""
import fcntl
import os
import sys

if len(sys.argv) < 3:
    raise SystemExit('usage: host-lock.py IMAGE_ROOT COMMAND [ARG ...]')
root = os.path.realpath(sys.argv[1])
os.makedirs(root, mode=0o700, exist_ok=True)
fd = os.open(os.path.join(root, '.host.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Caboose image root is locked by a host or VM')
if fd != 3:
    os.dup2(fd, 3)
    os.close(fd)
os.set_inheritable(3, True)
os.environ['CABOOSE_HOST_LOCK_FD'] = '3'
os.execvp(sys.argv[2], sys.argv[2:])
