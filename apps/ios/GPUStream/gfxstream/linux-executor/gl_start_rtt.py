#!/usr/bin/env python3
"""What one GL process's start costs at a phone's round-trip time: short Zink GL programs started
one after another on a private seat, through a link that delays each direction.

    python3 apps/ios/GPUStream/gfxstream/linux-executor/gl_start_rtt.py COMPUTER WORK RELEASE OUT \\
        [--rtt-ms 30] [--starts 6] [--command 'glxinfo -B'] [--env NAME=VALUE]

The seat is check_chaos.py's (its own compositor, broker, guest driver from RELEASE, X display and
sockets on COMPUTER; nothing of the computer's own session is used), served by the Linux executor
in WORK/build through a proxy that holds each direction's bytes for half of --rtt-ms. --command
(default `glxinfo -B`, which makes a Zink context and exits) runs --starts times in a row, each a
new process, with the guest's read profile on (--profile, CABOOSE_READ_PROFILE: 1 reports
the eight slowest commands per report, all every command). The first start is the
session's first of its kind; the later ones are what every further GL process of the session
pays.

The report (OUT/report.txt) gives each start's wall time and its synchronous round trips: the
blocking read time per command divided by the round-trip time, summed over every report the
process printed. A run at --rtt-ms 0 beside one at 30 gives the round trips from wall time alone:
(t30 - t0) / 30 ms.
"""
import argparse
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_chaos  # noqa: E402

PORT, XDISPLAY, PROXY_PORT = 14741, 201, 14742
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
READ = re.compile(r'CABOOSE_READ_PROFILE (.*)')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('computer')
    parser.add_argument('work')
    parser.add_argument('release')
    parser.add_argument('out')
    parser.add_argument('--rtt-ms', type=float, default=30)
    parser.add_argument('--starts', type=int, default=6)
    parser.add_argument('--command', default='glxinfo -B')
    parser.add_argument('--profile', default='all', help='CABOOSE_READ_PROFILE for each start (1 or all)')
    parser.add_argument('--env', action='append', default=[], metavar='NAME=VALUE', help='environment for each start')
    o = parser.parse_args()
    o.work, o.release = os.path.abspath(o.work), os.path.abspath(o.release)
    os.makedirs(o.out, exist_ok=True)
    o.out = os.path.abspath(o.out)
    o.gdb = False
    check_chaos.PORT, check_chaos.XDISPLAY = PORT, XDISPLAY
    # The phone's capabilities, as executor.py declares them for the phone.
    source = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'executor.py')).read()
    check_chaos.PHONE = ''.join(re.findall(r"'([^']*)'", re.search(r'FEATURES = \(([^)]*)\)', source).group(1)))
    seat = check_chaos.Seat(o)
    proxy = None
    if o.rtt_ms > 0:
        proxy = f'{seat.name}-rtt'
        check_chaos.run('docker', 'run', '-d', '--rm', '--name', proxy, '--network', f'container:{o.computer}',
                        '--cpus', '1', '--entrypoint', 'python3', 'caboose-linux-executor', '-c', DELAY_PROXY,
                        str(PROXY_PORT), str(PORT), str(o.rtt_ms / 2000))
        original = check_chaos.run

        def run(*argv, **kwargs):
            if argv[:2] == ('docker', 'run') and any('executor.py' in a for a in argv):
                argv = tuple(a.replace(f'--connect 127.0.0.1:{PORT}', f'--connect 127.0.0.1:{PROXY_PORT}') for a in argv)
            return original(*argv, **kwargs)
        check_chaos.run = run
    starts = []
    try:
        seat.start()
        seat.executor()
        seat.viewer()
        time.sleep(3)
        env = ' '.join(shlex.quote(e) for e in [f'CABOOSE_READ_PROFILE={o.profile}'] + o.env)
        for n in range(o.starts):
            log = f'{seat.dir}/start-{n}.log'
            took = seat.sh(f'. {seat.dir}/client; t0=$(date +%s%N); env {env} timeout 120 {o.command} > {log} 2>&1; '
                           f'echo status=$? ms=$(( ($(date +%s%N) - t0) / 1000000 ))', user='caboose', check=False)
            text = seat.sh(f'cat {log}', check=False)
            with open(os.path.join(o.out, f'start-{n}.log'), 'w') as f:
                f.write(text + took)
            starts.append((took.strip(), text))
    finally:
        seat.cleanup()
        if proxy:
            check_chaos.run('docker', 'rm', '-f', proxy, check=False)
    rtt = o.rtt_ms if o.rtt_ms > 0 else None
    report = [f'rtt {o.rtt_ms:g} ms, {o.starts} starts of {o.command} {" ".join(o.env)}'.rstrip()]
    for n, (took, text) in enumerate(starts):
        reads = {}
        for m in READ.finditer(text):
            for name, ms, count in re.findall(r'(\w+?\d+|\w+_\w+)=(\d+)ms/(\d+)', m.group(1)):
                total = reads.setdefault(name, [0, 0])
                total[0] += int(ms)
                total[1] += int(count)
        blocked = sum(ms for name, (ms, _) in reads.items() if not name.startswith('wait'))
        trips = f', {blocked / rtt:.0f} round trips' if rtt else ''
        top = sorted(reads.items(), key=lambda kv: -kv[1][0])
        report.append(f'start {n}: {took}, blocked {blocked} ms{trips}: ' +
                      ' '.join(f'{k}={ms}ms/{c}' for k, (ms, c) in top))
    with open(os.path.join(o.out, 'report.txt'), 'w') as f:
        f.write('\n'.join(report) + '\n')
    print('\n'.join(report))


if __name__ == '__main__':
    main()
