#!/usr/bin/env python3
"""What a Windows application's readbacks cost: a D3D11 program on a private seat, at a phone's
round-trip time.

    python3 apps/ios/GPUStream/gfxstream/linux-executor/readback_profile.py COMPUTER WORK RELEASE OUT \\
        --steam-home DIR --exe PATH [--args '60 4 50'] [--rtt-ms 30] [--seconds 75] [--env NAME=VALUE]

The seat is check_chaos.py's (its own compositor, broker, guest driver from RELEASE, X display and
sockets on COMPUTER; nothing of the computer's own session is used), served by the Linux executor
in WORK/build through a proxy that holds each direction's bytes for half of --rtt-ms. PATH, inside
--steam-home's Steam Flatpak data, runs through Proton (--proton) with the arguments --args, such
as d3d11_stress.exe built from d3d11-stress.cpp beside this script, which reads back staging
copies every frame. --env adds environment to it (CABOOSE_LAZY_READBACK=0 reads every
invalidated range at once), and --executor-env to the executor (CABOOSE_PIPELINE_LANE_THREADS).

The report (OUT/report.txt) gives the program's frame rates, its FAIL lines, the coherent
memory the driver read back and how (CABOOSE_GPU_MEMORY_TRAFFIC: invalidated bytes and calls,
bytes left lazy, and the bytes and round trips their fills read), and its synchronous round trips
(CABOOSE_READ_PROFILE, summed per command).
"""
import argparse
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_chaos  # noqa: E402

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
FPS = re.compile(r'frames=(\d+) fps=([\d.]+)')
TRAFFIC = re.compile(r'CABOOSE_GPU_MEMORY_TRAFFIC (.*)')
READ = re.compile(r'CABOOSE_READ_PROFILE (.*)')
TRAFFIC_FIELDS = ('sent_bytes', 'coherent_invalidated_bytes', 'coherent_invalidates', 'app_invalidated_bytes', 'app_invalidates',
                  'coherent_delivered_bytes', 'lazy_bytes', 'lazy_filled_bytes', 'lazy_fills', 'received_bytes')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('computer')
    parser.add_argument('work')
    parser.add_argument('release')
    parser.add_argument('out')
    parser.add_argument('--steam-home', required=True, help="a home of the check's own with a Steam Flatpak profile")
    parser.add_argument('--exe', required=True, help="the Windows program, inside --steam-home's Steam Flatpak data")
    parser.add_argument('--args', default='', help='its arguments')
    parser.add_argument('--env', action='append', default=[], metavar='NAME=VALUE', help='environment for it')
    parser.add_argument('--executor-env', action='append', default=[], metavar='NAME=VALUE',
                        help="environment for the executor (CABOOSE_PIPELINE_LANE_THREADS=8, for one)")
    parser.add_argument('--rtt-ms', type=float, default=30)
    parser.add_argument('--seconds', type=int, default=75)
    parser.add_argument('--proton', default='/opt/caboose-games/GE-Proton11-11/proton')
    o = parser.parse_args()
    o.work, o.release = os.path.abspath(o.work), os.path.abspath(o.release)
    os.makedirs(o.out, exist_ok=True)
    o.out = os.path.abspath(o.out)
    o.gdb = False
    # A port and X display of its own, apart from a chaos run's.
    check_chaos.PORT, check_chaos.XDISPLAY = 14697, 183
    # The phone's capabilities, as executor.py declares them for the phone.
    source = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'executor.py')).read()
    check_chaos.PHONE = ''.join(re.findall(r"'([^']*)'", re.search(r'FEATURES = \(([^)]*)\)', source).group(1)))
    seat = check_chaos.Seat(o)
    marker = f'CABOOSE_CHAOS_SEAT={os.getpid()}'
    proxy = None
    original = check_chaos.run
    def run(*argv, **kwargs):
        if argv[:2] == ('docker', 'run') and any('executor.py' in a for a in argv):
            if proxy:
                argv = tuple(a.replace(f'--connect 127.0.0.1:{check_chaos.PORT}', f'--connect 127.0.0.1:{PROXY_PORT}')
                             for a in argv)
            argv = argv[:2] + tuple(x for e in o.executor_env for x in ('-e', e)) + argv[2:]
        return original(*argv, **kwargs)
    check_chaos.run = run
    if o.rtt_ms > 0:
        proxy = f'{seat.name}-rtt'
        check_chaos.run('docker', 'run', '-d', '--rm', '--name', proxy, '--network', f'container:{o.computer}',
                        '--cpus', '1', '--entrypoint', 'python3', 'caboose-linux-executor', '-c', DELAY_PROXY,
                        str(PROXY_PORT), str(check_chaos.PORT), str(o.rtt_ms / 2000))
    output = ''
    try:
        seat.start()
        seat.executor()
        seat.viewer()
        time.sleep(3)
        bench = os.path.dirname(o.exe)
        # The program's output, which Proton's launcher does not pass through, goes to a file:
        # Wine's cmd runs it from a batch file with its output redirected (Z: is the root).
        win = lambda path: 'Z:' + path.replace('/', '\\')
        batch = f'{seat.dir}/program.bat'
        script = f'@echo off\r\n"{win(o.exe)}" %*> "{win(seat.dir + "/program-output.txt")}" 2>&1\r\n'
        seat.sh(f'printf %s {shlex.quote(script)} > {batch}', user='caboose')
        extra = ''.join(f'--env={shlex.quote(e)} ' for e in o.env)
        seat.app('program', f'env HOME={o.steam_home} timeout {o.seconds + 120} flatpak run '
                 '--env=CABOOSE_GFXSTREAM_SOCKET=$CABOOSE_GFXSTREAM_SOCKET '
                 '--env=CABOOSE_GFXSTREAM_SURFACE_SOCKET=$CABOOSE_GFXSTREAM_SURFACE_SOCKET '
                 f'--env=VK_DRIVER_FILES={seat.dir}/icd.json:{seat.dir}/icd32.json:{check_chaos.FLATPAK_LAVAPIPE} '
                 f'--env={marker} --env=CABOOSE_READ_PROFILE=1 {extra}'
                 f'--filesystem={seat.dir} --filesystem={os.path.dirname(o.proton)}:ro --command=sh com.valvesoftware.Steam -c '
                 f'"export STEAM_COMPAT_DATA_PATH={bench}/compat/1 STEAM_COMPAT_CLIENT_INSTALL_PATH={o.steam_home}/.var/app/'
                 f'com.valvesoftware.Steam/.local/share/Steam; mkdir -p {bench}/compat/1; '
                 f'exec {o.proton} waitforexitandrun {batch} {o.args}"')
        deadline = time.monotonic() + o.seconds + 60
        while time.monotonic() < deadline:
            output = seat.sh(f'cat {seat.dir}/program-output.txt {seat.dir}/program.log', check=False)
            if re.search(r'^done ', output, re.M):
                break
            time.sleep(2)
    finally:
        # Only this profile's processes: those carrying its marker (the Flatpak sandbox, which
        # ends its Wine session with it).
        for signal in ('TERM', 'KILL'):
            seat.sh(f'for p in $(pgrep -u caboose -f com.valvesoftware.Steam); do tr "\\0" "\\n" < /proc/$p/environ '
                    f'2>/dev/null | grep -qx {marker} && kill -{signal} $p; done', user='caboose', check=False)
            time.sleep(3)
        output = seat.sh(f'cat {seat.dir}/program-output.txt {seat.dir}/program.log', check=False) or output
        seat.cleanup()
        if proxy:
            check_chaos.run('docker', 'rm', '-f', proxy, check=False)
    report = [f'rtt {o.rtt_ms:g} ms, {o.exe} {o.args} {" ".join(o.env)} {" ".join(o.executor_env)}'.rstrip()]
    rates = [(int(m.group(1)), float(m.group(2))) for m in FPS.finditer(output)]
    if rates:
        steady = [fps for _, fps in rates[1:]] or [rates[0][1]]
        report.append(f'frames {rates[-1][0]}, fps per 5 s: {" ".join(f"{fps:.2f}" for _, fps in rates)}; '
                      f'mean after the first {sum(steady) / len(steady):.2f}')
    report.extend(line for line in output.splitlines() if line.startswith(('FAIL ', 'phase ', 'done ')))
    totals = dict.fromkeys(TRAFFIC_FIELDS, 0)
    for m in TRAFFIC.finditer(output):
        for field in TRAFFIC_FIELDS:
            v = re.search(rf'\b{field}=(\d+)', m.group(1))
            if v:
                totals[field] += int(v.group(1))
    report.append('memory: ' + ' '.join(f'{k}={v}' for k, v in totals.items()))
    reads = {}
    for m in READ.finditer(output):
        for name, ms, count in re.findall(r'(\w+?\d+)=(\d+)ms/(\d+)', m.group(1)):
            total = reads.setdefault(name, [0, 0])
            total[0] += int(ms); total[1] += int(count)
    top = sorted(reads.items(), key=lambda kv: -kv[1][0])[:12]
    report.append('round trips: ' + ' '.join(f'{k}={ms}ms/{n}' for k, (ms, n) in top))
    with open(os.path.join(o.out, 'program.log'), 'w') as f:
        f.write(output)
    with open(os.path.join(o.out, 'report.txt'), 'w') as f:
        f.write('\n'.join(report) + '\n')
    print('\n'.join(report))


if __name__ == '__main__':
    main()
