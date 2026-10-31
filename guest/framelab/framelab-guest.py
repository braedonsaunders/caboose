#!/usr/bin/env python3
"""Frame lab's guest side: runs the matrix on this computer's seat and measures each app.

    framelab-guest.py [--matrix FILE] [--apps ID,...] [--out DIR] [--env FILE]
                      [--broker-log FILE] [--offline] [--no-reference]

Run as the seat's owner (caboose) inside the computer. Each app is launched with the
seat's launch environment (--env, default /run/caboose/display.env) and measured through
the compositor's control socket (its windows, `frames` timeline, injected input and
screenshots), /proc (the app's CPU), the GPU broker's log (CABOOSE_GPU_PRESENT and
CABOOSE_GPU_STREAM, switched on with $XDG_RUNTIME_DIR/caboose-gpu-present-trace for the
run) and the app's own stderr (CABOOSE_READ_PROFILE). For apps marked `correctness`, the
app is run once more with the phone's Vulkan driver disabled for the CPU reference
picture. Writes DIR/<app>.run.json (raw), DIR/<app>.json (scorecard), the pictures and
DIR/summary.md; prints one JSON event per line on stdout, each with `t`, this computer's
CLOCK_MONOTONIC in nanoseconds, which the driver uses to align the phone's clock.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import framelab  # noqa: E402

TICK = os.sysconf('SC_CLK_TCK')
OUT_LOCK = threading.Lock()


def now():
    return time.monotonic_ns()


def emit(event, **fields):
    with OUT_LOCK:
        print(json.dumps({'t': now(), 'event': event, **fields}), flush=True)


def read_env(path):
    env = {}
    for line in Path(path).read_text().splitlines():
        if '=' in line and not line.startswith('#'):
            key, value = line.split('=', 1)
            env[key] = shlex.split(value)[0] if value else ''
    return env


class Control:
    """The compositor's control socket (guest/display/compositor/src/control.rs)."""

    def __init__(self, path):
        self.path = path

    def ask(self, request, timeout=10):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(timeout)
            s.connect(self.path)
            s.sendall(request.encode() + b'\n')
            data = b''
            while b'\n' not in data:
                chunk = s.recv(1 << 16)
                if not chunk:
                    raise ConnectionError('control socket closed')
                data += chunk
            head, rest = data.split(b'\n', 1)
            reply = json.loads(head)
            while len(rest) < reply.get('png', 0):
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                rest += chunk
            if not reply.get('ok'):
                raise RuntimeError(f"{request.split()[0]}: {reply.get('error')}")
            return reply, rest


def tree(root):
    """The pids of root and its descendants."""
    children = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / 'stat').read_text()
        except OSError:
            continue
        ppid = int(stat[stat.rindex(')') + 2:].split()[1])
        children.setdefault(ppid, []).append(int(entry.name))
    out, todo = [], [root]
    while todo:
        pid = todo.pop()
        out.append(pid)
        todo += children.get(pid, [])
    return out


def cpu_seconds(pids):
    total = 0
    for pid in pids:
        try:
            stat = Path(f'/proc/{pid}/stat').read_text()
        except OSError:
            continue
        values = stat[stat.rindex(')') + 2:].split()
        total += sum(int(v) for v in values[11:15])  # utime stime cutime cstime
    return total / TICK


def cmdline(pid):
    try:
        return Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
    except OSError:
        return ''


def desktop_command(entry_id, args):
    """A desktop entry's Exec line with its field codes resolved to `args`."""
    dirs = [Path.home() / '.local/share'] + [Path(d) for d in os.environ.get(
        'XDG_DATA_DIRS', '/usr/local/share:/usr/share').split(':') if d]
    for d in dirs:
        path = d / 'applications' / entry_id
        if path.is_file():
            break
    else:
        return None
    exec_line = None
    in_entry = False
    for line in path.read_text().splitlines():
        if line.startswith('['):
            in_entry = line.strip() == '[Desktop Entry]'
        elif in_entry and line.startswith('Exec='):
            exec_line = line[5:]
            break
    if exec_line is None:
        return None
    out = []
    for word in shlex.split(exec_line):
        if word in ('%u', '%U', '%f', '%F'):
            out += args
            args = []
        elif not re.fullmatch(r'%[a-zA-Z]', word):
            out.append(word.replace('%%', '%'))
    return out + args


