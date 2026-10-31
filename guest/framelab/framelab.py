"""Frame lab's pure logic: parsing the seat's diagnostics, scorecards, picture diffs and
the summary table. No I/O beyond reading PNG bytes handed to it; see README.md.

Times are integers in nanoseconds of the computer's CLOCK_MONOTONIC unless a name says
otherwise. Phone lines carry the driver's receive time and are moved onto the computer's
clock with an offset estimated from the guest's own event stream (`clock_offset`).
"""

import bisect
import math
import re
import struct
import zlib

STALL_MS = 100
# An input left unanswered this long ends its wait (it may have had nothing to change).
OWED_MAX_MS = 2000

_FIELDS = re.compile(r'(\w+)=(\S+)')


def fields(line):
    """`key=value` pairs of a diagnostic line, numbers as ints where they parse."""
    out = {}
    for key, value in _FIELDS.findall(line):
        try:
            out[key] = int(value)
        except ValueError:
            out[key] = value
    return out


def parse_line(line, received_ns=None):
    """One diagnostic line as a record, or None for anything else.

    Lines may carry a prefix (a log timestamp, a process tag); the marker is found
    anywhere in the line. `received_ns` is when the reader saw it, the only time for
    lines without their own clock.
    """
    if 'CABOOSE_GPU_PRESENT ' in line:
        f = fields(line.split('CABOOSE_GPU_PRESENT ', 1)[1])
        if 'monotonic_ns' in f and 'event' in f:
            return {'kind': 'gpu_present', 'event': f['event'], 't': f['monotonic_ns']}
    elif 'CABOOSE_GPU_STREAM ' in line:
        f = fields(line.split('CABOOSE_GPU_STREAM ', 1)[1])
        if 'monotonic_ns' in f:
            return {'kind': 'gpu_stream', 't': f['monotonic_ns'], 'elapsed_ms': f.get('elapsed_ms', 0),
                    'to_phone_bytes': f.get('to_phone_bytes', 0), 'from_phone_bytes': f.get('from_phone_bytes', 0)}
    elif 'CABOOSE_GPU_PRESENT_RATE ' in line:
        f = fields(line.split('CABOOSE_GPU_PRESENT_RATE ', 1)[1])
        return {'kind': 'present_rate', 't': received_ns, **{k: f.get(k, 0) for k in (
            'elapsed_ms', 'presented', 'ordered', 'results', 'released', 'gap_max_ms', 'result_gap_max_ms')}}
    elif 'CABOOSE_READ_PROFILE' in line:
        # ` opN=Tms/C` (own reply) and ` drainN=Tms/C` (earlier deferred replies), the
        # eight largest blocking totals of the last two seconds.
        entries = re.findall(r'(op|drain)(\d+)=(\d+)ms/(\d+)', line)
        return {'kind': 'read_profile', 't': received_ns,
                'entries': [{'what': w, 'opcode': int(o), 'ms': int(ms), 'count': int(c)} for w, o, ms, c in entries],
                'blocked_ms': sum(int(ms) for _, _, ms, _ in entries)}
    elif 'CABOOSE_GPU_DECODE_TIMING ' in line:
        f = fields(line.split('CABOOSE_GPU_DECODE_TIMING ', 1)[1])
        if 'elapsed_us' in f:
            return {'kind': 'decode', 't': received_ns, 'opcode': f.get('opcode'), 'elapsed_us': f['elapsed_us']}
    elif 'caboose-framelab: present ' in line:
        f = fields(line.split('caboose-framelab: present ', 1)[1])
        return {'kind': 'phone_present', 't': received_ns, **f}
    elif 'caboose-framelab: picture ' in line:
        f = fields(line.split('caboose-framelab: picture ', 1)[1])
        if 'window' in f and 'file' in f:
            return {'kind': 'phone_picture', 't': received_ns, 'window': f['window'], 'file': f['file']}
    return None


