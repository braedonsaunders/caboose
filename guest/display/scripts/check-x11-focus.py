#!/usr/bin/env python3
"""Check a PRIVATE empty Caboose seat; never run against an owner's seat.

Source that seat's launch environment, then pass --control and --wayland-command.
The command must create one native Wayland window (for example weston-simple-shm).
All fixture clients are owned and closed on exit. The unchanged compositor is the
negative control: the same assertions must fail there, without editing this test.
"""
import argparse
import ctypes as C
import json
import os
import socket
import subprocess
import time

P, U, I = C.c_void_p, C.c_ulong, C.c_int
class Data(C.Union):
    _fields_ = [('b', C.c_char * 20), ('s', C.c_short * 10), ('l', C.c_long * 5)]
class Client(C.Structure):
    _fields_ = [('type', I), ('serial', U), ('send', I), ('display', P), ('window', U), ('message', U), ('format', I), ('data', Data)]
class Key(C.Structure):
    _fields_ = [('type', I), ('serial', U), ('send', I), ('display', P), ('window', U), ('root', U), ('subwindow', U), ('time', U), ('x', I), ('y', I), ('rx', I), ('ry', I), ('state', C.c_uint), ('keycode', C.c_uint), ('same', I)]
class Event(C.Union):
    _fields_ = [('type', I), ('client', Client), ('key', Key), ('pad', C.c_long * 24)]
