#!/usr/bin/env python3
"""Executor loss chaos: a seat's apps keep drawing real pictures while its executor and viewer
are lost, replaced, stalled and reconnected at random points.

    python3 apps/ios/GPUStream/gfxstream/linux-executor/check_chaos.py COMPUTER WORK RELEASE OUT
        [--cycles 50] [--seed N] [--steam-home DIR] [--triangle PATH]

COMPUTER is a running computer with Chromium, mesa-utils and, for the CEF and DXVK apps, the
Steam Flatpak and a Proton. The check makes a seat of its own there (its own caboose-display,
port, token, Wayland socket, X display, runtime directory and private GPU sockets; nothing of
the computer's own session is used) running RELEASE's compositor, GPU broker and guest driver
(a release directory of guest/release: its files/ tree) for the compositor and every client,
served by the real Linux executor (WORK/build) with --pictures and watched by
caboose-display-probe.

Long-lived apps run through every cycle: the compositor, an animated Chromium page (a Wayland
client, so its frames are phone-resident dma-bufs), and with --steam-home Steam's own CEF
client (an X11 client on a profile in that home, never the computer owner's). Each cycle
applies one event at a random point:

  kill       the executor ends (a phone app closed or relaunched) and a new one connects
  drop       the executor and the viewer end together (a network drop, a lock) and return
  stall      the executor stops answering for 2-8 s and resumes (a short stall)
  viewer     only the viewer reconnects (a display reconnect)
  startup    fresh apps start and the executor ends 0-2 s later, during their warm-up,
             first bind and first present

After each cycle the long-lived apps must present real pictures again (Chromium, and Steam once
its window is poked), and freshly started apps must too: a Chromium with a new profile, a GL
app (glxgears through Zink, in its own window or the compositor's images) and, with --triangle, DXVK's d3d11 triangle through
Proton. A real picture is neither noise nor one colour (surfaces.content: a repeat fraction from
0.3 to 0.999 and at least 3 colours). The check prints one line per cycle and fails on the first
cycle whose apps did not all present.
"""
import argparse
import json
import os
import random
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '../../../../..'))
PHONE = ('guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,'
         'executor-resume,zstd-stream,guest-buffer-views,batched-descriptor-sets-inline,guest-set-ids,completion-payloads,'
         'wait-serial,silent-success')
PICTURE = re.compile(r'^(\S+) CABOOSE_LINUX_EXECUTOR picture window=(\S+) serial=\d+ (\d+)x(\d+) format=\d+ '
                     r'content=([0-9.]+) colours=(\d+)')
# The seat's port and X display (CHAOS_PORT, CHAOS_X_DISPLAY), so two checks can share a computer.
PORT, XDISPLAY = int(os.environ.get('CHAOS_PORT', '14695')), int(os.environ.get('CHAOS_X_DISPLAY', '181'))
FRESH_CHROMIUM = (608, 378)
# The Flatpak runtime's CPU Vulkan drivers, which the computer's own launch environment keeps
# beside its GPU driver: without them a 32-bit Steam client with no device fell back to
# drawing on the CPU and ran out of address space.
FLATPAK_LAVAPIPE = ('/usr/lib/x86_64-linux-gnu/GL/default/vulkan/icd.d/lvp_icd.x86_64.json:'
                    '/usr/lib/i386-linux-gnu/GL/default/vulkan/icd.d/lvp_icd.i686.json')
# DXVK's d3d11 triangle's window: its own size inside a Wine desktop, or a top-level window the
# compositor sizes to the seat's 1280x800 display (Wine without a desktop).
TRIANGLE = ((1016, 573), (1280, 785))
PAGE = ('data:text/html,<body style="margin:0;background:%23e8f0ff;font:40px sans-serif">'
        '<h1 style="background:%23204080;color:%23ffd040;margin:0">Caboose</h1>'
        '<div style="width:120px;height:120px;background:%23c03020;animation:s 1s linear infinite"></div>'
        '<style>@keyframes s{to{transform:translateX(300px) rotate(360deg)}}</style>'
        '<p>The quick brown fox jumps over the lazy dog.</p></body>')
STILL = ('data:text/html,<body style="margin:0;background:%23f0ffe8;font:40px sans-serif">'
         '<h1 style="background:%23406020;color:%23fff">Fresh</h1><p>Pack my box with five dozen liquor jugs.</p></body>')


