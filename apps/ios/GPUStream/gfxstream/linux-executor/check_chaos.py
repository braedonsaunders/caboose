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
app (glxgears through Zink, whose window the compositor's own images show) and, with --triangle, DXVK's d3d11 triangle through
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
         'executor-resume,zstd-stream,guest-buffer-views,batched-descriptor-sets-inline')
PICTURE = re.compile(r'^(\S+) CABOOSE_LINUX_EXECUTOR picture window=(\S+) serial=\d+ (\d+)x(\d+) format=\d+ '
                     r'content=([0-9.]+) colours=(\d+)')
PORT, XDISPLAY = 14695, 181
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

    def start(self):
        d = self.dir
        files = os.path.join(self.o.release, 'files')
        self.sh(f'mkdir -m 0700 -p {d}/run/gpu {d}/home {d}/bin && head -c 24 /dev/urandom | od -An -tx1 | tr -d " \\n" > {d}/token')
        # The release's own compositor, broker and driver, in the seat's directory.
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so'),
            f'{self.computer}:{d}/libvulkan_gfxstream.so')
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/bin/caboose-display'), f'{self.computer}:{d}/bin/caboose-display')
        run('docker', 'cp', '-q', os.path.join(files, 'usr/local/libexec'), f'{self.computer}:{d}/libexec')
        icd = json.dumps({'file_format_version': '1.0.0', 'ICD': {'library_path': f'{d}/libvulkan_gfxstream.so', 'api_version': '1.3.0'}})
        env = '\n'.join([
            f'export PATH=/usr/local/bin:/usr/bin:/bin HOME={d}/home XDG_RUNTIME_DIR={d}/run',
            f'export VK_DRIVER_FILES={d}/icd.json:/usr/share/vulkan/icd.d/lvp_icd.json CABOOSE_GPU_ROUTING=1 NODEVICE_SELECT=1',
            'export GALLIUM_DRIVER=zink LIBGL_KOPPER_DRI2=1 MESA_GL_VERSION_OVERRIDE=4.5COMPAT MESA_GLSL_VERSION_OVERRIDE=450 ZINK_DESCRIPTORS=lazy',
            f'export CABOOSE_GAME_SOCKET={d}/run/game.sock CABOOSE_CHAOS_SEAT={os.getpid()}', ''])
        self.sh(f"printf '%s' {shlex.quote(icd)} > {d}/icd.json && printf '%s' {shlex.quote(env)} > {d}/env && chown -R caboose {d}")
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
        self.wait(lambda: 'session ready' in run('docker', 'logs', name, check=False), 30, 'the executor')
        return name

    def end_executor(self):
        name = self.executors[-1]
        self.logs[name] = run('docker', 'logs', '--timestamps', name, check=False)
        run('docker', 'rm', '-f', name, check=False)

    def viewer(self, start=True):
        self.sh(f"pkill -TERM -f 'caboose-display-probe --url ws://127.0.0.1:{PORT}/'", check=False)
        if start:
            self.sh(f'exec caboose-display-probe --url ws://127.0.0.1:{PORT}/ --token-file {self.dir}/token --duration 100000 '
                    f'--display 1280x800@60x1 >> {self.dir}/probe.log 2>&1', user='caboose', detach=True)

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
    parser.add_argument('--steam-home', help="a home of the check's own holding a Steam Flatpak profile (never the owner's)")
    parser.add_argument('--triangle', help="DXVK's d3d11 triangle.exe, inside --steam-home's Flatpak data")
    parser.add_argument('--proton', default='/opt/caboose-games/GE-Proton11-11/proton')
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
                 f'--window-size=700,500 {shlex.quote(STILL)}')
        seat.app(f'fresh-gl-{n}', 'timeout 40 glxgears -geometry 320x240')
        expected = {'fresh chromium': None, 'fresh gl': None}
        if o.triangle:
            bench = os.path.dirname(o.triangle)
            seat.app(f'fresh-dxvk-{n}', f'env HOME={o.steam_home} timeout 45 flatpak run --env=CABOOSE_GFXSTREAM_SOCKET=$CABOOSE_GFXSTREAM_SOCKET '
                     f'--env=CABOOSE_GFXSTREAM_SURFACE_SOCKET=$CABOOSE_GFXSTREAM_SURFACE_SOCKET --env=VK_DRIVER_FILES=$VK_DRIVER_FILES '
                     f'--env=CABOOSE_CHAOS_SEAT={os.getpid()} --filesystem={seat.dir} --command=sh com.valvesoftware.Steam -c '
                     f'"export STEAM_COMPAT_DATA_PATH={bench}/compat/chaos STEAM_COMPAT_CLIENT_INSTALL_PATH={o.steam_home}/.var/app/'
                     f'com.valvesoftware.Steam/.local/share/Steam; mkdir -p {bench}/compat/chaos; exec {o.proton} waitforexitandrun {o.triangle}"')
            expected['fresh dxvk'] = None
        return expected

    def stop_fresh():
        seat.stop(f'{seat.dir}/home/fresh-')
        seat.stop('glxgears -geometry 320x240')
        seat.stop('triangle.exe')

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
        if o.steam_home:
            seat.app('steam', f'env HOME={o.steam_home} dbus-run-session -- flatpak run --env=CABOOSE_CHAOS_SEAT={os.getpid()} '
                     '--env=CABOOSE_GFXSTREAM_SOCKET=$CABOOSE_GFXSTREAM_SOCKET --env=CABOOSE_GFXSTREAM_SURFACE_SOCKET=$CABOOSE_GFXSTREAM_SURFACE_SOCKET '
                     f'--env=VK_DRIVER_FILES=$VK_DRIVER_FILES --env=PRESSURE_VESSEL_FILESYSTEMS_RW={seat.dir} --filesystem={seat.dir} com.valvesoftware.Steam')
        # Learn the long-lived apps' picture sizes: Chromium's is the largest, Steam's the other.
        time.sleep(60 if o.steam_home else 15)
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
        events = ['kill', 'drop', 'stall', 'viewer', 'startup']
        for cycle in range(1, o.cycles + 1):
            event = rng.choice(events)
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
            wanted['fresh chromium'] = lambda w, h, big=chromium_size: (w, h) != big and 500 <= w <= 720 and 300 <= h <= 520
            # glxgears draws with Zink and reaches the compositor as an X11 window's pixels; the
            # compositor's own window images (the display's size) show it.
            wanted['fresh gl in the compositor'] = lambda w, h: (w, h) == (1280, 800)
            if 'fresh dxvk' in fresh:
                wanted['fresh dxvk'] = lambda w, h, known={chromium_size, (1280, 800)}: (w, h) not in known and w >= 600
            missing, pictures = judge(mark, wanted, 60)
            stop_fresh()
            seconds = time.monotonic() - started
            if missing:
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