def percentile(values, p):
    """Nearest-rank percentile (p in 0..1) of a sequence; None when empty."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(p * len(ordered)) - 1))]


def clock_offset(samples):
    """The reader's clock minus the computer's, from (received_ns, guest_ns) pairs.

    Each pair is a guest event stamped on the computer and the reader's clock when it
    arrived; the smallest difference has the least transit delay in it, so it is the
    best estimate (an overestimate by that sample's transit time).
    """
    diffs = [received - sent for received, sent in samples]
    return min(diffs) if diffs else None


def owed(span, inputs, frames):
    """Where an input-driven app owed a picture: from each input until the first frame
    after it (at most OWED_MAX_MS), overlapping waits merged. A steady app answers each
    input before the next one arrives; a stalled one leaves one long wait."""
    frames = sorted(frames)
    out = []
    for t in sorted(inputs):
        if not span[0] <= t < span[1]:
            continue
        i = bisect.bisect_right(frames, t)
        end = min(frames[i] if i < len(frames) else span[1], t + OWED_MAX_MS * 1_000_000, span[1])
        if out and t <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], end))
        else:
            out.append((t, end))
    return out


def gaps(frames, span):
    """(start, end) of each interval between consecutive frames of a span, its edges
    counted as frames: an animation that draws nothing has one gap the span long."""
    times = [span[0]] + sorted(t for t in frames if span[0] < t < span[1]) + [span[1]]
    return list(zip(times, times[1:]))


def stall_intervals(span, inputs, frames, animated):
    """Intervals of STALL_MS or more where the app should have drawn and did not: any
    frame gap for an animation, an unanswered input otherwise."""
    waits = gaps(frames, span) if animated else owed(span, inputs, frames)
    return [w for w in waits if w[1] - w[0] >= STALL_MS * 1_000_000]


def pacing(frames, span):
    """Frames per second and the gap distribution over a span, from frame times."""
    inside = sorted(t for t in frames if span[0] <= t <= span[1])
    seconds = (span[1] - span[0]) / 1e9
    gaps = [(b - a) / 1e6 for a, b in zip(inside, inside[1:])]
    return {
        'frames': len(inside),
        'per_s': round(len(inside) / seconds, 2) if seconds > 0 else None,
        'gap_ms': {'p50': _r(percentile(gaps, 0.5)), 'p95': _r(percentile(gaps, 0.95)), 'max': _r(max(gaps) if gaps else None)},
    }


def _r(value, digits=1):
    return None if value is None else round(value, digits)


def attribute_stall(stall, read_profiles, decodes, cpu):
    """Why a stall happened, with the evidence for it.

    - phone_decode: the phone spent 50 ms or more decoding one command inside the stall
      (CABOOSE_GPU_DECODE_TIMING); the guest waiting on its replies follows from that.
    - guest_read: the app's processes were blocked reading replies for at least half the
      stall in the two-second CABOOSE_READ_PROFILE window that covers it.
    - app_busy: the app's processes used at least half a core across the stall.
    - app_idle: none of these; the app had nothing to draw or was waiting on something
      outside the GPU path.
    """
    start, end = stall
    duration_ms = (end - start) / 1e6
    evidence = {}
    phone = [d for d in decodes if start - 50_000_000 <= d['t'] <= end + 50_000_000]
    if phone:
        evidence['phone_decode_ms'] = round(sum(d['elapsed_us'] for d in phone) / 1000, 1)
        evidence['phone_decode_opcodes'] = sorted({d['opcode'] for d in phone if d.get('opcode') is not None})
    # A profile line covers the two seconds before it was read.
    reads = [r for r in read_profiles if r['t'] - 2_000_000_000 <= end and r['t'] >= start]
    if reads:
        worst = max(reads, key=lambda r: r['blocked_ms'])
        evidence['guest_blocked_ms'] = worst['blocked_ms']
        if worst['entries']:
            top = max(worst['entries'], key=lambda e: e['ms'])
            evidence['guest_blocked_top'] = f"{top['what']}{top['opcode']}"
    usage = cpu_between(cpu, start, end)
    if usage is not None:
        evidence['app_cpu_pct'] = round(usage, 1)
    if phone and evidence['phone_decode_ms'] >= 50:
        cause = 'phone_decode'
    elif reads and evidence['guest_blocked_ms'] >= min(duration_ms, 2000) / 2:
        cause = 'guest_read'
    elif usage is not None and usage >= 50:
        cause = 'app_busy'
    else:
        cause = 'app_idle'
    return {'start_ns': start, 'ms': round(duration_ms, 1), 'cause': cause, **evidence}


def cpu_between(cpu, start, end, slack=1_000_000_000):
    """Percent of one core the app used between two times, from cumulative samples
    (t, cpu_seconds) of its process tree: the samples just outside the interval, or just
    inside it within `slack` of its ends; None without them."""
    before = [s for s in cpu if s[0] <= start] or [s for s in cpu if s[0] <= start + slack][:1]
    after = [s for s in cpu if s[0] >= end][:1] or [s for s in cpu if s[0] >= end - slack][-1:]
    if not before or not after:
        return None
    (t0, c0), (t1, c1) = before[-1], after[0]
    return 100 * (c1 - c0) / ((t1 - t0) / 1e9) if t1 > t0 else None


def input_latency(inputs, frames, results=(), glass=()):
    """For each input time, the first frame after it, the first phone result after that
    frame and the first displayed (glass) time after that, in milliseconds."""
    frames, results, glass = sorted(frames), sorted(results), sorted(glass)

    def first_after(values, t):
        return next((v for v in values if v > t), None)

    rows = []
    for t in sorted(inputs):
        frame = first_after(frames, t)
        result = first_after(results, frame) if frame is not None else None
        shown = first_after(glass, result if result is not None else frame) if frame is not None else None
        rows.append((frame, result, shown, t))

    def summary(index):
        values = [(row[index] - row[3]) / 1e6 for row in rows if row[index] is not None]
        if not values:
            return None
        return {'n': len(values), 'p50': _r(percentile(values, 0.5)), 'p95': _r(percentile(values, 0.95)), 'max': _r(max(values))}

    return {'inputs': len(rows), 'to_frame_ms': summary(0), 'to_phone_result_ms': summary(1), 'to_glass_ms': summary(2)}


def scorecard(app, run, phone_records=(), offset=None):
    """One app's scorecard from its run record (what framelab-guest.py measured) and the
    phone's records over the same time (driver clock, moved by `offset`)."""
    span = (run['start_ns'], run['end_ns'])
    measured = (run.get('measure_ns', span[0]), run.get('measure_end_ns', span[1]))
    records = [r for r in run.get('records', []) if r.get('t') is not None and span[0] <= r['t'] <= span[1]]
    presents = [r['t'] for r in records if r['kind'] == 'gpu_present' and r['event'] == 'present']
    results = [r['t'] for r in records if r['kind'] == 'gpu_present' and r['event'] == 'result']
    sent = [s for w in run.get('windows', {}).values() for s in w.get('sent', [])]
    commits = [t for w in run.get('windows', {}).values() for t in w.get('commits', [])]
    rates = [r for r in records if r['kind'] == 'present_rate']
    phone = []
    if offset is not None:
        for record in phone_records:
            if record.get('t') is not None and span[0] <= record['t'] - offset <= span[1]:
                moved = {**record, 't': record['t'] - offset}
                if 'presented_ns' in record:
                    moved['presented_ns'] = record['presented_ns'] - offset
                phone.append(moved)
    path = 'gpu' if presents or any(r['presented'] for r in rates) else 'video' if sent or commits else 'none'
    # A sharpened picture of content already sent is not a frame (its bytes still count).
    frames = presents if path == 'gpu' else [s[0] for s in sent if not (len(s) > 3 and s[3])]
    card = {
        'app': app['id'],
        'name': app.get('name', app['id']),
        'path': path,
        'seconds': round((measured[1] - measured[0]) / 1e9, 1),
        'ok': run.get('ok', False),
        'error': run.get('error'),
    }
    pace = pacing(frames, measured)
    if path == 'gpu' and not presents:
        # The broker's two-second counters only: no gap distribution.
        window = [r for r in rates if measured[0] <= r['t'] <= measured[1]]
        elapsed = sum(r['elapsed_ms'] for r in window) / 1000
        pace = {'frames': sum(r['presented'] for r in window),
                'per_s': round(sum(r['presented'] for r in window) / elapsed, 2) if elapsed else None,
                'gap_ms': {'p50': None, 'p95': None, 'max': max((r['gap_max_ms'] for r in window), default=None)},
                'source': 'CABOOSE_GPU_PRESENT_RATE'}
    else:
        pace['source'] = {'gpu': 'CABOOSE_GPU_PRESENT', 'video': 'compositor frames', 'none': None}[path]
    if path == 'gpu' and results:
        pace['phone_results_per_s'] = pacing(results, measured)['per_s']
        pace['phone_result_gap_ms'] = pacing(results, measured)['gap_ms']
    card['pacing'] = pace

    inputs = [i['t'] for i in run.get('inputs', [])]
    waits = stall_intervals(measured, inputs, frames, app.get('animated', False))
    reads = [r for r in records if r['kind'] == 'read_profile']
    decodes = [r for r in phone if r['kind'] == 'decode']
    cpu = run.get('cpu', [])
    stalls = [attribute_stall(w, reads, decodes, cpu) for w in waits]
    causes = {}
    for s in stalls:
        causes[s['cause']] = causes.get(s['cause'], 0) + 1
    card['stalls'] = {'count': len(stalls), 'by_cause': causes, 'worst_ms': max((s['ms'] for s in stalls), default=0),
                      'list': stalls[:50]}

    if inputs and not app.get('animated', False):
        glass = [r['presented_ns'] for r in phone if r['kind'] == 'phone_present' and 'presented_ns' in r]
        card['input'] = input_latency(inputs, frames, results if path == 'gpu' else (), glass)
        card['input']['source'] = run.get('input_source', 'compositor control socket')
    else:
        card['input'] = None

    streams = [r for r in records if r['kind'] == 'gpu_stream' and measured[0] <= r['t'] <= measured[1]]
    seconds = (measured[1] - measured[0]) / 1e9
    if path == 'gpu' and streams:
        elapsed = sum(r['elapsed_ms'] for r in streams) / 1000
        to_phone = sum(r['to_phone_bytes'] for r in streams) / elapsed if elapsed else None
    elif path == 'video':
        to_phone = sum(s[2] for s in sent if measured[0] <= s[0] <= measured[1]) / seconds if seconds else None
    else:
        to_phone = None
    usage = cpu_between(cpu, *measured)
    peak = None
    for a, b in zip(cpu, cpu[1:]):
        if b[0] > a[0] and measured[0] <= a[0] and b[0] <= measured[1]:
            pct = 100 * (b[1] - a[1]) / ((b[0] - a[0]) / 1e9)
            peak = pct if peak is None else max(peak, pct)
    card['resources'] = {'guest_cpu_pct': _r(usage), 'guest_cpu_pct_max': _r(peak),
                         'stream_bytes_per_s': None if to_phone is None else int(to_phone),
                         'stream': {'gpu': 'GPU stream to the phone', 'video': 'window pictures to the client'}.get(path)}
    card['correctness'] = run.get('correctness')
    return card


def reference_environment(env):
    """The launch environment without the phone's Vulkan driver, for the CPU reference:
    driver lists that name it and its socket variables removed, and the loader told to skip
    any driver named gfxstream, so every toolkit falls back to the computer's drivers."""
    out = {k: v for k, v in env.items() if not k.startswith('CABOOSE_GFXSTREAM_')}
    for key in ('VK_ADD_DRIVER_FILES', 'VK_DRIVER_FILES', 'VK_ICD_FILENAMES'):
        if key in out:
            kept = [p for p in out[key].split(':') if p and 'gfxstream' not in p and 'caboose-gpu' not in p]
            if kept:
                out[key] = ':'.join(kept)
            else:
                del out[key]
    out['VK_LOADER_DRIVERS_DISABLE'] = '*gfxstream*'
    return out


# --- Pictures -------------------------------------------------------------------------

def decode_png(data):
    """(width, height, rows of RGB tuples flattened as bytes) of an 8-bit PNG: greyscale,
    RGB, palette or RGBA, not interlaced."""
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    at, idat, palette = 8, b'', None
    width = height = depth = color = interlace = None
    while at < len(data):
        length, kind = struct.unpack('>I4s', data[at:at + 8])
        body = data[at + 8:at + 8 + length]
        if kind == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif kind == b'PLTE':
            palette = body
        elif kind == b'IDAT':
            idat += body
        at += 12 + length
    if depth != 8 or interlace:
        raise ValueError('only 8-bit, non-interlaced PNG')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    stride = width * channels
    raw = zlib.decompress(idat)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = previous[x]
            c = previous[x - channels] if x >= channels else 0
            if kind == 1:
                line[x] = (line[x] + a) & 255
            elif kind == 2:
                line[x] = (line[x] + b) & 255
            elif kind == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        previous = line
    rgb = bytearray(width * height * 3)
    for y, line in enumerate(rows):
        for x in range(width):
            if color == 3:
                r, g, b = palette[line[x] * 3:line[x] * 3 + 3]
            elif color in (0, 4):
                r = g = b = line[x * channels]
            else:
                r, g, b = line[x * channels:x * channels + 3]
            o = (y * width + x) * 3
            rgb[o:o + 3] = bytes((r, g, b))
    return width, height, bytes(rgb)


def luma_grid(width, height, rgb, size):
    """The picture's luma (0..1) box-filtered to a size x size grid."""
    out = []
    for gy in range(size):
        y0, y1 = gy * height // size, max(gy * height // size + 1, (gy + 1) * height // size)
        for gx in range(size):
            x0, x1 = gx * width // size, max(gx * width // size + 1, (gx + 1) * width // size)
            total, n = 0, 0
            for y in range(y0, y1, max(1, (y1 - y0) // 8)):
                row = y * width
                for x in range(x0, x1, max(1, (x1 - x0) // 8)):
                    o = (row + x) * 3
                    total += 0.2126 * rgb[o] + 0.7152 * rgb[o + 1] + 0.0722 * rgb[o + 2]
                    n += 1
            out.append(total / n / 255)
    return out


def compare(reference, candidate, size=64, block=8):
    """A perceptual comparison of two pictures of the same scene: both reduced to a
    size x size luma grid (so scale and small offsets matter little), then mean SSIM over
    block x block tiles and the share of grid cells that differ by more than 10%."""
    a = luma_grid(*decode_png(reference), size)
    b = luma_grid(*decode_png(candidate), size)
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    scores = []
    for by in range(0, size, block):
        for bx in range(0, size, block):
            xs = [a[(by + y) * size + bx + x] for y in range(block) for x in range(block)]
            ys = [b[(by + y) * size + bx + x] for y in range(block) for x in range(block)]
            mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
            vx = sum((v - mx) ** 2 for v in xs) / len(xs)
            vy = sum((v - my) ** 2 for v in ys) / len(ys)
            cov = sum((p - mx) * (q - my) for p, q in zip(xs, ys)) / len(xs)
            scores.append(((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2)))
    changed = sum(1 for p, q in zip(a, b) if abs(p - q) > 0.1) / len(a)
    return {'ssim': round(sum(scores) / len(scores), 4), 'changed': round(changed, 4)}


def phone_picture(records, window, at, offset):
    """The phone's settled picture of a window nearest a time on the computer's clock:
    the file named by its `caboose-framelab: picture` line, or None."""
    if offset is None or window is None or at is None:
        return None
    shots = [r for r in records if r['kind'] == 'phone_picture' and r['window'] == window]
    if not shots:
        return None
    return min(shots, key=lambda r: abs(r['t'] - offset - at))['file']


def verdict(comparison, min_ssim=0.9, max_changed=0.05):
    return comparison['ssim'] >= min_ssim and comparison['changed'] <= max_changed


# --- Summary --------------------------------------------------------------------------

def _fmt(value, suffix=''):
    if value is None:
        return '-'
    if isinstance(value, float):
        value = f'{value:.0f}' if abs(value) >= 100 else f'{value:.1f}'
    return f'{value}{suffix}'


def summary_table(cards):
    """A Markdown table with one row per scorecard."""
    head = ['app', 'path', 'ok', 'fps', 'gap p50', 'gap p95', 'gap max', 'stalls', 'causes', 'input p50/p95',
            'cpu %', 'stream kB/s', 'picture']
    rows = [head, ['---'] * len(head)]
    for c in cards:
        p, inp, res, cor = c.get('pacing') or {}, c.get('input'), c.get('resources') or {}, c.get('correctness')
        gap = p.get('gap_ms') or {}
        latency = '-'
        if inp:
            best = inp.get('to_glass_ms') or inp.get('to_phone_result_ms') or inp.get('to_frame_ms')
            if best:
                which = 'glass' if inp.get('to_glass_ms') else 'result' if inp.get('to_phone_result_ms') else 'frame'
                latency = f"{_fmt(best['p50'])}/{_fmt(best['p95'])} ms ({which})"
        stream = res.get('stream_bytes_per_s')
        if cor is None:
            picture = '-'
        elif cor.get('skipped'):
            picture = 'skipped'
        else:
            picture = f"{'pass' if cor.get('pass') else 'FAIL'} {cor.get('ssim', 0):.2f}"
        rows.append([c['app'], c['path'], 'yes' if c.get('ok') else 'NO', _fmt(p.get('per_s')), _fmt(gap.get('p50')),
                     _fmt(gap.get('p95')), _fmt(gap.get('max')), str(c['stalls']['count']),
                     ' '.join(f'{k}:{v}' for k, v in sorted(c['stalls']['by_cause'].items())) or '-',
                     latency, _fmt(res.get('guest_cpu_pct')), _fmt(None if stream is None else stream / 1000), picture])
    return '\n'.join('| ' + ' | '.join(r) + ' |' for r in rows) + '\n'
