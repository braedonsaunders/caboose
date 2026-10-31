import struct
import unittest
import zlib
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import framelab as fl

MS = 1_000_000
S = 1_000_000_000


def png(width, height, pixel, filter_type=0):
    """An RGB PNG whose pixel (x, y) is pixel(x, y), every row with one filter type."""
    raw = bytearray()
    previous = bytes(width * 3)
    for y in range(height):
        line = bytes(c for x in range(width) for c in pixel(x, y))
        if filter_type == 1:
            encoded = bytes((line[i] - (line[i - 3] if i >= 3 else 0)) & 255 for i in range(len(line)))
        elif filter_type == 2:
            encoded = bytes((line[i] - previous[i]) & 255 for i in range(len(line)))
        else:
            encoded = line
        raw += bytes((filter_type,)) + encoded
        previous = line

    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(raw))) + chunk(b'IEND', b''))


class ParseTests(unittest.TestCase):
    def test_present_trace_and_stream(self):
        self.assertEqual(fl.parse_line('x CABOOSE_GPU_PRESENT event=result monotonic_ns=42'),
                         {'kind': 'gpu_present', 'event': 'result', 't': 42})
        r = fl.parse_line('CABOOSE_GPU_STREAM elapsed_ms=1000 to_phone_bytes=5 from_phone_bytes=2 monotonic_ns=9')
        self.assertEqual((r['t'], r['to_phone_bytes'], r['from_phone_bytes']), (9, 5, 2))

    def test_present_rate_takes_the_reader_time(self):
        r = fl.parse_line('CABOOSE_GPU_PRESENT_RATE elapsed_ms=2001 presented=60 ordered=0 results=59 released=59 '
                          'gap_max_ms=180 result_gap_max_ms=200', received_ns=7)
        self.assertEqual((r['t'], r['presented'], r['gap_max_ms']), (7, 60, 180))

    def test_read_profile_entries(self):
        r = fl.parse_line('[pid 4] CABOOSE_READ_PROFILE op20320=120ms/40 drain20325=30ms/3', received_ns=1)
        self.assertEqual(r['blocked_ms'], 150)
        self.assertEqual(r['entries'][0], {'what': 'op', 'opcode': 20320, 'ms': 120, 'count': 40})
        self.assertEqual(r['entries'][1]['what'], 'drain')

    def test_phone_lines(self):
        r = fl.parse_line('CABOOSE_GPU_DECODE_TIMING stream=3 opcode=20324 elapsed_us=81000 host_sync=0', 5)
        self.assertEqual((r['kind'], r['opcode'], r['elapsed_us']), ('decode', 20324, 81000))
        self.assertIsNone(fl.parse_line('CABOOSE_GPU_DECODE_TIMING limit=64', 5))
        r = fl.parse_line('caboose-framelab: present window=4 seq=17 presented_ns=123', 9)
        self.assertEqual((r['window'], r['seq'], r['presented_ns']), (4, 17, 123))
        self.assertIsNone(fl.parse_line('unrelated'))


class MathTests(unittest.TestCase):
    def test_percentile_nearest_rank(self):
        self.assertEqual(fl.percentile([5, 1, 3, 2, 4], 0.5), 3)
        self.assertEqual(fl.percentile(list(range(1, 101)), 0.95), 95)
        self.assertIsNone(fl.percentile([], 0.5))

    def test_clock_offset_takes_the_fastest_sample(self):
        self.assertEqual(fl.clock_offset([(1100, 100), (1050, 60), (2000, 900)]), 990)
        self.assertIsNone(fl.clock_offset([]))

    def test_owed_waits_end_at_the_answer_and_merge(self):
        frames = [1 * S + 10 * MS, 2 * S + 300 * MS]
        got = fl.owed((0, 10 * S), [1 * S, 2 * S, 2 * S + 100 * MS, 9 * S], frames)
        self.assertEqual(got, [(1 * S, 1 * S + 10 * MS), (2 * S, 2 * S + 300 * MS), (9 * S, 10 * S)])
        # An unanswered input waits at most OWED_MAX_MS.
        self.assertEqual(fl.owed((0, 10 * S), [1 * S], []), [(1 * S, 3 * S)])

    def test_gaps_include_the_edges(self):
        self.assertEqual(fl.gaps([2, 5, 20], (0, 10)), [(0, 2), (2, 5), (5, 10)])
        self.assertEqual(fl.gaps([], (0, 10)), [(0, 10)])

    def test_stall_intervals(self):
        frames = [i * 16 * MS for i in range(10)] + [400 * MS]
        self.assertEqual(fl.stall_intervals((0, 400 * MS), [], frames, True), [(144 * MS, 400 * MS)])
        # Typing every 250 ms, each key answered in 5 ms: no stall for a static app.
        keys = [i * 250 * MS for i in range(8)]
        self.assertEqual(fl.stall_intervals((0, 2 * S), keys, [k + 5 * MS for k in keys], False), [])

    def test_pacing(self):
        frames = [i * 16 * MS for i in range(61)] + [61 * 16 * MS + 200 * MS]
        p = fl.pacing(frames, (0, 1200 * MS))
        self.assertEqual(p['frames'], 62)
        self.assertEqual(p['gap_ms'], {'p50': 16.0, 'p95': 16.0, 'max': 216.0})

    def test_cpu_between(self):
        cpu = [(0, 0.0), (1 * S, 0.5), (2 * S, 0.6)]
        self.assertAlmostEqual(fl.cpu_between(cpu, 0, 2 * S), 30.0)
        self.assertAlmostEqual(fl.cpu_between(cpu, 0, 2 * S + 500 * MS), 30.0)  # the last sample, just inside
        self.assertIsNone(fl.cpu_between(cpu, 0, 4 * S))


