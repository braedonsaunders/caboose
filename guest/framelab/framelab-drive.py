#!/usr/bin/env python3
"""Frame lab's driver: runs the matrix on a computer whose GPU path executes on the phone.

    framelab-drive.py --computer ID --device UDID [--host SSH] [--apps ID,...]
                      [--stage FILE] [--out DIR] [--phone-env JSON] [--no-phone] ...

Run on the Mac the phone is attached to. In order, each step bounded by a timeout:
wakes the computer through its host (POST /v1/computers/ID/session on the host machine,
with the owner token from the host's environment file); runs --stage (a Python script
fed to `python3 -` on the host machine, for example one that installs a driver build in
the computer) once the computer is awake; copies frame lab into the computer; launches
Caboose on the phone with `xcrun devicectl ... --console` (CABOOSE_FRAMELAB=1 and the
phone's GPU diagnostics in its environment) and keeps its console; waits for the GPU
broker's socket; runs framelab-guest.py in the computer and streams its events; then
stops the phone app and the guest, kills whatever the guest launched, copies the results
back and scores each app again with the phone's records (CABOOSE_GPU_DECODE_TIMING,
`caboose-framelab: present`, pictures from Documents/framelab) on the computer's clock.

Writes DIR/<app>.json, DIR/summary.md, DIR/phone-console.log, DIR/guest-events.jsonl
and DIR/guest/ (the guest's own output). Exits 1 when an app failed.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import framelab  # noqa: E402

GUEST_DIR = '/tmp/caboose-framelab'
FILES = ('framelab.py', 'framelab-guest.py', 'matrix.json')


def log(message):
    print(f'[framelab +{time.monotonic() - START:6.1f}s] {message}', flush=True)


START = time.monotonic()


class Host:
    """The machine running the computers, over ssh."""

    def __init__(self, ssh, computer):
        self.ssh, self.computer = ssh, computer
        self.container = f'caboose-{computer}'

    def run(self, command, timeout, input=None, check=True):
        return subprocess.run(['ssh', '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes', self.ssh, command],
                              input=input, capture_output=True, timeout=timeout, check=check,
                              text=not isinstance(input, bytes))

    def exec(self, command, timeout, user='caboose', input=None, check=True):
        prefix = f'docker exec -i -u {user} -e XDG_RUNTIME_DIR=/run/user/1000 {self.container} '
        return self.run(prefix + command, timeout, input=input, check=check)

    def wake(self, env_file, port):
        script = ('set -a; . ' + shlex.quote(env_file) + '; set +a; curl -sS -m 300 -o /dev/null -w "%{http_code}" '
                  '-X POST -H "Authorization: Bearer $CABOOSE_OWNER_TOKEN" -H "Content-Type: application/json" -d "{}" '
                  f'http://127.0.0.1:{port}/v1/computers/{self.computer}/session')
        code = self.run(script, timeout=320).stdout.strip()
        if not code.startswith('2'):
            raise RuntimeError(f'the host answered {code} to waking {self.computer}')

    def wait_for(self, path, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.exec(f'test -S {shlex.quote(path)}', timeout=20, check=False).returncode == 0:
                return True
            time.sleep(1)
        return False


def stream_lines(proc, sink):
    for raw in proc.stdout:
        sink(raw.decode(errors='replace') if isinstance(raw, bytes) else raw, time.monotonic_ns())


def phone_launch(args, environment, console_path, sink):
    env = {**os.environ, 'DEVELOPER_DIR': args.developer_dir}
    timeout = str(args.phone_timeout)
    command = ['xcrun', 'devicectl', '--timeout', timeout, 'device', 'process', 'launch', '--device', args.device,
               '--terminate-existing', '--environment-variables', json.dumps(environment), '--payload-url',
               args.payload_url, '--console', args.bundle]
    log('launching the phone app')
    proc = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
    console = open(console_path, 'w')

    def keep(line, received):
        console.write(f'{received} {line}' if line.endswith('\n') else f'{received} {line}\n')
        console.flush()
        sink(line, received)

    thread = threading.Thread(target=stream_lines, args=(proc, keep), daemon=True)
    thread.start()
    return proc, console


def stop_process_group(proc, grace=5):
    if proc is None or proc.poll() is not None:
        return
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def phone_pictures(args, dest):
    """Documents/framelab from the app's container, when the phone wrote pictures."""
    env = {**os.environ, 'DEVELOPER_DIR': args.developer_dir}
    result = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                             '--domain-type', 'appDataContainer', '--domain-identifier', args.bundle,
                             '--source', 'Documents/framelab', '--destination', str(dest)],
                            env=env, capture_output=True, text=True, timeout=120)
    return result.returncode == 0 and dest.exists()


def matrix_seconds(apps):
    total = 0
    for app in apps:
        once = app.get('ready_s', 30) + app.get('warmup_s', 3) + app.get('measure_s', 15) + 15
        total += once * (2 if app.get('correctness') else 1)
    return total + 60


