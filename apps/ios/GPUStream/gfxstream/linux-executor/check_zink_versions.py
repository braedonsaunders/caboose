#!/usr/bin/env python3
"""Whether Zink offers the same OpenGL through the guest driver as on the computer's own CPU
device: the driver must hide nothing that sets its OpenGL versions.

    python3 apps/ios/GPUStream/gfxstream/linux-executor/check_zink_versions.py COMPUTER WORK RELEASE OUT

The seat is check_chaos.py's (its own compositor, broker, guest driver from RELEASE, X display and
sockets on COMPUTER; nothing of the computer's own session is used), served by the Linux executor
in WORK/build. eglinfo runs twice on the surfaceless platform without the seat's version
overrides: once through the driver, whose device is the executor's lavapipe, and once on the
computer's own lavapipe. The core, compatibility and ES versions must match. OUT/report.txt has
both versions and the extensions only the CPU device offers, which include some no remote
device can offer (GL_AMD_pinned_memory, which imports the application's own memory).
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_chaos  # noqa: E402

VERSION = re.compile(r'^OpenGL (core|compatibility|ES) profile version: (?:OpenGL ES )?([\d.]+)', re.M)
EXTENSIONS = re.compile(r'^OpenGL (core|compatibility|ES) profile extensions:\n(.*?)(?=^\S|\Z)', re.M | re.S)
EGLINFO = 'env -u MESA_GL_VERSION_OVERRIDE -u MESA_GLSL_VERSION_OVERRIDE -u MESA_GLES_VERSION_OVERRIDE {extra}eglinfo -p surfaceless'
CPU_DEVICE = '/usr/share/vulkan/icd.d/lvp_icd.json'


def profiles(text):
    versions = dict(VERSION.findall(text))
    extensions = {name: set(re.findall(r'GL_\w+', body)) for name, body in EXTENSIONS.findall(text)}
    return versions, extensions


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    class Options:
        pass
    o = Options()
    o.computer, o.work, o.release, o.out = sys.argv[1], *(os.path.abspath(a) for a in sys.argv[2:5])
    o.gdb = False
    os.makedirs(o.out, exist_ok=True)
    # A port and X display of its own, apart from a chaos run's.
    check_chaos.PORT, check_chaos.XDISPLAY = 14697, 183
    seat = check_chaos.Seat(o)
    try:
        seat.start()
        seat.executor()
        seat.viewer()
        time.sleep(3)
        seat.app('driver', EGLINFO.format(extra=''))
        seat.app('cpu', EGLINFO.format(extra=f'VK_DRIVER_FILES={CPU_DEVICE} '))
        deadline = time.monotonic() + 60
        texts = {}
        while time.monotonic() < deadline and len(texts) < 2:
            time.sleep(2)
            for name in ('driver', 'cpu'):
                text = seat.sh(f'cat {seat.dir}/{name}.log', check=False) or ''
                if 'OpenGL ES profile extensions:' in text:
                    texts[name] = text
    finally:
        seat.cleanup()
    if len(texts) < 2:
        sys.exit(f'FAIL eglinfo did not finish: {sorted(texts)}')
    (driver_versions, driver_extensions), (cpu_versions, cpu_extensions) = profiles(texts['driver']), profiles(texts['cpu'])
    report, failed = [], False
    for name in ('core', 'compatibility', 'ES'):
        missing = sorted(cpu_extensions.get(name, set()) - driver_extensions.get(name, set()))
        same = driver_versions.get(name) == cpu_versions.get(name)
        failed |= not same
        report.append(f'{"pass" if same else "FAIL"} {name}: driver {driver_versions.get(name)}, '
                      f'CPU device {cpu_versions.get(name)}; only on the CPU device: {" ".join(missing) or "none"}')
    for name, text in texts.items():
        with open(os.path.join(o.out, f'{name}-eglinfo.txt'), 'w') as f:
            f.write(text)
    with open(os.path.join(o.out, 'report.txt'), 'w') as f:
        f.write('\n'.join(report) + '\n')
    print('\n'.join(report))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
