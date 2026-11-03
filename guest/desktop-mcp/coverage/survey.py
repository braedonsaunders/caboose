#!/usr/bin/env python3
"""Accessibility coverage of every application on the agent seat, grouped by toolkit.

usage: survey.py --output RESULTS.jsonl [--only ID ...] [--skip ID ...] [--wait SECONDS]
       survey.py --table RESULTS.jsonl

Run inside the computer as the agent user with the agent seat's environment and its agent
profile (`python3 /opt/caboose/agent-profile.py exec ...`), from desktop-mcp's directory. The
seat must be empty: each application is started alone, as desktop MCP's launch starts it,
and ended afterwards. It lists every desktop entry that opens a window (the image's, and the
system and user Flatpak exports), starts it, waits for its window and scores it:

  tree     the focused window's accessibility tree is found
  controls how many controls a read lists
  named    the share of them with a name
  text     whether the window's readable text is non-empty
  acts     the share of interactive controls that offer an action
  focus    whether focusing a field or button through its id takes
  ms       the median time of three reads of the window

and records its toolkit and runtime from the libraries the window's process has mapped (or,
for a process that hides them, the toolkit its accessibility registration names). A window
is read again until two reads agree, for up to 8 s, so late contents count. The table groups
the applications by toolkit."""
import argparse
import configparser
import glob
import json
import os
import pathlib
import shlex
import signal
import statistics
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
from seat import Seat  # noqa: E402

INTERACTIVE = {'push button', 'button', 'toggle button', 'check box', 'radio button', 'menu item', 'menu', 'link', 'page tab',
               'combo box', 'text', 'entry', 'spin button', 'slider', 'list item', 'tree item', 'check menu item', 'radio menu item'}
LIBRARIES = [  # first match wins: the toolkit a window is drawn with
    ('LibreOffice VCL', ('libvcllo.so', 'libmergedlo.so')), ('Gecko', ('libxul.so',)),
    ('Chromium/Electron', ('libffmpeg.so', 'libEGL.so', 'resources.pak', 'v8_context_snapshot.bin', 'icudtl.dat')),
    ('Java', ('libjvm.so',)), ('Wine', ('wine', 'ntdll.so')), ('Qt 6', ('libQt6Gui.so',)), ('Qt 5', ('libQt5Gui.so',)),
    ('GTK 4', ('libgtk-4.so',)), ('GTK 3', ('libgtk-3.so',)), ('SDL', ('libSDL2', 'libSDL3')), ('Godot', ('godot',)),
]


def toolkit(pid):
    try:
        maps = pathlib.Path(f'/proc/{pid}/maps').read_text()
        exe = os.readlink(f'/proc/{pid}/exe')
    except OSError:
        return 'unknown', False
    flatpak = pathlib.Path(f'/proc/{pid}/root/.flatpak-info').exists()
    names = {line.rsplit('/', 1)[-1] for line in maps.splitlines() if '/' in line} | {exe.rsplit('/', 1)[-1]}
    for label, markers in LIBRARIES:
        if label == 'Chromium/Electron':
            if any(n.endswith('.pak') or n in ('icudtl.dat', 'v8_context_snapshot.bin') for n in names):
                return label, flatpak
            continue
        if any(any(n.startswith(m) or m in n for m in markers) for n in names):
            return label, flatpak
    return 'other', flatpak


def entries(only, skip):
    homes = [os.environ.get('XDG_DATA_HOME', os.path.expanduser('~/.local/share'))]
    dirs = ['/usr/share/applications', '/var/lib/flatpak/exports/share/applications'] + [f'{h}/flatpak/exports/share/applications' for h in homes]
    found = {}
    for path in sorted(p for d in dirs for p in glob.glob(f'{d}/*.desktop')):
        ident = pathlib.Path(path).stem
        if ident in found or (only and ident not in only) or ident in skip:
            continue
        config = configparser.RawConfigParser(strict=False, interpolation=None)
        try:
            config.read(path, encoding='utf-8')
            entry = config['Desktop Entry']
        except Exception:
            continue
        if entry.get('Type') != 'Application' or entry.get('NoDisplay', '').lower() == 'true' or entry.get('Hidden', '').lower() == 'true' \
                or entry.get('Terminal', '').lower() == 'true' or not entry.get('Exec'):
            continue
        words = [w for w in shlex.split(entry['Exec']) if not (len(w) == 2 and w.startswith('%'))]
        found[ident] = {'id': ident, 'name': entry.get('Name', ident), 'exec': words}
    return list(found.values())