class Tail(threading.Thread):
    """Lines appended to a file from now on, parsed as they arrive."""

    def __init__(self, path, sink):
        super().__init__(daemon=True)
        self.path, self.sink, self.stopped = Path(path), sink, threading.Event()

    def run(self):
        with open(self.path, 'rb') as f:
            f.seek(0, os.SEEK_END)
            pending = b''
            while not self.stopped.is_set():
                chunk = f.read(1 << 16)
                if not chunk:
                    time.sleep(0.05)
                    continue
                pending += chunk
                *lines, pending = pending.split(b'\n')
                for line in lines:
                    self.sink(line.decode(errors='replace'), now())

    def stop(self):
        self.stopped.set()


def broker_log():
    """The running GPU broker's stderr, when it is a file (it inherits the display's)."""
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit() and 'caboose-gpu-broker' in cmdline(entry.name):
            try:
                target = os.readlink(entry / 'fd/2')
            except OSError:
                continue
            if target.startswith('/') and Path(target).is_file():
                return target
    return None


class Run:
    """One launch of one app, measured."""

    def __init__(self, app, control, env, out, broker_log_path, reference=False):
        self.app, self.control, self.env, self.out = app, control, env, out
        self.reference = reference
        self.broker_log_path = broker_log_path
        self.records, self.inputs, self.cpu = [], [], []
        self.windows, self.window_ids = {}, set()
        self.lock = threading.Lock()
        self.proc = None
        self.log = None
        self.no_timeline = False

    def keep(self, line, received):
        record = framelab.parse_line(line, received)
        if record:
            with self.lock:
                self.records.append(record)

    def find_window(self, pids):
        """The app's window: a toplevel that appeared since the launch, of a process the
        launch started, or, for an X11 window that names no process, of nobody (apps run
        one at a time), or of a process or title the app's `window` pattern matches (a
        launcher that hands off to another process)."""
        pattern = re.compile(self.app.get('window', '$^'))
        for w in self.control.ask('windows')[0]['windows']:
            if w['id'] in self.before or w.get('kind') != 'toplevel' or w['rect'][2] < 64 or w['rect'][3] < 64:
                continue
            if w['pid'] in pids or not w['pid'] or pattern.search(w['title'] or '') or pattern.search(cmdline(w['pid'])):
                return w
        return None

    def stable_picture(self, window, seconds=20):
        """The window's picture once it stops changing (two in a row, a second apart, the
        same), or the last one after `seconds`: a page still loading is not the scene."""
        previous, deadline = None, time.monotonic() + seconds
        while True:
            self.control.ask('settle')
            time.sleep(0.25)
            png = self.control.ask(f'screenshot {window}')[1]
            if png == previous:
                return png, True
            if time.monotonic() >= deadline:
                return png, False
            previous = png
            time.sleep(0.75)

    def poll_frames(self, since):
        """New entries of the compositor's timeline; a compositor without `frames` gives
        none, and the GPU broker's records stand alone."""
        try:
            reply = self.control.ask(f'frames {since}')[0]
        except RuntimeError as e:
            if 'unknown request' not in str(e):
                raise
            self.no_timeline = True
            return since
        for w in reply['windows']:
            if w['id'] in self.window_ids:
                entry = self.windows.setdefault(str(w['id']), {'commits': [], 'sent': []})
                # Compositor microseconds to nanoseconds, the clock every record uses.
                entry['commits'] += [t * 1000 for t in w['commits']]
                entry['sent'] += [[a * 1000, p * 1000, b, r] for a, p, b, r in w['sent']]
        return reply['now_us']

    def inject(self, step, window):
        x = window['rect'][0] + window['rect'][2] // 2
        y = window['rect'][1] + window['rect'][3] // 2
        if 'scroll' in step:
            request = f"scroll {x} {y} {step['scroll'][0]} {step['scroll'][1]}"
        elif 'key' in step:
            request = f"key {step['key']}"
        elif 'type' in step:
            request = f"type {step['type']}"
        elif 'click' in step:
            request = f'click {x} {y}'
        else:
            raise ValueError(f'unknown input step {step}')
        before = now()
        self.control.ask(request)
        self.inputs.append({'t': before, 'done': now(), 'request': request.split()[0]})

    def start(self, tmp, materials, offline):
        app = self.app

        def fill(word):
            return word.format(tmp=tmp, **materials)

        for rel, content in app.get('files', {}).items():
            path = Path(tmp) / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        args = [fill(a) for a in app.get('args', [])]
        url = app.get('offline_url') if offline and app.get('offline_url') else app.get('url')
        if url:
            args.append(fill(url))
        if 'desktop' in app:
            command = desktop_command(app['desktop'], args)
            if command is None:
                raise FileNotFoundError(f"no desktop entry {app['desktop']}")
        else:
            command = [fill(a) for a in app['command']] + args
        if not shutil.which(command[0], path=self.env.get('PATH', os.environ.get('PATH'))):
            raise FileNotFoundError(f'{command[0]} is not installed')
        env = {**os.environ, **self.env, 'CABOOSE_READ_PROFILE': '1'}
        if self.reference:
            # The CPU reference: the same launch without the phone's Vulkan driver.
            env = framelab.reference_environment(env)
        name = app['id'] + ('.reference' if self.reference else '')
        self.log = open(self.out / f'{name}.log', 'w')
        self.proc = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, start_new_session=True, cwd=tmp)
        threading.Thread(target=self.read_output, daemon=True).start()
        emit('launch', app=app['id'], reference=self.reference, pid=self.proc.pid, command=command)

    def read_output(self):
        for raw in self.proc.stdout:
            line = raw.decode(errors='replace')
            self.log.write(line)
            self.keep(line, now())

    def stop(self):
        if self.proc is None:
            return
        pids = tree(self.proc.pid)
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(Path(f'/proc/{p}').exists() for p in tree(self.proc.pid)[1:]):
            time.sleep(0.1)
        for pid in tree(self.proc.pid) + pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        if self.log:
            self.log.close()

    def measure(self, tmp, materials, offline, shot_name):
        """Launch, wait for the window, settle, take the picture, drive the input and
        record; returns the run record."""
        app = self.app
        record = {'app': app['id'], 'reference': self.reference, 'ok': False}
        tail = None
        try:
            record['start_ns'] = now()
            self.before = {w['id'] for w in self.control.ask('windows')[0]['windows']}
            self.start(tmp, materials, offline)
            if self.broker_log_path and not self.reference:
                tail = Tail(self.broker_log_path, self.keep)
                tail.start()
            deadline = time.monotonic() + app.get('ready_s', 30)
            window = None
            while time.monotonic() < deadline:
                if self.proc.poll() is not None and not tree(self.proc.pid)[1:]:
                    # Launchers that hand off and exit leave the window to a process
                    # outside the tree; the title still finds it.
                    pass
                window = self.find_window(set(tree(self.proc.pid)))
                if window:
                    break
                time.sleep(0.25)
            if not window:
                seen = [(w['id'], w['kind'], w['title'], w['pid'], w['rect'])
                        for w in self.control.ask('windows')[0]['windows']]
                raise TimeoutError(f"no window within {app.get('ready_s', 30)} s; windows: {seen}")
            self.window_ids.add(window['id'])
            record['window'] = {k: window[k] for k in ('id', 'title', 'app_id', 'pid', 'rect')}
            emit('window', app=app['id'], reference=self.reference, window=record['window'])
            since = self.poll_frames(0) if not self.no_timeline else 0
            end_warmup = time.monotonic() + app.get('warmup_s', 3)
            while time.monotonic() < end_warmup:
                self.control.ask('settle')
                time.sleep(0.25)
            # Windows often open small and grow; input goes to where the window is now.
            window = next((w for w in self.control.ask('windows')[0]['windows'] if w['id'] == window['id']), None)
            if window is None:
                raise RuntimeError('the window closed')
            record['window']['rect'] = window['rect']
            if app.get('correctness'):
                png, stable = self.stable_picture(window['id'])
                record['picture_ns'] = now()
                (self.out / shot_name).write_bytes(png)
                record['picture'] = shot_name
                record['picture_stable'] = stable
            if self.reference:
                record['ok'] = True
                return record
            self.cpu.append((now(), cpu_seconds(tree(self.proc.pid))))
            record['measure_ns'] = now()
            emit('measure', app=app['id'])
            steps = [s for s in app.get('input', []) for _ in range(s.get('count', 1))]
            measure_end = time.monotonic() + app.get('measure_s', 15)
            next_poll, next_sample = 0, time.monotonic() + 0.5
            while time.monotonic() < measure_end:
                t = time.monotonic()
                if t >= next_sample:
                    self.cpu.append((now(), cpu_seconds(tree(self.proc.pid))))
                    next_sample = t + 0.5
                if t >= next_poll:
                    since = self.poll_frames(since)
                    next_poll = t + 1
                if steps:
                    step = steps.pop(0)
                    self.inject(step, window)
                    time.sleep(step.get('every_ms', 100) / 1000)
                else:
                    time.sleep(0.05)
            self.cpu.append((now(), cpu_seconds(tree(self.proc.pid))))
            self.poll_frames(since)
            record['measure_end_ns'] = now()
            record['ok'] = self.proc.poll() is None or bool(tree(self.proc.pid)[1:])
            if not record['ok']:
                record['error'] = f'exited with {self.proc.returncode}'
        except Exception as e:  # noqa: BLE001 - every failure becomes the app's result
            record['error'] = f'{type(e).__name__}: {e}'
        finally:
            record['end_ns'] = now()
            if tail:
                tail.stop()
            self.stop()
        with self.lock:
            record.update(records=list(self.records), inputs=self.inputs, cpu=self.cpu, windows=self.windows,
                          compositor_timeline=not self.no_timeline)
        return record


