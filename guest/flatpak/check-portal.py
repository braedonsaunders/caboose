#!/usr/bin/env python3
"""Check a container's Flatpak spawn portal, as its unprivileged user on D-Bus."""
import argparse
import ctypes
import errno
import subprocess


def check_outer_filter():
    libc = ctypes.CDLL(None, use_errno=True)
    # An invalid fd distinguishes seccomp's EPERM from the kernel's EBADF without
    # entering any namespace. Zero (infer type) and combined pidfd masks stay denied.
    for kind in [0, 0x10000000, 0x20000000, 0x30000000, 0x20000,
                 0x40000000, 0x8000000, 0x4000000, 0x2000000, 0x80]:
        ctypes.set_errno(0)
        result = libc.setns(-1, kind)
        expected = errno.EBADF if kind in (0x10000000, 0x20000000) else errno.EPERM
        assert result == -1 and ctypes.get_errno() == expected, (kind, ctypes.get_errno())
    print("PASS outer setns permits only explicit user/PID namespace types", flush=True)


INNER_CHECK = r'''
print("Checking inner namespace filter", flush=True)
import ctypes, errno, os, struct
libc = ctypes.CDLL(None, use_errno=True)
NEWUSER, SIGCHLD = 0x10000000, 17
clone, clone3 = {"x86_64": (56, 435), "aarch64": (220, 435)}[os.uname().machine]
def refused(name, result, allowed=(errno.EPERM,)):
    if result == 0:
        os._exit(1)  # Also fail in a clone child; never report a successful escape as a pass.
    assert result == -1 and ctypes.get_errno() in allowed, (name, result, ctypes.get_errno())
    print(name, "denied", flush=True)
refused("unshare", libc.unshare(NEWUSER))
refused("clone", libc.syscall(clone, NEWUSER | SIGCHLD, 0, 0, 0, 0))
args = struct.pack("QQQQQQQQQQQ", NEWUSER, 0, 0, 0, SIGCHLD, 0, 0, 0, 0, 0, 0)
refused("clone3", libc.syscall(clone3, ctypes.c_char_p(args), len(args)), (errno.EPERM, errno.ENOSYS))
# EBADF would show setns reached the kernel; EPERM proves the app filter still rejects it.
refused("setns-user", libc.setns(-1, NEWUSER))
refused("setns-pid", libc.setns(-1, 0x20000000))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", help="installed Flatpak app with Python 3 in its runtime")
    parser.add_argument("--outer-seccomp", action="store_true",
                        help="also require Caboose's container setns filter")
    args = parser.parse_args()
    if args.outer_seccomp:
        check_outer_filter()
    # Run the same denial checks in the original app and both portal-created children.
    relay = """
import subprocess
for mode in ['--expose-pids', '--share-pids']:
    command = ['flatpak-spawn', '--sandbox', mode]
    subprocess.run(command + ['/usr/bin/true'], check=True, timeout=30)
    result = subprocess.run(command + ['python3', '-c', 'raise SystemExit(37)'], timeout=30)
    assert result.returncode == 37, (mode, result.returncode)
    subprocess.run(command + ['python3', '-c', INNER], check=True, timeout=30)
    print('PASS portal', mode, 'and child seccomp', flush=True)
"""
    subprocess.run(["flatpak", "run", "--command=python3", args.app, "-c", INNER_CHECK],
                   check=True, timeout=60)
    subprocess.run(["flatpak", "run", "--command=python3", args.app, "-c",
                    "INNER = " + repr(INNER_CHECK) + "\n" + relay], check=True, timeout=210)


if __name__ == "__main__":
    main()