class Hints(C.Structure):
    _fields_ = [('flags', C.c_long), ('input', I), ('initial', I), ('pixmap', U), ('icon', U), ('x', I), ('y', I), ('mask', U), ('group', U)]

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--control', required=True)
    ap.add_argument('--wayland-command', nargs=argparse.REMAINDER, required=True)
    args = ap.parse_args()
    def seat(command):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(3); s.connect(args.control); s.sendall((command+'\n').encode())
            reply = b''
            while not reply.endswith(b'\n'):
                chunk=s.recv(65536)
                assert chunk, 'control connection closed'
                reply += chunk
        result = json.loads(reply)
        assert result.get('ok'), result
        return result
    assert not seat('windows')['windows'], 'Refusing nonempty seat; use a disposable compositor'
    X = C.CDLL('libX11.so.6'); T = C.CDLL('libXtst.so.6')
    signatures = [
        ('XOpenDisplay', [C.c_char_p], P), ('XDefaultRootWindow', [P], U),
        ('XCreateSimpleWindow', [P,U,I,I,C.c_uint,C.c_uint,C.c_uint,U,U], U),
        ('XStoreName',[P,U,C.c_char_p],I), ('XSetWMHints',[P,U,C.POINTER(Hints)],I),
        ('XSetWMProtocols',[P,U,C.POINTER(U),I],I), ('XMapWindow',[P,U],I),
        ('XDestroyWindow',[P,U],I), ('XCloseDisplay',[P],I),
        ('XInternAtom',[P,C.c_char_p,I],U), ('XSelectInput',[P,U,C.c_long],I),
        ('XChangeProperty',[P,U,U,U,I,I,P,I],I), ('XFlush',[P],I),
        ('XGetWindowProperty',[P,U,U,C.c_long,C.c_long,I,U,C.POINTER(U),C.POINTER(I),C.POINTER(U),C.POINTER(U),C.POINTER(P)],I),
        ('XPending',[P],I), ('XNextEvent',[P,C.POINTER(Event)],I),
        ('XSetInputFocus',[P,U,I,U],I), ('XFree',[P],I),
        ('XStringToKeysym',[C.c_char_p],U), ('XKeysymToKeycode',[P,U],C.c_ubyte),
    ]
    for name, arguments, result in signatures:
        f = getattr(X, name); f.argtypes = arguments; f.restype = result
    T.XTestFakeKeyEvent.argtypes = [P,C.c_uint,I,U]; T.XTestFakeKeyEvent.restype = I
    d = X.XOpenDisplay(None); assert d, 'X11 connection failed'
    root = X.XDefaultRootWindow(d); active = X.XInternAtom(d,b'_NET_ACTIVE_WINDOW',0)
    take = X.XInternAtom(d,b'WM_TAKE_FOCUS',0)
    X.XSelectInput(d,root,1 << 22)
    clients = []; child = None; presses = []; take_focus = []; notifications = []
    def pump():
        while X.XPending(d):
            e = Event(); X.XNextEvent(d,C.byref(e))
            if e.type == 33 and e.client.data.l[0] == take:
                take_focus.append(e.client.window)
                X.XSetInputFocus(d,e.client.window,1,e.client.data.l[1]); X.XFlush(d)
            elif e.type == 2: presses.append((e.key.window,e.key.keycode))
            elif e.type == 28: notifications.append(time.monotonic())
    def wait(predicate, label, seconds=3):
        end = time.monotonic()+seconds
        while time.monotonic()<end:
            pump()
            if predicate(): print('PASS',label,flush=True); return
            time.sleep(.01)
        raise AssertionError(label)
    def value():
        typ=U(); fmt=I(); n=U(); left=U(); ptr=P()
        X.XGetWindowProperty(d,root,active,0,1,0,33,C.byref(typ),C.byref(fmt),C.byref(n),C.byref(left),C.byref(ptr))
        result = C.cast(ptr,C.POINTER(U))[0] if fmt.value == 32 and n.value == 1 else None
        if ptr: X.XFree(ptr)
        return result
    def force_stale():
        stale=U(root); X.XChangeProperty(d,root,active,33,32,0,C.byref(stale),1); X.XFlush(d)
    def window_id(xid):
        return next((w['id'] for w in seat('windows')['windows'] if w.get('x11') == xid), None)
    try:
        for globally_active in (False,True):
            w=X.XCreateSimpleWindow(d,root,0,0,320,240,0,0,0x336699); clients.append(w)
            X.XStoreName(d,w,b'focus-regression-global' if globally_active else b'focus-regression-passive')
            hints=Hints(); hints.flags=1; hints.input=int(not globally_active); X.XSetWMHints(d,w,C.byref(hints))
            if globally_active:
                protocol=U(take); X.XSetWMProtocols(d,w,C.byref(protocol),1)
            X.XSelectInput(d,w,1|(1<<15)); X.XMapWindow(d,w); X.XFlush(d)
            wait(lambda: window_id(w) is not None,'X11 mapped')
            seat('focus '+str(window_id(w)))
            wait(lambda: value()==w,'globally active foreground' if globally_active else 'passive foreground')
            if globally_active: assert w in take_focus, 'WM_TAKE_FOCUS was not honored'
            force_stale(); wait(lambda: value()==w,'stale root notification repaired')
            key=X.XKeysymToKeycode(d,X.XStringToKeysym(b'Return'))
            T.XTestFakeKeyEvent(d,key,1,0); X.XFlush(d)
            wait(lambda: (w,key) in presses,'Return reaches focused client')
            T.XTestFakeKeyEvent(d,key,0,0); X.XFlush(d)
        for _ in range(256): force_stale()
        wait(lambda: value()==clients[-1], 'buffered property flood converges')
        started=time.monotonic(); seat('windows')
        assert time.monotonic()-started < 2, 'property flood starved seat control'
        child=subprocess.Popen(args.wayland_command,env={**os.environ,'GDK_BACKEND':'wayland','QT_QPA_PLATFORM':'wayland'},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        def wayland(): return next((w['id'] for w in seat('windows')['windows'] if w.get('x11') is None),None)
        wait(lambda: wayland() is not None,'Wayland mapped')
        seat('focus '+str(wayland())); wait(lambda: value()==0,'Wayland clears X11 foreground')
        force_stale(); wait(lambda: value()==0,'stale update cannot steal Wayland foreground')
        for w in clients: X.XDestroyWindow(d,w)
        clients.clear(); X.XFlush(d)
        child.terminate(); child.wait(timeout=5); child=None
        wait(lambda: not seat('windows')['windows'],'all fixture windows removed')
        wait(lambda: value()==0,'no focus clears foreground')
        pump(); before=len(notifications); end=time.monotonic()+.3
        while time.monotonic()<end: pump(); time.sleep(.01)
        assert len(notifications)-before<=1,'self-notification write loop'
        print('PASS notification convergence',flush=True)
    finally:
        # Release only the fixture's Return and clients, including on assertion failure.
        key=X.XKeysymToKeycode(d,X.XStringToKeysym(b'Return')); T.XTestFakeKeyEvent(d,key,0,0)
        for w in clients: X.XDestroyWindow(d,w)
        X.XFlush(d); X.XCloseDisplay(d)
        if child is not None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()

if __name__ == '__main__': main()