def materials(root):
    """The local inputs the matrix refers to, made once per run."""
    root = Path(root)
    words = ('locomotive caboose freight signal junction platform timetable coupling brake '
             'gradient viaduct switchyard roundhouse tender boiler piston').split()
    paragraphs = []
    for i in range(400):
        text = ' '.join(words[(i * 7 + j * 3) % len(words)] for j in range(90))
        paragraphs.append(f'<h2>Section {i + 1}</h2><p>{text}.</p>' if i % 8 == 0 else f'<p>{text}.</p>')
    page = root / 'long-article.html'
    page.write_text('<!doctype html><meta charset="utf-8"><title>Frame lab article</title>'
                    '<body style="font:18px/1.5 serif;max-width:46em;margin:2em auto">'
                    + ''.join(paragraphs) + '</body>')
    listing = root / 'listing.txt'
    listing.write_text(''.join(f'{i:6d}  ' + ' '.join(words[(i + j) % len(words)] for j in range(10)) + '\n'
                               for i in range(5000)))
    qml = root / 'list.qml'
    qml.write_text('import QtQuick\nimport QtQuick.Window\n'
                   'Window { visible: true; width: 640; height: 800; title: "Frame lab list"\n'
                   '  ListView { anchors.fill: parent; model: 2000\n'
                   '    delegate: Rectangle { width: ListView.view.width; height: 48\n'
                   '      color: index % 2 ? "#e8eef7" : "#ffffff"\n'
                   '      Text { anchors.verticalCenter: parent.verticalCenter; x: 16; font.pixelSize: 20;'
                   ' text: "Row " + index } } } }\n')
    video = root / 'clip.mp4'
    if shutil.which('ffmpeg'):
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30',
                        '-t', '10', '-pix_fmt', 'yuv420p', str(video)], check=False, timeout=120)
    return {'page': str(page), 'listing': str(listing), 'qml': str(qml), 'video': str(video)}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--matrix', default=str(HERE / 'matrix.json'))
    parser.add_argument('--apps', help='comma-separated app ids (default: all)')
    parser.add_argument('--out', default=str(Path(tempfile.gettempdir()) / 'caboose-framelab'))
    parser.add_argument('--env', default='/run/caboose/display.env')
    parser.add_argument('--broker-log', help='the GPU broker log (default: found from the running broker)')
    parser.add_argument('--offline', action='store_true', help='local pages instead of the network')
    parser.add_argument('--no-reference', action='store_true', help='skip the CPU reference pictures')
    args = parser.parse_args()
    # The driver stops a run with SIGTERM (or the session ends): unwind, so every app
    # launched is stopped and the present trace switched off.
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, lambda number, _: sys.exit(128 + number))

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    env = read_env(args.env)
    control = Control(env['CABOOSE_DISPLAY_CONTROL'])
    apps = json.loads(Path(args.matrix).read_text())['apps']
    if args.apps:
        wanted = args.apps.split(',')
        unknown = set(wanted) - {a['id'] for a in apps}
        if unknown:
            sys.exit(f'unknown apps: {", ".join(sorted(unknown))}')
        apps = [a for a in apps if a['id'] in wanted]
    log_path = args.broker_log or broker_log()
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR') or env.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'))
    flag = runtime / 'caboose-gpu-present-trace'
    emit('start', apps=[a['id'] for a in apps], broker_log=log_path, out=str(out))

    work = Path(tempfile.mkdtemp(prefix='caboose-framelab-'))
    cards = []
    try:
        made = materials(work)
        flag.touch()
        for app in apps:
            if app.get('needs_network') and args.offline:
                card = {'app': app['id'], 'name': app.get('name'), 'path': 'none', 'ok': False,
                        'skipped': 'needs the network', 'stalls': {'count': 0, 'by_cause': {}}}
                cards.append(card)
                (out / f"{app['id']}.json").write_text(json.dumps(card, indent=2))
                emit('skipped', app=app['id'], reason=card['skipped'])
                continue
            tmp = Path(tempfile.mkdtemp(prefix=f"{app['id']}-", dir=work))
            run = Run(app, control, env, out, log_path).measure(tmp, made, args.offline, f"{app['id']}.png")
            correctness = None
            if app.get('correctness') and run.get('picture'):
                if args.no_reference:
                    correctness = {'skipped': 'no reference run'}
                else:
                    ref_tmp = Path(tempfile.mkdtemp(prefix=f"{app['id']}-ref-", dir=work))
                    ref = Run(app, control, env, out, None, reference=True).measure(
                        ref_tmp, made, args.offline, f"{app['id']}.reference.png")
                    if ref.get('picture'):
                        comparison = framelab.compare((out / ref['picture']).read_bytes(),
                                                      (out / run['picture']).read_bytes())
                        correctness = {**comparison, 'pass': framelab.verdict(comparison),
                                       'reference': ref['picture'], 'candidate': run['picture'],
                                       'candidate_source': 'compositor'}
                    else:
                        correctness = {'skipped': f"no reference picture: {ref.get('error')}"}
            run['correctness'] = correctness
            (out / f"{app['id']}.run.json").write_text(json.dumps(run))
            card = framelab.scorecard(app, run)
            cards.append(card)
            (out / f"{app['id']}.json").write_text(json.dumps(card, indent=2))
            emit('scorecard', app=app['id'], ok=card['ok'], path=card['path'], fps=card['pacing']['per_s'],
                 stalls=card['stalls']['count'], error=card.get('error'))
    finally:
        flag.unlink(missing_ok=True)
        shutil.rmtree(work, ignore_errors=True)
    table = framelab.summary_table([c for c in cards if 'pacing' in c])
    skipped = [c for c in cards if 'pacing' not in c]
    if skipped:
        table += ''.join(f"\n{c['app']}: skipped, {c['skipped']}" for c in skipped) + '\n'
    (out / 'summary.md').write_text(table)
    emit('done', ok=all(c.get('ok') or c.get('skipped') for c in cards), summary=str(out / 'summary.md'))
    sys.stderr.write(table)


if __name__ == '__main__':
    main()