class Helper:
    """a11y.py's long-lived helper, as desktop MCP keeps it."""

    def __init__(self):
        self.child = subprocess.Popen([sys.executable, str(HERE / 'a11y.py'), 'serve', '--display=' + os.environ.get('DISPLAY', ':101')],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def __call__(self, **request):
        self.child.stdin.write(json.dumps(request) + '\n'); self.child.stdin.flush()
        return json.loads(self.child.stdout.readline() or '{}')

    def close(self):
        self.child.kill(); self.child.wait()


def announce():
    subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus', '--method',
                    'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'ScreenReaderEnabled', '<true>'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def agent_orphans(before):
    """Processes started since `before` (a pid set) that outlived their parent and belong to
    the agent profile: helpers an application left behind (a sandbox's image loaders)."""
    found = []
    for name in os.listdir('/proc'):
        if not name.isdigit() or int(name) in before:
            continue
        try:
            status = pathlib.Path(f'/proc/{name}/status').read_text()
            if '\nPPid:\t1\n' not in status:
                continue
            marks = pathlib.Path(f'/proc/{name}/cmdline').read_bytes()
            try:
                marks += pathlib.Path(f'/proc/{name}/environ').read_bytes()
            except OSError:
                pass
            if b'/caboose/agent-seat/' in marks or b'agent-bus' in marks:
                found.append(int(name))
        except OSError:
            continue
    return found


def end(seat, process, before):
    for w in seat.windows()['windows']:
        try: os.kill(w['pid'], signal.SIGTERM)
        except (OSError, KeyError, TypeError): pass
    try: os.killpg(process.pid, signal.SIGTERM)
    except OSError: pass
    for _ in range(50):
        if not seat.windows()['windows']: break
        time.sleep(0.1)
    for w in seat.windows()['windows']:
        try: os.kill(w['pid'], signal.SIGKILL)
        except (OSError, KeyError, TypeError): pass
    try: os.killpg(process.pid, signal.SIGKILL)
    except OSError: pass
    for pid in agent_orphans(before):
        try: os.kill(pid, signal.SIGKILL)
        except OSError: pass


def measure(app, seat, wait):
    env = dict(os.environ, ACCESSIBILITY_ENABLED='1', GNOME_ACCESSIBILITY='1', QT_LINUX_ACCESSIBILITY_ALWAYS_ON='1', XDG_SESSION_TYPE='wayland')
    env.pop('NO_AT_BRIDGE', None)
    announce()
    before = {int(n) for n in os.listdir('/proc') if n.isdigit()}
    process = subprocess.Popen([sys.executable, str(HERE / 'launcher.py'), shlex.join(app['exec'])], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    record = {'id': app['id'], 'name': app['name']}
    try:
        window, deadline = None, time.monotonic() + wait
        while time.monotonic() < deadline and window is None:
            time.sleep(0.25)
            listing = seat.windows()
            window = next((w for w in listing['windows'] if w['id'] == listing.get('focused') and w.get('title')), None)
        if window is None:
            return {**record, 'window': False}
        time.sleep(1.5)  # the window finishes building its first contents
        listing = seat.windows()
        window = next((w for w in listing['windows'] if w['id'] == listing.get('focused')), window)
        kit, flatpak = toolkit(window['pid'])
        record.update(window=True, toolkit=kit, flatpak=flatpak, wayland=not window.get('x11'), kind=window['kind'])
        helper = Helper()
        try:
            count, settle = len(helper(op='elements').get('elements') or []), time.monotonic() + 8
            while time.monotonic() < settle:
                time.sleep(0.5)
                now = len(helper(op='elements').get('elements') or [])
                if now and now == count:
                    break
                count = now
            reads = []
            for _ in range(3):
                started = time.monotonic()
                state = helper(op='elements')
                reads.append((time.monotonic() - started) * 1000)
            elements = state.get('elements') or []
            if kit in ('unknown', 'other') and state.get('toolkit'):
                kit = record['toolkit'] = 'Qt' if state['toolkit'].startswith('Qt') else state['toolkit'].split()[0]
            text = (helper(op='text').get('text') or '').strip()
            interactive = [e for e in elements if e['role'] in INTERACTIVE]
            target = next((e for e in elements if e['role'] in ('text', 'entry') and 'focus' in e.get('actions', [])), None) \
                or next((e for e in elements if 'focus' in e.get('actions', [])), None)
            focus = None
            if target:
                focus = bool(helper(op='act', element=target['id'], action='focus').get('ok'))
                if focus:
                    after = helper(op='elements').get('elements') or []
                    focus = any(e['id'] == target['id'] and 'focused' in e['states'] for e in after)
            record.update(tree=bool(elements) and not state.get('note'), note=state.get('note'), controls=len(elements),
                          named=round(sum(1 for e in elements if e['name']) / len(elements), 2) if elements else None,
                          text=bool(text), acts=round(sum(1 for e in interactive if e.get('actions')) / len(interactive), 2) if interactive else None,
                          focus=focus, ms=round(statistics.median(reads)))
        finally:
            helper.close()
        return record
    finally:
        end(seat, process, before)


def table(path):
    rows = [json.loads(line) for line in open(path)]
    groups = {}
    for r in rows:
        groups.setdefault((r.get('toolkit') or 'no window') + (' (Flatpak)' if r.get('flatpak') else ''), []).append(r)
    mean = lambda xs: f"{100 * statistics.mean(xs):.0f}%" if xs else '—'
    print('| toolkit | apps | window | tree | controls (median) | named | text | acts | focus | ms (median) |')
    print('|---|---|---|---|---|---|---|---|---|---|')
    for name, rs in sorted(groups.items(), key=lambda g: -len(g[1])):
        win = [r for r in rs if r.get('window')]
        tree = [r for r in win if r.get('tree')]
        print(f"| {name} | {len(rs)} | {len(win)} | {len(tree)} | {statistics.median([r['controls'] for r in win]) if win else '—'} "
              f"| {mean([r['named'] for r in tree if r.get('named') is not None])} "
              f"| {mean([1 if r.get('text') else 0 for r in win])} | {mean([r['acts'] for r in tree if r.get('acts') is not None])} "
              f"| {mean([1 if r.get('focus') else 0 for r in tree if r.get('focus') is not None])} | {statistics.median([r['ms'] for r in win]) if win else '—'} |")
    print()
    for r in rows:
        print(f"- {r['id']}: {r.get('toolkit', 'no window')}{' flatpak' if r.get('flatpak') else ''}, "
              + (f"{r['controls']} controls, tree {r['tree']}, named {r['named']}, text {r['text']}, acts {r['acts']}, focus {r['focus']}, {r['ms']} ms"
                 + (f" ({r['note']})" if r.get('note') else '') if r.get('window') else 'no window'))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--output')
    p.add_argument('--table')
    p.add_argument('--only', action='append', default=[])
    p.add_argument('--skip', action='append', default=[])
    p.add_argument('--wait', type=float, default=25)
    a = p.parse_args()
    if a.table:
        table(a.table); sys.exit(0)
    seat = Seat()
    if seat.windows()['windows']:
        sys.exit('the agent seat has windows open; run on an empty seat')
    for app in entries(set(a.only), set(a.skip)):
        try:
            record = measure(app, seat, a.wait)
        except Exception as error:
            record = {'id': app['id'], 'name': app['name'], 'error': str(error)[:300]}
        print(json.dumps(record), flush=True)
        with open(a.output, 'a') as f:
            f.write(json.dumps(record) + '\n')