def run(*argv, check=True, capture=True, timeout=None):
    result = subprocess.run(argv, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{shlex.join(argv)}: {result.stdout.decode(errors="replace")[-400:]}')
    return result.stdout.decode(errors='replace') if capture else ''


class Seat:
    def __init__(self, options):
        self.o = options
        self.computer = options.computer
        self.dir = f'/tmp/caboose-chaos-{os.getpid()}'
        self.name = f'caboose-chaos-{os.getpid()}'
        self.generation = 0
        self.executors = []
        self.logs = {}

    def sh(self, script, user=None, check=True, detach=False):
        argv = ['docker', 'exec'] + (['-d'] if detach else []) + (['-u', user] if user else []) + [self.computer, 'sh', '-c', script]
        return run(*argv, check=check)

    def shm(self):
        return set(self.sh('ls -d /dev/shm/flatpak-* 2>/dev/null', check=False).split())

    def start(self):
        d = self.dir
        # Flatpak's shared-memory directories that exist before the seat's apps run: only the
        # seat's own are removed at the end (an app ended by a signal leaves its directory, and
        # a full /dev/shm ends every app on the computer).
        self.shm_before = self.shm()
        files = os.path.join(self.o.release, 'files')
        self.sh(f'mkdir -m 0700 -p {d}/run/gpu {d}/home {d}/bin && head -c 24 /dev/urandom | od -An -tx1 | tr -d " \\n" > {d}/token')
        # The release's own compositor, broker and driver, in the seat's directory.
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so'),
            f'{self.computer}:{d}/libvulkan_gfxstream.so')
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/lib/caboose-gpu-live/i386/libvulkan_gfxstream.so'),
            f'{self.computer}:{d}/libvulkan_gfxstream32.so')
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/bin/caboose-display'), f'{self.computer}:{d}/bin/caboose-display')
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/bin/caboose-display-probe'), f'{self.computer}:{d}/bin/caboose-display-probe')
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/libexec'), f'{self.computer}:{d}/libexec')
        icd = json.dumps({'file_format_version': '1.0.0', 'ICD': {'library_path': f'{d}/libvulkan_gfxstream.so', 'api_version': '1.3.0'}})
        icd32 = json.dumps({'file_format_version': '1.0.0', 'ICD': {'library_path': f'{d}/libvulkan_gfxstream32.so', 'api_version': '1.3.0'}})
        env = '\n'.join([
            f'export PATH=/usr/local/bin:/usr/bin:/bin HOME={d}/home XDG_RUNTIME_DIR={d}/run',
            f'export VK_DRIVER_FILES={d}/icd.json:/usr/share/vulkan/icd.d/lvp_icd.json CABOOSE_GPU_ROUTING=1 NODEVICE_SELECT=1',
            'export GALLIUM_DRIVER=zink LIBGL_KOPPER_DRI2=1 MESA_GL_VERSION_OVERRIDE=4.5COMPAT MESA_GLSL_VERSION_OVERRIDE=450 ZINK_DESCRIPTORS=lazy',
            f'export CABOOSE_GAME_SOCKET={d}/run/game.sock CABOOSE_CHAOS_SEAT={os.getpid()}', ''])
        self.sh(f"printf '%s' {shlex.quote(icd)} > {d}/icd.json && printf '%s' {shlex.quote(icd32)} > {d}/icd32.json && "
                f"printf '%s' {shlex.quote(env)} > {d}/env && chown -R caboose {d}")
        self.sh(f'. {d}/env; CABOOSE_GPU_BROKER={d}/libexec/caboose-gpu-broker exec {d}/bin/caboose-display --listen 127.0.0.1:{PORT} --token-file {d}/token --socket wayland-chaos '
                f'--x-display {XDISPLAY} --no-audio --no-devices --private-gpu-stream-socket {d}/run/gpu/gpu.sock '
                f'--private-gpu-surface-socket {d}/run/gpu/surface.sock --private-gpu-indexed --env-file {d}/display.env '
                f'--display 1280x800@60x1 > {d}/display.log 2>&1', user='caboose', detach=True)
        self.wait(lambda: subprocess.run(['docker', 'exec', self.computer, 'test', '-s', f'{d}/display.env']).returncode == 0,
                  30, 'the seat')
        self.token = self.sh(f'cat {d}/token').strip()
        self.sh(f'cat > {d}/client <<EOF\n. {d}/env; set -a; . {d}/display.env; set +a\n'
                f'export CABOOSE_GFXSTREAM_SOCKET={d}/run/gpu/gpu.sock CABOOSE_GFXSTREAM_SURFACE_SOCKET={d}/run/gpu/surface.sock '
                f'PRESSURE_VESSEL_FILESYSTEMS_RW={d}/run/gpu\nEOF\nchown caboose {d}/client')

    @staticmethod
    def wait(predicate, seconds, what):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.2)
        raise RuntimeError(f'{what} did not start')

    def executor(self):
        """A new executor (the next generation), as a returning phone's."""
        self.generation += 1
        name = f'{self.name}-{self.generation}'
        pictures = os.path.join(self.o.out, f'pictures-{self.generation}')
        os.makedirs(pictures, exist_ok=True)
        os.chmod(pictures, 0o777)
        run('docker', 'run', '-d', '--name', name, '--init', '--network', f'container:{self.computer}', '--cpus', '4',
            '--memory', '4g', '-v', f'{self.o.work}/build:/build:ro', '-v', f'{REPO}/guest/gpu:/repo/guest/gpu:ro',
            '-v', f'{HERE}:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro', '-v', f'{pictures}:/pictures',
            '--entrypoint', 'sh', 'caboose-linux-executor', '-c',
            f"printf %s '{self.token}' > /tmp/token; exec python3 -u /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py "
            f"--connect 127.0.0.1:{PORT} --token-file /tmp/token --library /build/libcaboose_gpu_executor.so --features {PHONE} "
            f"--pictures /pictures --display 1280x800")
        self.executors.append(name)
        if self.o.gdb:
            # Each executor's native stacks if it faults: gdb on the host, attached to its Python
            # as soon as it runs (a fault can come with the first connections).
            pid = run('docker', 'inspect', '-f', '{{.State.Pid}}', name).strip()
            target = None
            for _ in range(200):
                for child in run('pgrep', '-P', pid, check=False).split():
                    try:
                        if b'executor.py' in open(f'/proc/{child}/cmdline', 'rb').read():
                            target = child
                    except OSError:
                        pass
                if target:
                    break
                time.sleep(0.02)
            if target:
                trace = open(os.path.join(self.o.out, f'gdb-{self.generation}.txt'), 'w')
                subprocess.Popen(['gdb', '-p', target, '-batch', '-ex', f'set sysroot /proc/{target}/root',
                                  '-ex', 'handle SIGPIPE nostop noprint', '-ex', 'handle SIGUSR1 nostop noprint',
                                  '-ex', 'continue', '-ex', 'thread apply all bt 25'],
                                 stdout=trace, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        try:
            started = time.monotonic()
            self.wait(lambda: 'session ready' in run('docker', 'logs', name, check=False),
                      int(os.environ.get('CHAOS_READY_SECONDS', '30')), 'the executor')
            if time.monotonic() - started > 10:
                print(f'executor {self.generation} took {time.monotonic() - started:.0f} s to connect', flush=True)
        except RuntimeError:
            # Where the broker waits, in the display log, before the seat goes.
            self.sh(f"pkill -USR1 -f '{self.dir}/libexec/caboose-gpu-broker'", check=False)
            if self.o.gdb:
                # And the compositor's native stacks, on the host.
                for pid in run('pgrep', '-f', f'{self.dir}/bin/caboose-display --listen', check=False).split():
                    with open(os.path.join(self.o.out, f'gdb-compositor-{pid}.txt'), 'w') as trace:
                        subprocess.run(['timeout', '60', 'gdb', '-p', pid, '-batch', '-ex', f'set sysroot /proc/{pid}/root',
                                        '-ex', 'thread apply all bt 30'], stdout=trace, stderr=subprocess.STDOUT)
            time.sleep(1)
            raise
        return name

    def end_executor(self):
        name = self.executors[-1]
        self.logs[name] = run('docker', 'logs', '--timestamps', name, check=False)
        run('docker', 'rm', '-f', name, check=False)

    def viewer(self, start=True):
        self.sh(f"pkill -TERM -f 'caboose-display-probe --url ws://127.0.0.1:{PORT}/'", check=False)
        if start:
            # Showing child windows (inset GPU windows bind), as the phone does.
            self.sh(f'exec {self.dir}/bin/caboose-display-probe --url ws://127.0.0.1:{PORT}/ --token-file {self.dir}/token '
                    f'--duration 100000 --display 1280x800@60x1 --children >> {self.dir}/probe.log 2>&1', user='caboose', detach=True)

    def viewer_alive(self):
        return subprocess.run(['docker', 'exec', self.computer, 'pgrep', '-f',
                               f'caboose-display-probe --url ws://127.0.0.1:{PORT}/'],
                              stdout=subprocess.DEVNULL).returncode == 0

    def app(self, label, command):
        self.sh(f'. {self.dir}/client; exec {command} > {self.dir}/{label}.log 2>&1', user='caboose', detach=True)

    def stop(self, pattern):
        self.sh(f"pkill -TERM -f {shlex.quote(pattern)}", check=False)

    def pictures(self, since):
        """Pictures every executor logged after `since` (docker timestamps): (window, w, h, good)."""
        found = []
        for name in self.executors:
            text = self.logs.get(name) or run('docker', 'logs', '--timestamps', name, check=False)
            for line in text.splitlines():
                m = PICTURE.match(line)
                if not m or m.group(1) < since:
                    continue
                repeat, colours = float(m.group(5)), int(m.group(6))
                found.append((name, m.group(2), int(m.group(3)), int(m.group(4)), 0.3 <= repeat < 0.999 and colours >= 3))
        return found

    def cleanup(self):
        for name in self.executors:
            if name not in self.logs:
                self.logs[name] = run('docker', 'logs', '--timestamps', name, check=False)
            run('docker', 'rm', '-f', name, check=False)
        for name, text in self.logs.items():
            with open(os.path.join(self.o.out, f'{name}.log'), 'w') as f:
                f.write(text)
        # Processes the seat started carry its marker; only they are ended.
        marker = f'CABOOSE_CHAOS_SEAT={os.getpid()}'
        for signal in ('TERM', 'KILL'):
            self.sh(f'for p in $(pgrep -u caboose); do tr "\\0" "\\n" < /proc/$p/environ 2>/dev/null | grep -qx {marker} && kill -{signal} $p; done',
                    user='caboose', check=False)
            self.sh(f"pkill -{signal} -f '{self.dir}/'", check=False)
            time.sleep(2)
        os.makedirs(os.path.join(self.o.out, 'seat'), exist_ok=True)
        # Ending Steam with signals leaves its Flatpak shared-memory directory behind. A directory
        # made during the run that no process maps or holds open is removed; one in use (another
        # Steam's) is left.
        for path in sorted(self.shm() - getattr(self, 'shm_before', set())):
            name = shlex.quote(os.path.basename(path))
            self.sh(f'for p in /proc/[0-9]*; do grep -qs {name} $p/maps && exit 0; ls -l $p/fd 2>/dev/null | grep -qs {name} && exit 0; done; '
                    f'rm -rf {shlex.quote(path)}', check=False)
        for f in self.sh(f'cd {self.dir} && ls *.log', check=False).split():
            with open(os.path.join(self.o.out, 'seat' if f not in ('display.log', 'probe.log') else '', f), 'w') as out:
                out.write(self.sh(f'cat {self.dir}/{f}', check=False))
        self.sh(f'rm -rf {self.dir}', check=False)


def now():
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime()) + '.000000000Z'


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('computer')
    parser.add_argument('work')
    parser.add_argument('release', help="a release directory: its files/ tree's compositor, broker and driver run the seat")
    parser.add_argument('out')
    parser.add_argument('--cycles', type=int, default=50)
    parser.add_argument('--seed', type=int, default=None)
    parser.add_argument('--events', help="comma-separated events to run in order, repeated (kill, drop, stall, viewer, "
                        "startup), instead of random ones; the seed still picks their delays")
    parser.add_argument('--steam-home', help="a home of the check's own holding a Steam Flatpak profile (never the owner's)")
    parser.add_argument('--triangle', help="DXVK's d3d11 triangle.exe, inside --steam-home's Flatpak data")
    parser.add_argument('--proton', default='/opt/caboose-games/GE-Proton11-11/proton')
    parser.add_argument('--gdb', action='store_true', help="attach gdb to each executor; a fault's stacks go to OUT/gdb-N.txt")
    o = parser.parse_args()
    o.work, o.release = os.path.abspath(o.work), os.path.abspath(o.release)
    os.makedirs(o.out, exist_ok=True)
    o.out = os.path.abspath(o.out)
    seed = o.seed if o.seed is not None else random.randrange(1 << 30)
    rng = random.Random(seed)
    print(f'chaos seed={seed} cycles={o.cycles}', flush=True)
    seat = Seat(o)
    fresh_count = 0

    def fresh_apps():
        nonlocal fresh_count
        fresh_count += 1
        n = fresh_count
        seat.app(f'fresh-chromium-{n}', f'timeout 40 /usr/bin/chromium --user-data-dir={seat.dir}/home/fresh-{n} --no-first-run '
                 f'--no-default-browser-check --password-store=basic --ozone-platform=wayland --use-gl=angle --use-angle=gl '
                 f'--window-size=640,420 {shlex.quote(STILL)}')
        seat.app(f'fresh-gl-{n}', 'timeout 40 glxgears -geometry 320x240')
        expected = {'fresh chromium': None, 'fresh gl': None}
        if o.triangle:
            seat.app(f'fresh-dxvk-{n}', dxvk_command(45))
            expected['fresh dxvk'] = None
        return expected

    def dxvk_command(seconds):
        bench = os.path.dirname(o.triangle)
        return (f'env HOME={o.steam_home} timeout {seconds} flatpak run --env=CABOOSE_GFXSTREAM_SOCKET=$CABOOSE_GFXSTREAM_SOCKET '
                f'--env=CABOOSE_GFXSTREAM_SURFACE_SOCKET=$CABOOSE_GFXSTREAM_SURFACE_SOCKET --env=VK_DRIVER_FILES={seat.dir}/icd.json:{seat.dir}/icd32.json:{FLATPAK_LAVAPIPE} '
                f'--env=CABOOSE_CHAOS_SEAT={os.getpid()} --filesystem={seat.dir} --filesystem={os.path.dirname(o.proton)}:ro '
                f'--command=sh com.valvesoftware.Steam -c '
                f'"export STEAM_COMPAT_DATA_PATH={bench}/compat/1 STEAM_COMPAT_CLIENT_INSTALL_PATH={o.steam_home}/.var/app/'
                f'com.valvesoftware.Steam/.local/share/Steam; mkdir -p {bench}/compat/1; exec {o.proton} waitforexitandrun {o.triangle}"')

    def stop_fresh():
        seat.stop(f'{seat.dir}/home/fresh-')
        # glxgears runs in other checks too: only the seat's own (its marker) is ended.
        stop_marked('glxgears -geometry 320x240')
        stop_wine()

    def stop_marked(pattern):
        marker = f'CABOOSE_CHAOS_SEAT={os.getpid()}'
        for signal in ('TERM', 'KILL'):
            seat.sh(f'for p in $(pgrep -u caboose -f "{pattern}"); do tr "\\0" "\\n" < /proc/$p/environ 2>/dev/null | '
                    f'grep -qx {marker} && kill -{signal} $p; done', user='caboose', check=False)
            time.sleep(2)

    def stop_wine():
        # Wine winds down before the next DXVK start, which would otherwise join the running
        # Wine session (its desktop, or a session left hung by an executor loss). Each DXVK run
        # is its own Flatpak sandbox, a PID namespace: ending the sandbox ends every process of
        # its Wine session, including wineserver (which cannot be told apart by its environment)
        # and the Windows services. Only the seat's own sandboxes are ended, and only its own
        # triangle is asked to quit: other checks on the computer run triangle.exe too.
        marker = f'CABOOSE_CHAOS_SEAT={os.getpid()}'
        seat.sh(f'for p in $(pgrep -u caboose -f "triangle.exe"); do tr "\\0" "\\n" < /proc/$p/environ 2>/dev/null | '
                f'grep -qx {marker} && kill -TERM $p; done', user='caboose', check=False)
        for attempt in range(30):
            alive = seat.sh(f'for p in $(pgrep -u caboose -f "waitforexitandrun {o.triangle}"); do '
                            f'tr "\\0" "\\n" < /proc/$p/environ 2>/dev/null | grep -qx {marker} && echo $p; done',
                            user='caboose', check=False).split()
            if not alive:
                return
            if attempt >= 5:
                seat.sh(f'kill -KILL {" ".join(alive)}', user='caboose', check=False)
            time.sleep(1)
        print('DXVK sandboxes did not end', flush=True)

    def judge(since, wanted, wait):
        """Whether every wanted app presented a real picture after `since`, within `wait` seconds."""
        deadline = time.monotonic() + wait
        while True:
            pictures = seat.pictures(since)
            missing = [label for label, test in wanted.items() if not any(good and test(w, h) for _, _, w, h, good in pictures)]
            if not missing or time.monotonic() >= deadline:
                return missing, pictures
            time.sleep(2)

    try:
        seat.start()
        seat.executor()
        seat.viewer()
        time.sleep(3)
        mark = now()
        seat.app('chromium', f'/usr/bin/chromium --user-data-dir={seat.dir}/home/long --no-first-run --no-default-browser-check '
                 f'--password-store=basic --ozone-platform=wayland --use-gl=angle --use-angle=gl --window-size=1000,620 {shlex.quote(PAGE)}')
        def steam():
            seat.app('steam', f'env HOME={o.steam_home} dbus-run-session -- flatpak run --env=CABOOSE_CHAOS_SEAT={os.getpid()} '
                     '--env=CABOOSE_GFXSTREAM_SOCKET=$CABOOSE_GFXSTREAM_SOCKET --env=CABOOSE_GFXSTREAM_SURFACE_SOCKET=$CABOOSE_GFXSTREAM_SURFACE_SOCKET '
                     f'--env=VK_DRIVER_FILES={seat.dir}/icd.json:{seat.dir}/icd32.json:{FLATPAK_LAVAPIPE} --env=PRESSURE_VESSEL_FILESYSTEMS_RW={seat.dir} '
                     f'--filesystem={seat.dir} com.valvesoftware.Steam')
        if o.steam_home:
            steam()
        # Learn the long-lived apps' picture sizes: Chromium's is the largest, Steam's the other.
        time.sleep(60 if o.steam_home else 15)
        sizes = sorted({(w, h) for _, _, w, h, good in seat.pictures(mark) if good}, key=lambda s: -s[0] * s[1])
        if o.steam_home and len(sizes) < 2:
            # Starting Steam is not under test: a start that never showed its window is tried once more.
            print('Steam showed no window; starting it again', flush=True)
            stop_marked('steam')
            steam()
            time.sleep(60)
            sizes = sorted({(w, h) for _, _, w, h, good in seat.pictures(mark) if good}, key=lambda s: -s[0] * s[1])
        if not sizes:
            raise RuntimeError('no long-lived app presented a real picture before the first cycle')
        chromium_size = sizes[0]
        long_lived = {'chromium': lambda w, h, s=chromium_size: (w, h) == s}
        if o.steam_home:
            if len(sizes) < 2:
                raise RuntimeError(f'Steam presented no real picture before the first cycle (sizes {sizes})')
            steam_size = sizes[1]
            long_lived['steam'] = lambda w, h, s=steam_size: (w, h) == s
        print(f'long-lived apps presenting: {", ".join(long_lived)} (sizes {sizes[:2]})', flush=True)
        if o.triangle:
            # Proton makes its prefix on its first run, which takes longer than a cycle allows.
            mark = now()
            seat.app('dxvk-prefix', dxvk_command(240))
            missing, _ = judge(mark, {'dxvk': lambda w, h: (w, h) in TRIANGLE}, 240)
            stop_wine()
            if missing:
                raise RuntimeError('DXVK presented no real picture before the first cycle')
            print('DXVK presenting', flush=True)
        events = ['kill', 'drop', 'stall', 'viewer', 'startup']
        forced = [e.strip() for e in o.events.split(',')] if o.events else []
        if any(e not in events for e in forced):
            raise SystemExit(f'unknown event in --events: {o.events}')
        for cycle in range(1, o.cycles + 1):
            event = forced[(cycle - 1) % len(forced)] if forced else rng.choice(events)
            delay = rng.uniform(0, 3)
            started = time.monotonic()
            time.sleep(delay)
            if event == 'kill':
                seat.end_executor(); time.sleep(rng.uniform(0, 3)); seat.executor()
            elif event == 'drop':
                seat.end_executor(); seat.viewer(start=False); time.sleep(rng.uniform(1, 4)); seat.executor(); seat.viewer()
            elif event == 'stall':
                name = seat.executors[-1]
                run('docker', 'pause', name); time.sleep(rng.uniform(2, 8)); run('docker', 'unpause', name)
            elif event == 'viewer':
                seat.viewer(start=False); time.sleep(rng.uniform(0, 2)); seat.viewer()
            elif event == 'startup':
                fresh_apps(); time.sleep(rng.uniform(0, 2)); seat.end_executor(); time.sleep(rng.uniform(0, 2)); seat.executor()
                stop_fresh()
            # The compositor closes the display session on every executor change and the phone
            # reconnects it: so does the viewer.
            if not seat.viewer_alive():
                seat.viewer()
            time.sleep(4)
            mark = now()
            stop_fresh()
            fresh = fresh_apps()
            if o.steam_home:
                # Steam draws on change: a resize redraws its window.
                seat.sh(f'. {seat.dir}/client; for w in $(xdotool search --name "Steam" 2>/dev/null); do '
                        f'xdotool windowsize $w {700 + cycle % 2} 440 2>/dev/null; xdotool windowsize $w 700 440 2>/dev/null; done',
                        user='caboose', check=False)
            wanted = dict(long_lived)
            # Chromium's Wayland window is its --window-size less its frame (32x42).
            wanted['fresh chromium'] = lambda w, h: (w, h) == FRESH_CHROMIUM
            # glxgears draws with Zink and presents in its own window (its swapchain binds), or
            # reaches the compositor as an X11 window's pixels, which the compositor's own images
            # (the display's size) show.
            wanted['fresh gl'] = lambda w, h: (w, h) in ((320, 240), (1280, 800))
            if 'fresh dxvk' in fresh:
                # Wine's windows for it are the triangle's at whatever size Wine and the
                # compositor gave them (in a Wine desktop, or a top-level of its own).
                def dxvk_sizes():
                    tree = seat.sh(f'. {seat.dir}/client; xwininfo -root -tree 2>/dev/null', user='caboose', check=False)
                    return {(int(m.group(1)), int(m.group(2))) for m in
                            re.finditer(r'\("steam_proton" "steam_proton"\)\s+(\d+)x(\d+)\+', tree)
                            if int(m.group(1)) >= 600}
                triangle_sizes, looked = set(TRIANGLE), [0.0]
                def dxvk(w, h):
                    if (w, h) not in triangle_sizes and time.monotonic() - looked[0] > 1:
                        looked[0] = time.monotonic()
                        triangle_sizes.update(dxvk_sizes())
                    return (w, h) in triangle_sizes and (w, h) not in (chromium_size, FRESH_CHROMIUM)
                wanted['fresh dxvk'] = dxvk
            missing, pictures = judge(mark, wanted, 60)
            stop_fresh()
            seconds = time.monotonic() - started
            if missing:
                # What the seat had then: its X windows and the check's own processes.
                with open(os.path.join(o.out, 'failure.txt'), 'w') as f:
                    f.write(seat.sh(f'. {seat.dir}/client; xwininfo -root -tree 2>&1 | head -200', user='caboose', check=False))
                    f.write(seat.sh(f'for p in $(pgrep -u caboose); do tr "\\0" "\\n" < /proc/$p/environ 2>/dev/null | '
                                    f'grep -qx CABOOSE_CHAOS_SEAT={os.getpid()} && ps -o pid,lstart,args -p $p | tail -1; done',
                                    user='caboose', check=False))
                    # Every process of the user, as root sees it (a Flatpak sandbox's environment is
                    # not readable from outside it): where each waits, for an app that never started.
                    f.write('\n== processes\n')
                    f.write(seat.sh('ps -u caboose -o pid,ppid,lstart,stat,wchan:24,args --sort=start_time | cut -c1-240',
                                    check=False))
                print(f'FAIL cycle {cycle}/{o.cycles} {event} after {delay:.1f} s: no real picture from {", ".join(missing)} '
                      f'({len(pictures)} pictures since the cycle, executor generation {seat.generation})', flush=True)
                return 1
            print(f'PASS cycle {cycle}/{o.cycles} {event} after {delay:.1f} s ({seconds:.0f} s, generation {seat.generation})', flush=True)
        print(f'PASS chaos: {o.cycles}/{o.cycles} cycles, every app presented real pictures after each (seed {seed})', flush=True)
        return 0
    finally:
        seat.cleanup()


if __name__ == '__main__':
    sys.exit(main())
