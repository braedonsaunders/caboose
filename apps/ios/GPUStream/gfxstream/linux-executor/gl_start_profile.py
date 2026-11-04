#!/usr/bin/env python3
"""Where a first GL start's time goes: Steam's first start on a private seat, profiled from the
executor's side.

    python3 apps/ios/GPUStream/gfxstream/linux-executor/gl_start_profile.py COMPUTER WORK RELEASE OUT \\
        --steam-home DIR [--seconds 180]

The seat is check_chaos.py's (its own compositor, broker, guest driver from RELEASE, X display and
sockets on COMPUTER; nothing of the computer's own session is used), served by the Linux executor
in WORK/build with no caches, so every start is a first start. Steam starts on --steam-home, a
home of the check's own, with the guest's read profile on (CABOOSE_READ_PROFILE=1).

The report (OUT/report.txt) gives, relative to Steam's start: when its first real picture
arrived; when each Vulkan instance was made, by which application; Steam's own milestones from
its logs (each steamwebhelper start, and each of its GPU processes that exits during
initialization, which Chromium answers by starting another, and after three by ending the
webhelper, which Steam starts again); the commands the executor took longest on
(CABOOSE_GPU_DECODE_TIMING, 50 ms or more); and from the guest, per Vulkan command, the
synchronous round trips it waited for (CABOOSE_READ_PROFILE, which Steam's processes print to
its console-linux.txt and webhelper-linux.txt when they exit). The executor here answers in
microseconds, so a phone's start is about this start's time plus its round trips times the phone's
round-trip time.
"""
import argparse
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_chaos  # noqa: E402

INSTANCE = re.compile(r"^(\S+) .*Created VkInstance:\S+ for application:'([^']*)'")
STEAM_LOG = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)[^\]]*\] (.*)')
MILESTONES = (('webhelper start', re.compile(r'^exec \./steamwebhelper')),
              ('GPU process failed to initialize', re.compile(r'Exiting GPU process due to errors during initialization')),
              ('surface bind refused', re.compile(r'CABOOSE_GPU_SURFACE_BIND .* attempt=1 refused')))
PROXY_PORT = 14707
# A TCP proxy that delays each direction by argv[3] seconds, in order: argv[1] listens, argv[2] is
# the seat's broker on 127.0.0.1.
DELAY_PROXY = '''
import asyncio, sys, time
listen, target, delay = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
async def pump(reader, writer):
    queue = asyncio.Queue()
    async def feed():
        while True:
            data = await reader.read(1 << 16)
            await queue.put((time.monotonic() + delay, data))
            if not data: return
    asyncio.ensure_future(feed())
    while True:
        due, data = await queue.get()
        wait = due - time.monotonic()
        if wait > 0: await asyncio.sleep(wait)
        if not data:
            writer.close(); return
        writer.write(data); await writer.drain()
async def client(reader, writer):
    up_reader, up_writer = await asyncio.open_connection('127.0.0.1', target)
    await asyncio.gather(pump(reader, up_writer), pump(up_reader, writer), return_exceptions=True)
async def main():
    server = await asyncio.start_server(client, '127.0.0.1', listen)
    await server.serve_forever()
asyncio.run(main())
'''
DECODE = re.compile(r'^(\S+) CABOOSE_GPU_DECODE_TIMING stream=(\d+) opcode=(\d+) elapsed_us=(\d+)')
READ = re.compile(r'CABOOSE_READ_PROFILE (.*)')


