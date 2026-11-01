#!/usr/bin/env python3
"""The GPU compositor's window pictures and their cost, checked against real applications.

    gpu-windows-check.py --env DISPLAY.ENV --control CONTROL.SOCK --pid PID --out DIR

Run by gpu-windows-check.sh, as the seat's owner, against a running caboose-display with a
connected client. It starts foot (a Wayland terminal drawing into shared memory), xterm
(X11 core drawing through Xwayland), a GTK 3 window (scripts/gtk-reference.py) and Wine's
About dialog (a GDI dialog, X11), then:

- compares each window's picture, taken through the control socket's `screenshot` (drawn
  by the compositor's own renderer), with what the application drew: the X server's copy of
  the X11 windows (`import -window`) and GTK's own offscreen drawing of the same widgets,
  pixel for pixel; foot's picture must change where, and only where, a typed glyph appears;
- types glyphs into the terminals and reports, per glyph, the renders, the redrawn pixels,
  the bytes uploaded from shared memory and the presents (`stats`), and the same for an idle
  stretch, with the compositor's CPU time.

Prints one JSON report and exits non-zero when a picture is wrong or an idle stretch did
any work.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
GLYPHS = 20
IDLE_S = 5


def ctl(path, request, png=None):
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(path)
        s.sendall(request.encode() + b'\n')
        data = b''
        while b'\n' not in data:
            chunk = s.recv(65536)
            if not chunk:
                raise RuntimeError(f'control socket closed answering {request!r}')
            data += chunk
        line, rest = data.split(b'\n', 1)
        answer = json.loads(line)
        if not answer.get('ok'):
            raise RuntimeError(f'{request}: {answer}')
        if png is not None and 'png' in answer:
            while len(rest) < answer['png']:
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                rest += chunk
            Path(png).write_bytes(rest[:answer['png']])
        return answer


def cpu_ms(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) * 1000 / os.sysconf('SC_CLK_TCK')


def differing_pixels(a, b, diff=None):
    """ImageMagick's count of pixels that differ between two pictures (sizes must match)."""
    result = subprocess.run(['compare', '-metric', 'AE', str(a), str(b), str(diff or 'null:')],
                            capture_output=True, text=True)
    text = (result.stderr or result.stdout).strip().split()[0]
    try:
        return int(float(text))
    except ValueError:
        raise RuntimeError(f'compare {a} {b}: {result.stderr.strip()}')


def size_of(png):
    out = subprocess.run(['identify', '-format', '%w %h', str(png)], capture_output=True, text=True, check=True)
    w, h = out.stdout.split()
    return int(w), int(h)


