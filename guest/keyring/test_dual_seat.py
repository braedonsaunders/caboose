"""Host fixture bounds and cleanup, without Docker or guest dependencies."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('dual', Path(__file__).with_name('check-dual-seat.py'))
dual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dual)


class HostBounds(unittest.TestCase):
    def exercise(self, failure=False, limit=256):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            if args[:2] == ['docker', 'run'] and failure:
                raise subprocess.TimeoutExpired(args, 180)
            absent = args[:2] == ['docker', 'inspect'] and '--format' not in args
            absent |= args[:3] == ['docker', 'volume', 'inspect']
            return subprocess.CompletedProcess(args, 1 if absent else 0)
        with patch.object(dual.os, 'sched_getaffinity', create=True, return_value={3, 5, 7}), \
             patch.object(dual.subprocess, 'check_output', return_value='sha256:test'), \
             patch.object(dual.subprocess, 'run', side_effect=run):
            if failure:
                with self.assertRaises(subprocess.TimeoutExpired):
                    dual.host('sha256:test', __file__, pids_limit=limit)
            else:
                dual.host('sha256:test', __file__, pids_limit=limit)
        runs = [(a, k) for a, k in calls if a[:2] == ['docker', 'run']]
        self.assertEqual(len(runs), 1 if failure else 2)
        for args, kwargs in runs:
            for key, value in [('--cpus', '2'), ('--cpuset-cpus', '3,5'),
                               ('--memory', '2g'), ('--network', 'none'), ('--pids-limit', str(limit))]:
                self.assertEqual(args[args.index(key)+1], value)
            self.assertEqual(kwargs['timeout'], 180)
            name = args[args.index('--name')+1]
            self.assertTrue(any(a == ['docker', 'rm', '-f', name] for a, _ in calls))
            self.assertTrue(any(a == ['docker', 'inspect', name] for a, _ in calls))
        self.assertEqual(calls[-1][0][:3], ['docker', 'volume', 'inspect'])

    def test_sequential_bounds(self):
        self.exercise()

    def test_timeout_reaps_without_second_phase(self):
        self.exercise(failure=True)

    def test_explicit_bounded_retry(self):
        self.exercise(limit=512)

    def test_reject_unbounded_pids(self):
        with self.assertRaises(AssertionError):
            dual.host('unused', __file__, pids_limit=-1)


if __name__ == '__main__':
    unittest.main()
