#!/usr/bin/env python3
"""An X11 window the way a game or a Wine program makes one: its own WM_CLASS, no desktop
entry, a `_NET_WM_PID` that is not its process (as in a Flatpak sandbox) and a
`_NET_WM_ICON`, which it changes once after mapping. For check.py's `taskbar` check.

    x11-icon-window.py PID_FILE [SECONDS]

Writes its real PID to PID_FILE once mapped, then waits. Needs only libX11 (ctypes).
"""
import ctypes
import ctypes.util
import os
import sys
import time

CLASS = (b"caboose-taskbar-check", b"CabooseTaskbarCheck")
CLAIMED_PID = 2  # a namespace PID: never this process's

x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p
x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XCreateSimpleWindow.restype = ctypes.c_ulong
x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                  ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
x.XInternAtom.restype = ctypes.c_ulong
x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
x.XStoreName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_char_p]
x.XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]

XA_CARDINAL, XA_STRING, XA_WM_CLASS, REPLACE = 6, 31, 67, 0


def cardinals(display, window, name, values):
    # Xlib takes format-32 data as C longs.
    data = (ctypes.c_long * len(values))(*values)
    x.XChangeProperty(display, window, x.XInternAtom(display, name, 0), XA_CARDINAL, 32, REPLACE, data, len(values))


def icon(size, argb):
    return [size, size] + [argb] * (size * size)


def main():
    pid_file = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30
    display = x.XOpenDisplay(None)
    if not display:
        sys.exit("cannot open display")
    window = x.XCreateSimpleWindow(display, x.XDefaultRootWindow(display), 0, 0, 320, 200, 0, 0, 0x3366cc)
    x.XStoreName(display, window, b"Taskbar check")
    wm_class = CLASS[0] + b"\0" + CLASS[1] + b"\0"
    x.XChangeProperty(display, window, XA_WM_CLASS, XA_STRING, 8, REPLACE, wm_class, len(wm_class))
    cardinals(display, window, b"_NET_WM_PID", [CLAIMED_PID])
    cardinals(display, window, b"_NET_WM_ICON", icon(16, 0xFFFF0000))
    x.XMapWindow(display, window)
    x.XSync(display, 0)
    time.sleep(5)
    # A program that sets its icon after mapping (Wine does) is followed.
    cardinals(display, window, b"_NET_WM_ICON", icon(16, 0xFFFF0000) + icon(128, 0xFF00FF00))
    x.XSync(display, 0)
    with open(pid_file + ".tmp", "w") as f:
        f.write(f"{os.getpid()}\n")
    os.rename(pid_file + ".tmp", pid_file)
    time.sleep(seconds)


if __name__ == "__main__":
    main()