class Check:
    def __init__(self, args):
        self.args = args
        self.out = Path(args.out)
        self.env = dict(os.environ)
        for line in Path(args.env).read_text().splitlines():
            key, _, value = line.partition('=')
            if key:
                self.env[key] = value.strip("'")
        self.procs = []
        self.report = {'windows': {}, 'cost': {}, 'failures': []}

    def fail(self, what):
        self.report['failures'].append(what)

    def start(self, name, command):
        log = open(self.out / f'{name}.log', 'w')
        self.procs.append(subprocess.Popen(command, env=self.env, stdout=log, stderr=subprocess.STDOUT))

    def window(self, match, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for w in ctl(self.args.control, 'windows')['windows']:
                if match(w):
                    return w
            time.sleep(0.5)
        return None

    def shot(self, window, name):
        path = self.out / f'{name}.png'
        ctl(self.args.control, f'screenshot {window["id"]}', path)
        return path

    def stats(self):
        return ctl(self.args.control, 'stats')

    def exact(self, name, window, reference):
        """The window's picture against what the application drew."""
        picture = self.shot(window, name)
        if size_of(picture) != size_of(reference):
            self.fail(f'{name}: picture {size_of(picture)} but the application drew {size_of(reference)}')
            return
        wrong = differing_pixels(picture, reference, self.out / f'{name}-diff.png')
        self.report['windows'][name] = {'size': size_of(picture), 'differing_px': wrong}
        if wrong:
            self.fail(f'{name}: {wrong} pixels differ from what the application drew')

    def x11_reference(self, window, name):
        path = self.out / f'{name}-x11.png'
        subprocess.run(['import', '-window', str(window['x11']), str(path)], env=self.env, check=True,
                       capture_output=True)
        return path

    def typing_cost(self, name, window):
        ctl(self.args.control, f'focus {window["id"]}')
        time.sleep(1)
        before, cpu0 = self.stats(), cpu_ms(self.args.pid)
        for i in range(GLYPHS):
            ctl(self.args.control, f'type {chr(ord("a") + i % 26)}')
            time.sleep(0.15)
        time.sleep(1)
        after, cpu1 = self.stats(), cpu_ms(self.args.pid)
        per = {k: round((after[k] - before[k]) / GLYPHS, 1)
               for k in ('renders', 'damaged_px', 'uploaded_bytes', 'presents', 'direct_presents')}
        per['compositor_cpu_ms'] = round((cpu1 - cpu0) / GLYPHS, 2)
        self.report['cost'][f'{name}_per_glyph'] = per

    def idle_cost(self):
        since = ctl(self.args.control, 'frames 0')['now_us']
        before, cpu0 = self.stats(), cpu_ms(self.args.pid)
        time.sleep(IDLE_S)
        after, cpu1 = self.stats(), cpu_ms(self.args.pid)
        per = {k: round((after[k] - before[k]) / IDLE_S, 1) for k in ('renders', 'uploaded_bytes', 'presents')}
        per['compositor_cpu_pct'] = round((cpu1 - cpu0) / IDLE_S / 10, 2)
        # Which windows committed anything meanwhile (an application that animates).
        per['committing_windows'] = {w['id']: len(w['commits'])
                                     for w in ctl(self.args.control, f'frames {since}')['windows'] if w['commits']}
        self.report['cost']['idle_per_second'] = per
        if per['renders'] or per['uploaded_bytes'] or per['presents']:
            self.fail(f'idle: work was done: {per}')

    def run(self):
        stats = self.stats()
        self.report['renderer'] = stats['renderer']
        self.report['phone_images'] = stats['phone_images']
        if 'zink' not in stats['renderer']:
            self.fail(f'the renderer is not Zink: {stats["renderer"]}')

        self.start('foot', ['foot', '--app-id', 'gpu-check-foot', '-e', 'cat'])
        self.start('xterm', ['xterm', '-class', 'GpuCheckXterm', '-geometry', '60x10', '-fa', 'DejaVu Sans Mono',
                             '-fs', '11', '-e', 'cat'])
        gtk_reference = self.out / 'gtk-reference.png'
        self.start('gtk', [sys.executable, str(HERE / 'gtk-reference.py'), 'gpu-check-gtk', str(gtk_reference)])
        # Wine's first start updates its prefix, behind a progress window of its own.
        subprocess.run(['wineboot', '-i'], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=300)
        self.start('wine', ['wine', 'winver'])

        foot = self.window(lambda w: w['app_id'] == 'gpu-check-foot')
        xterm = self.window(lambda w: w['app_id'] == 'GpuCheckXterm')
        gtk = self.window(lambda w: w['title'] == 'gpu-check-gtk')
        wine = self.window(lambda w: w['title'].startswith('About Wine') and w['x11'] is not None, 180)
        for name, w in (('foot', foot), ('xterm', xterm), ('gtk', gtk), ('wine', wine)):
            if w is None:
                self.fail(f'{name}: no window')
        time.sleep(2)

        if gtk:
            self.exact('gtk', gtk, gtk_reference)
        if xterm:
            self.exact('xterm', xterm, self.x11_reference(xterm, 'xterm'))
        if wine:
            self.exact('wine', wine, self.x11_reference(wine, 'wine'))
        if foot:
            ctl(self.args.control, f'focus {foot["id"]}')
            time.sleep(1)
            blank = self.shot(foot, 'foot-before')
            ctl(self.args.control, 'type X')
            time.sleep(1)
            typed = self.shot(foot, 'foot-after')
            changed = differing_pixels(blank, typed, self.out / 'foot-diff.png')
            self.report['windows']['foot'] = {'size': size_of(typed), 'glyph_px': changed}
            # One glyph (and the cursor moving one cell): a few hundred pixels, not the window.
            if not 10 <= changed <= 2000:
                self.fail(f'foot: typing one glyph changed {changed} pixels')

        self.idle_cost()
        if foot:
            self.typing_cost('foot', foot)
        if xterm:
            self.typing_cost('xterm', xterm)
        if xterm:
            # After all that typing the picture must still be exactly what X drew.
            self.exact('xterm-after-typing', xterm, self.x11_reference(xterm, 'xterm-after-typing'))
        final = self.stats()
        self.report['totals'] = {k: final[k] for k in ('renders', 'unchanged_renders', 'uploaded_bytes', 'presents')}
        return not self.report['failures']

    def stop(self):
        for p in self.procs:
            p.terminate()
        for p in self.procs:
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.kill()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--env', required=True)
    parser.add_argument('--control', required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--out', required=True)
    check = Check(parser.parse_args())
    try:
        ok = check.run()
    finally:
        check.stop()
    print(json.dumps(check.report))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