def rescore(out, apps, phone_records, offset, pictures):
    """Every app's scorecard again, with the phone's records and, where the phone wrote a
    settled picture of the app's window near the guest's, that picture compared."""
    cards = []
    for app in apps:
        run_path = out / 'guest' / f"{app['id']}.run.json"
        card_path = out / 'guest' / f"{app['id']}.json"
        if run_path.exists():
            run = json.loads(run_path.read_text())
            correctness = run.get('correctness')
            window = (run.get('window') or {}).get('id')
            name = framelab.phone_picture(phone_records, window, run.get('picture_ns'), offset)
            shot = pictures / name if pictures and name else None
            reference = correctness and correctness.get('reference')
            if shot and shot.exists() and reference:
                comparison = framelab.compare((out / 'guest' / reference).read_bytes(), shot.read_bytes())
                run['correctness'] = {**comparison, 'pass': framelab.verdict(comparison), 'reference': reference,
                                      'candidate': str(shot.relative_to(out)), 'candidate_source': 'phone'}
            card = framelab.scorecard(app, run, phone_records, offset)
        elif card_path.exists():
            card = json.loads(card_path.read_text())
        else:
            card = {'app': app['id'], 'ok': False, 'error': 'not run', 'path': 'none',
                    'stalls': {'count': 0, 'by_cause': {}}}
        (out / f"{app['id']}.json").write_text(json.dumps(card, indent=2))
        cards.append(card)
    return cards


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--computer', required=True, help='the computer id, e.g. c-9c400ccda8')
    parser.add_argument('--device', help='the phone (devicectl identifier); required unless --no-phone')
    parser.add_argument('--host', default='gpu-wsl', help='ssh destination of the machine running the computer')
    parser.add_argument('--host-env', default='/home/bsaun/.config/caboose/host.env',
                        help="the host's environment file there (CABOOSE_OWNER_TOKEN)")
    parser.add_argument('--host-port', default=7310, type=int)
    parser.add_argument('--stage', help='a Python script run on the host machine after waking the computer')
    parser.add_argument('--gpu-socket', default='/run/user/1000/caboose-gpu-acceptance/gpu.sock')
    parser.add_argument('--seat-env', default='/run/caboose/display.env')
    parser.add_argument('--apps', help='comma-separated app ids (default: the whole matrix)')
    parser.add_argument('--matrix', default=str(HERE / 'matrix.json'))
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--no-reference', action='store_true')
    parser.add_argument('--out', default=None)
    parser.add_argument('--bundle', default='com.braedonsaunders.caboose')
    parser.add_argument('--payload-url', default='caboose://desktop')
    parser.add_argument('--phone-env', default='{}', help='extra phone environment, JSON')
    parser.add_argument('--developer-dir', default='/Applications/Xcode.app/Contents/Developer')
    parser.add_argument('--no-phone', action='store_true', help='run the guest side only (no phone records)')
    parser.add_argument('--no-wake', action='store_true', help='the computer is awake; do not ask its host')
    parser.add_argument('--socket-timeout', default=90, type=int, help='seconds to wait for the GPU socket')
    args = parser.parse_args()
    if not args.no_phone and not args.device:
        parser.error('--device is required unless --no-phone')

    apps = json.loads(Path(args.matrix).read_text())['apps']
    if args.apps:
        wanted = args.apps.split(',')
        apps = [a for a in apps if a['id'] in wanted]
        if len(apps) != len(wanted):
            parser.error('unknown app ids')
    guest_seconds = matrix_seconds(apps)
    args.phone_timeout = guest_seconds + args.socket_timeout + 120
    out = Path(args.out or tempfile.mkdtemp(prefix='caboose-framelab-'))
    out.mkdir(parents=True, exist_ok=True)
    host = Host(args.host, args.computer)

    phone_records, clock_samples = [], []
    lock = threading.Lock()

    def phone_line(line, received):
        record = framelab.parse_line(line, received)
        if record:
            if record['kind'] == 'phone_present' and {'presented_ns', 'now_ns'} <= record.keys():
                # The phone's presentation time, moved onto the reader's clock: it was
                # printed now_ns - presented_ns after it was shown.
                record['presented_ns'] = received - (record['now_ns'] - record['presented_ns'])
            with lock:
                phone_records.append(record)

    events = open(out / 'guest-events.jsonl', 'w')

    def guest_line(line, received):
        events.write(f'{received} {line}' if line.endswith('\n') else f'{received} {line}\n')
        events.flush()
        try:
            event = json.loads(line)
        except ValueError:
            sys.stdout.write(f'  guest: {line}')
            return
        clock_samples.append((received, event['t']))
        if event['event'] in ('launch', 'window', 'scorecard', 'skipped', 'done'):
            detail = {k: v for k, v in event.items() if k not in ('t', 'event', 'command')}
            log(f"guest {event['event']}: {json.dumps(detail)[:200]}")

    phone = console = guest = None
    failed = True
    # However the driver is stopped, the cleanup below runs.
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda number, _: sys.exit(128 + number))
    try:
        if not args.no_wake:
            log(f'waking {args.computer}')
            host.wake(args.host_env, args.host_port)
        if args.stage:
            log(f'staging with {args.stage}')
            staged = host.run('python3 -', timeout=600, input=Path(args.stage).read_text())
            log(f'staged: {staged.stdout.strip()[-400:]}')
        host.exec(f'rm -rf {GUEST_DIR}', timeout=30, user='root')
        host.exec(f'mkdir -p {GUEST_DIR}/out', timeout=30)
        for name in FILES:
            host.exec(f'sh -c "cat > {GUEST_DIR}/{name}"', timeout=30, input=(HERE / name).read_bytes())
        if not args.no_phone:
            environment = {'CABOOSE_PRIVATE_GPU_INDEXED': '1', 'CABOOSE_PRIVATE_GPU_MEMORY_AUDIT': '1',
                           'CABOOSE_FRAMELAB': '1', **json.loads(args.phone_env)}
            phone, console = phone_launch(args, environment, out / 'phone-console.log', phone_line)
            log('waiting for the GPU socket')
            if not host.wait_for(args.gpu_socket, args.socket_timeout):
                raise TimeoutError(f'no {args.gpu_socket} within {args.socket_timeout} s')
            log('GPU socket is up')
        options = ['--out', f'{GUEST_DIR}/out', '--env', args.seat_env]
        options += ['--apps', ','.join(a['id'] for a in apps)]
        options += ['--offline'] if args.offline else []
        options += ['--no-reference'] if args.no_reference else []
        command = ['ssh', '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes', args.host,
                   f'docker exec -i -u caboose -e XDG_RUNTIME_DIR=/run/user/1000 {host.container} '
                   f'python3 -u {GUEST_DIR}/framelab-guest.py ' + ' '.join(map(shlex.quote, options))]
        log(f'running {len(apps)} apps (at most {guest_seconds} s)')
        guest = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 start_new_session=True)
        reader = threading.Thread(target=stream_lines, args=(guest, guest_line), daemon=True)
        reader.start()
        try:
            guest.wait(timeout=guest_seconds)
        except subprocess.TimeoutExpired:
            log('the guest overran the matrix timeout; stopping it')
        reader.join(timeout=10)
        failed = False
    finally:
        stop_process_group(phone)
        if console:
            console.close()
        stop_process_group(guest)
        # The guest stops its apps on SIGTERM; anything left of it, or of what it ran,
        # goes with it.
        host.exec('pkill -TERM -f framelab-guest.py', timeout=30, check=False)
        time.sleep(3)
        host.exec('pkill -KILL -f framelab-guest.py', timeout=30, check=False)
        started = []
        for line in (out / 'guest-events.jsonl').read_text().splitlines():
            try:
                event = json.loads(line.split(' ', 1)[1])
            except (ValueError, IndexError):
                continue
            if event.get('event') == 'launch':
                started.append(event['pid'])
        for pid in started:
            host.exec(f'sh -c "pkill -KILL -s {pid}; kill -KILL {pid}" 2>/dev/null', timeout=30, check=False)
        host.exec(f'rm -f /run/user/1000/caboose-gpu-present-trace', timeout=30, check=False)
        events.close()
        archive = host.exec(f'tar -C {GUEST_DIR}/out -cf - .', timeout=120, check=False, input=b'')
        (out / 'guest').mkdir(exist_ok=True)
        if archive.returncode == 0:
            subprocess.run(['tar', '-C', str(out / 'guest'), '-xf', '-'], input=archive.stdout, check=False)
        host.exec(f'rm -rf {GUEST_DIR}', timeout=30, user='root', check=False)

    pictures = None
    if not args.no_phone and not failed:
        dest = out / 'phone-pictures'
        try:
            if phone_pictures(args, dest):
                pictures = dest / 'framelab' if (dest / 'framelab').is_dir() else dest
        except subprocess.TimeoutExpired:
            log('copying the phone pictures timed out')
    offset = framelab.clock_offset(clock_samples)
    cards = rescore(out, apps, phone_records, offset, pictures)
    table = framelab.summary_table([c for c in cards if 'pacing' in c])
    notes = [f"{c['app']}: {c.get('skipped') or c.get('error')}" for c in cards if not c.get('ok')]
    table += ('\n' + '\n'.join(notes) + '\n') if notes else ''
    table += f"\nphone records: {len(phone_records)}; clock offset {offset} ns from {len(clock_samples)} guest events\n"
    (out / 'summary.md').write_text(table)
    print(table)
    log(f'results in {out}')
    sys.exit(0 if not failed and all(c.get('ok') or c.get('skipped') for c in cards) else 1)


if __name__ == '__main__':
    main()