class StallTests(unittest.TestCase):
    def test_phone_decode_wins(self):
        s = fl.attribute_stall((1 * S, 1 * S + 300 * MS), [{'t': 2 * S, 'blocked_ms': 280, 'entries': []}],
                               [{'t': 1 * S + 100 * MS, 'elapsed_us': 250000, 'opcode': 20324}], [])
        self.assertEqual(s['cause'], 'phone_decode')
        self.assertEqual((s['phone_decode_ms'], s['guest_blocked_ms']), (250.0, 280))

    def test_guest_read(self):
        reads = [{'t': 2 * S, 'blocked_ms': 200, 'entries': [{'what': 'drain', 'opcode': 20325, 'ms': 190, 'count': 2}]}]
        s = fl.attribute_stall((1 * S, 1 * S + 300 * MS), reads, [], [])
        self.assertEqual((s['cause'], s['guest_blocked_top']), ('guest_read', 'drain20325'))
        # A profile read before the stall began does not cover it.
        self.assertEqual(fl.attribute_stall((3 * S, 3 * S + 300 * MS), reads, [], [])['cause'], 'app_idle')

    def test_busy_or_idle_from_cpu(self):
        busy = [(0, 0.0), (2 * S, 1.6)]
        self.assertEqual(fl.attribute_stall((S // 2, S), [], [], busy)['cause'], 'app_busy')
        self.assertEqual(fl.attribute_stall((S // 2, S), [], [], [(0, 0.0), (2 * S, 0.1)])['cause'], 'app_idle')


class LatencyTests(unittest.TestCase):
    def test_input_to_frame_result_and_glass(self):
        got = fl.input_latency([1 * S, 2 * S], [1 * S + 30 * MS, 2 * S + 50 * MS],
                               [1 * S + 60 * MS, 2 * S + 90 * MS], [1 * S + 70 * MS])
        self.assertEqual(got['to_frame_ms'], {'n': 2, 'p50': 30.0, 'p95': 50.0, 'max': 50.0})
        self.assertEqual(got['to_phone_result_ms']['max'], 90.0)
        self.assertEqual(got['to_glass_ms'], {'n': 1, 'p50': 70.0, 'p95': 70.0, 'max': 70.0})


class ScorecardTests(unittest.TestCase):
    def run_record(self, presents, **extra):
        records = [{'kind': 'gpu_present', 'event': 'present', 't': t} for t in presents]
        records += [{'kind': 'gpu_present', 'event': 'result', 't': t + 20 * MS} for t in presents]
        records += [{'kind': 'gpu_stream', 't': 2 * S, 'elapsed_ms': 1000, 'to_phone_bytes': 4000, 'from_phone_bytes': 0}]
        return {'start_ns': 0, 'measure_ns': 1 * S, 'end_ns': 3 * S, 'ok': True, 'records': records,
                'cpu': [(1 * S, 0.0), (2 * S, 0.25), (3 * S, 0.5)], **extra}

    def test_animated_gpu_app(self):
        presents = [1 * S + i * 20 * MS for i in range(50)] + [2 * S + 400 * MS + i * 20 * MS for i in range(30)]
        card = fl.scorecard({'id': 'vkcube', 'animated': True}, self.run_record(presents))
        self.assertEqual(card['path'], 'gpu')
        self.assertEqual(card['pacing']['frames'], 80)
        self.assertEqual(card['pacing']['gap_ms']['max'], 420.0)
        self.assertEqual(card['stalls']['count'], 1)
        self.assertEqual(card['stalls']['by_cause'], {'app_idle': 1})
        self.assertEqual(card['resources']['guest_cpu_pct'], 25.0)
        self.assertEqual(card['resources']['stream_bytes_per_s'], 4000)
        self.assertIsNone(card['input'])

    def test_static_app_with_input_and_phone_lines(self):
        presents = [1 * S + 500 * MS + 40 * MS]
        run = self.run_record(presents, inputs=[{'t': 1 * S + 500 * MS}])
        # On the driver's clock, 10 s ahead of the computer's.
        phone = [{'kind': 'phone_present', 't': 11 * S + 650 * MS, 'presented_ns': 11 * S + 600 * MS}]
        card = fl.scorecard({'id': 'gtk4'}, run, phone, offset=10 * S)
        self.assertEqual(card['input']['to_frame_ms']['p50'], 40.0)
        self.assertEqual(card['input']['to_phone_result_ms']['p50'], 60.0)
        self.assertEqual(card['input']['to_glass_ms']['p50'], 100.0)
        # Answered in 40 ms, and nothing else is owed: no stall.
        self.assertEqual(card['stalls']['count'], 0)

    def test_video_path_from_compositor_frames(self):
        sent = [[1 * S + i * 100 * MS, 1 * S + i * 100 * MS - 5 * MS, 1000, False] for i in range(10)]
        sent.append([1 * S + 950 * MS, 1 * S + 950 * MS, 0, True])  # sharpening only
        run = {'start_ns': 0, 'measure_ns': 1 * S, 'end_ns': 2 * S, 'ok': True,
               'windows': {'7': {'commits': [], 'sent': sent}}, 'cpu': []}
        card = fl.scorecard({'id': 'terminal'}, run)
        self.assertEqual(card['path'], 'video')
        self.assertEqual(card['pacing']['per_s'], 10.0)
        self.assertEqual(card['resources']['stream_bytes_per_s'], 10000)

    def test_rate_only(self):
        records = [{'kind': 'present_rate', 't': 2 * S, 'elapsed_ms': 1000, 'presented': 30, 'ordered': 0,
                    'results': 30, 'released': 30, 'gap_max_ms': 70, 'result_gap_max_ms': 80}]
        card = fl.scorecard({'id': 'x', 'animated': True},
                            {'start_ns': 0, 'measure_ns': 1 * S, 'end_ns': 3 * S, 'ok': True, 'records': records})
        self.assertEqual(card['pacing']['per_s'], 30.0)
        self.assertEqual(card['pacing']['source'], 'CABOOSE_GPU_PRESENT_RATE')

    def test_summary_table(self):
        card = fl.scorecard({'id': 'vkcube', 'animated': True}, self.run_record([1 * S + i * 20 * MS for i in range(100)]))
        table = fl.summary_table([card])
        self.assertIn('| vkcube | gpu | yes | 50.0 |', table)


class EnvironmentTests(unittest.TestCase):
    def test_reference_environment_drops_the_phone_driver(self):
        env = {'VK_ADD_DRIVER_FILES': '/usr/local/lib/caboose-gpu-live/icd.json', 'VK_ICD_FILENAMES': '/a/x.json:/b/gfxstream.json',
               'CABOOSE_GFXSTREAM_SOCKET': '/run/gpu.sock', 'DISPLAY': ':110'}
        got = fl.reference_environment(env)
        self.assertEqual(got, {'VK_ICD_FILENAMES': '/a/x.json', 'DISPLAY': ':110', 'VK_LOADER_DRIVERS_DISABLE': '*gfxstream*'})


class PictureTests(unittest.TestCase):
    def test_decode_filters(self):
        pixel = lambda x, y: (x * 10, y * 20, (x + y) * 5)
        for f in (0, 1, 2):
            w, h, rgb = fl.decode_png(png(5, 4, pixel, f))
            self.assertEqual((w, h), (5, 4))
            self.assertEqual(rgb[(2 * 5 + 3) * 3:(2 * 5 + 3) * 3 + 3], bytes(pixel(3, 2)))

    def test_compare(self):
        scene = lambda x, y: (200, 40, 40) if (x // 16 + y // 16) % 2 else (20, 20, 220)
        same = fl.compare(png(128, 96, scene), png(128, 96, scene, 2))
        self.assertEqual(same, {'ssim': 1.0, 'changed': 0.0})
        self.assertTrue(fl.verdict(same))
        blank = fl.compare(png(128, 96, scene), png(128, 96, lambda x, y: (0, 0, 0)))
        self.assertFalse(fl.verdict(blank))
        # The same scene at another scale still matches.
        half = fl.compare(png(128, 96, scene), png(64, 48, lambda x, y: scene(x * 2, y * 2)))
        self.assertTrue(fl.verdict(half), half)


if __name__ == '__main__':
    unittest.main()