def stamp(text):
    """Seconds since the epoch of a docker log timestamp."""
    day, clock = text.rstrip('Z').split('T')
    whole, _, frac = clock.partition('.')
    return time.mktime(time.strptime(f'{day}T{whole}', '%Y-%m-%dT%H:%M:%S')) - time.timezone + float('0.' + (frac or '0'))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('computer')
    parser.add_argument('work')
    parser.add_argument('release')
    parser.add_argument('out')
    parser.add_argument('--steam-home', required=True, help="a home of the check's own with a Steam Flatpak profile")
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--prepare', default='', help="shell run in the seat before Steam starts (SEAT is its directory)")
    parser.add_argument('--rtt-ms', type=float, default=0,
                        help="round-trip time added between the executor and the seat's broker, as a phone's network adds")
    parser.add_argument('--capability-history', metavar='DIR',
                        help="a directory (in the computer) that carries the seat's capability logs from run to run, "
                             "as a computer keeps them from session to session (warmup/README.md)")
    parser.add_argument('--keep', action='store_true', help="keep Steam running for --seconds after its first picture")
    parser.add_argument('--steam-arg', action='append', default=[], help="an argument for the Steam client")
    parser.add_argument('--flatpak-env', action='append', default=[], metavar='NAME=VALUE',
                        help="an environment variable for Steam's Flatpak (SEAT is the seat's directory)")
    o = parser.parse_args()
    o.work, o.release = os.path.abspath(o.work), os.path.abspath(o.release)
    os.makedirs(o.out, exist_ok=True)
    o.out = os.path.abspath(o.out)
    o.gdb = False
    # A port and X display of its own, apart from a chaos run's.
    check_chaos.PORT, check_chaos.XDISPLAY = 14697, 183
    # The phone's capabilities, as executor.py declares them for the phone (check_chaos.py
    # keeps an older list of its own).
    source = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'executor.py')).read()
    check_chaos.PHONE = ''.join(re.findall(r"'([^']*)'", re.search(r'FEATURES = \(([^)]*)\)', source).group(1)))
    seat = check_chaos.Seat(o)
    proxy = None
    if o.rtt_ms > 0:
        # The executor connects through a proxy that holds each direction's bytes for half the
        # round trip, in the computer's network namespace but in a container of its own: only
        # this seat's executor connection is delayed.
        proxy = f'{seat.name}-rtt'
        check_chaos.run('docker', 'run', '-d', '--rm', '--name', proxy, '--network', f'container:{o.computer}',
                        '--cpus', '1', '--entrypoint', 'python3', 'caboose-linux-executor', '-c', DELAY_PROXY,
                        str(PROXY_PORT), str(check_chaos.PORT), str(o.rtt_ms / 2000))
        original = check_chaos.run
        def run(*argv, **kwargs):
            if argv[:2] == ('docker', 'run') and any('executor.py' in a for a in argv):
                argv = tuple(a.replace(f'--connect 127.0.0.1:{check_chaos.PORT}', f'--connect 127.0.0.1:{PROXY_PORT}')
                             for a in argv)
            return original(*argv, **kwargs)
        check_chaos.run = run
    report = []
    try:
        seat.start()
        if o.capability_history:
            # Earlier runs' capability logs, where the broker finds earlier sessions' logs.
            # The broker's own user and private modes, as its checks require.
            seat.sh(f'umask 077; mkdir -p {o.capability_history} {seat.dir}/run/gpu/capabilities/history && '
                    f'for f in {o.capability_history}/formats-*.bin; do [ -f "$f" ] && cp "$f" {seat.dir}/run/gpu/capabilities/history/; done; true',
                    user='caboose', check=False)
        executor = seat.executor()
        seat.viewer()
        time.sleep(3)
        mark = check_chaos.now()
        if o.prepare:
            seat.sh(o.prepare.replace('SEAT', seat.dir), user='caboose')
        extra = ''.join(f'--env={shlex.quote(e.replace("SEAT", seat.dir))} ' for e in o.flatpak_env)
        started = time.time()
        seat.app('steam', f'env HOME={o.steam_home} CABOOSE_READ_PROFILE=1 dbus-run-session -- flatpak run '
                 f'--env=CABOOSE_CHAOS_SEAT={os.getpid()} --env=CABOOSE_READ_PROFILE=1 {extra}'
                 '--env=CABOOSE_GFXSTREAM_SOCKET=$CABOOSE_GFXSTREAM_SOCKET --env=CABOOSE_GFXSTREAM_SURFACE_SOCKET=$CABOOSE_GFXSTREAM_SURFACE_SOCKET '
                 f'--env=VK_DRIVER_FILES={seat.dir}/icd.json:{seat.dir}/icd32.json:{check_chaos.FLATPAK_LAVAPIPE} '
                 f'--env=PRESSURE_VESSEL_FILESYSTEMS_RW={seat.dir} --filesystem={seat.dir} com.valvesoftware.Steam '
                 + ' '.join(shlex.quote(a) for a in o.steam_arg))
        first = None
        deadline = time.monotonic() + o.seconds
        while time.monotonic() < deadline:
            good = [p for p in seat.pictures(mark) if p[4]]
            if good and first is None:
                first = time.time() - started
                report.append(f'first real picture {first:.1f} s after Steam started ({good[0][2]}x{good[0][3]})')
                # Let the start settle, so the processes that drew it exit and print their profiles.
                if not o.keep:
                    deadline = min(deadline, time.monotonic() + 30)
            time.sleep(1)
        if first is None:
            report.append(f'no real picture within {o.seconds} s')
        log = check_chaos.run('docker', 'logs', '--timestamps', executor, check=False)
        seat.stop('com.valvesoftware.Steam')
        seat.sh(f'pkill -TERM -f steamwebhelper; pkill -TERM -f "{o.steam_home}"', check=False)
        time.sleep(10)
        steam = seat.sh(f'cat {seat.dir}/steam.log', check=False)
        if o.capability_history:
            seat.sh(f'umask 077; mkdir -p {o.capability_history} && '
                    f'for f in {seat.dir}/run/gpu/capabilities/formats-*.bin; do [ -f "$f" ] && cp "$f" {o.capability_history}/; done; '
                    f'ls -t {o.capability_history}/formats-*.bin 2>/dev/null | tail -n +5 | xargs -r rm -f; true',
                    user='caboose', check=False)
            report.append('capability logs kept: ' + seat.sh(f'cd {o.capability_history} && find . -type f | head -20 | tr "\n" " "', check=False))
        logs = f'{o.steam_home}/.var/app/com.valvesoftware.Steam/.local/share/Steam/logs'
        steam += seat.sh(f'cat {logs}/console-linux.txt {logs}/webhelper-linux.txt', check=False)
    finally:
        seat.cleanup()
        if proxy:
            check_chaos.run('docker', 'rm', '-f', proxy, check=False)
    t0 = stamp(mark)
    for line in log.splitlines():
        m = INSTANCE.match(line)
        if m and stamp(m.group(1)) >= t0:
            report.append(f'  {stamp(m.group(1)) - t0:6.1f} s Vulkan instance of {m.group(2) or "(unnamed)"}')
    for line in steam.splitlines():
        m = STEAM_LOG.match(line)
        if not m:
            continue
        at = time.mktime(time.strptime(m.group(1), '%Y-%m-%d %H:%M:%S')) - time.timezone - t0
        if at < -1:
            continue
        for what, pattern in MILESTONES:
            if pattern.search(m.group(2)):
                report.append(f'  {at:6.0f} s {what}: {m.group(2)[:120]}')
    slow = []
    for line in log.splitlines():
        m = DECODE.match(line)
        if m:
            slow.append((stamp(m.group(1)) - t0, int(m.group(2)), int(m.group(3)), int(m.group(4)) / 1000))
    report.append(f'executor commands of 50 ms or more: {len(slow)}, {sum(s[3] for s in slow):.0f} ms in all')
    for at, stream, opcode, ms in sorted(slow, key=lambda s: -s[3])[:25]:
        report.append(f'  at {at:6.1f} s stream {stream} opcode {opcode}: {ms:.0f} ms')
    periods = [l for l in log.splitlines() if 'CABOOSE_GPU_DECODE_PERIOD' in l or 'connected' in l.lower()]
    report.append(f'executor period lines: {len(periods)} (in executor.log)')
    profiles = [m.group(1) for line in steam.splitlines() for m in [READ.search(line)]
                if m and (not STEAM_LOG.match(line) or
                          time.mktime(time.strptime(STEAM_LOG.match(line).group(1), '%Y-%m-%d %H:%M:%S')) - time.timezone >= t0 - 1)]
    report.append(f'guest read profiles: {len(profiles)}')
    report.extend('  ' + p[:400] for p in profiles)
    with open(os.path.join(o.out, 'executor.log'), 'w') as f:
        f.write(log)
    with open(os.path.join(o.out, 'steam.log'), 'w') as f:
        f.write(steam)
    with open(os.path.join(o.out, 'report.txt'), 'w') as f:
        f.write('\n'.join(report) + '\n')
    print('\n'.join(report))


if __name__ == '__main__':
    main()
