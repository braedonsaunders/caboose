"""Negative controls for the oracle, not evidence that a GPU rendered anything."""
import json
from pathlib import Path
import unittest

from verify import verify_pixels

CASES = {c['name']: c for c in json.loads(Path(__file__).with_name('expected.json').read_text())['tests']}


def sampled_image(case):
    # Test-only bytes. Native acceptance never uses this generator.
    image = bytearray(bytes([0, 0, 0, 255]) * (128 * 64))
    for sample in case['samples']:
        x, y = sample['xy']; offset = (y * 128 + x) * 4
        image[offset:offset + 4] = bytes(sample['rgba'])
    return image


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.case = CASES['compute_cpu_feedback']
        self.pixels = sampled_image(self.case)
        self.metadata = {'gpu_feedback_words': [6, 1, 0, 0, 19 ^ 0x6d2b79f5]}

    def test_feedback_and_image_required(self):
        self.assertEqual(verify_pixels(self.pixels, self.case, self.metadata)['status'], 'PASS')

    def test_zero_gpu_results_fail_even_with_correct_image(self):
        self.metadata['gpu_feedback_words'] = [0] * 5
        self.assertEqual(verify_pixels(self.pixels, self.case, self.metadata)['status'], 'FAIL')

    def test_stale_cookie_fails(self):
        self.metadata['gpu_feedback_words'][-1] = 0xdeadbeef
        self.assertEqual(verify_pixels(self.pixels, self.case, self.metadata)['status'], 'FAIL')

    def test_prior_run_feedback_fails_new_challenge(self):
        self.metadata['feedback_seed'] = 23
        self.assertEqual(verify_pixels(self.pixels, self.case, self.metadata, expected_seed=23)['status'], 'FAIL')

    def test_new_challenge_requires_matching_gpu_cookie(self):
        self.metadata['feedback_seed'] = 23
        self.metadata['gpu_feedback_words'][-1] = 23 ^ 0x6d2b79f5
        self.assertEqual(verify_pixels(self.pixels, self.case, self.metadata, expected_seed=23)['status'], 'PASS')
        self.assertEqual(verify_pixels(self.pixels, self.case, self.metadata, expected_seed=27)['status'], 'FAIL')

    def test_no_cpu_feedback_fails(self):
        self.assertEqual(verify_pixels(self.pixels, self.case, {})['status'], 'FAIL')

    def test_skipped_cpu_branch_fails(self):
        both_triangles = sampled_image(CASES['compute_indirect'])
        self.assertEqual(verify_pixels(both_triangles, self.case, self.metadata)['status'], 'FAIL')

    def test_no_compute_draw_fails(self):
        cleared = bytes([0, 0, 0, 255]) * (128 * 64)
        self.assertEqual(verify_pixels(cleared, CASES['compute_indirect'], {})['status'], 'FAIL')

    def test_short_readback_fails(self):
        self.assertEqual(verify_pixels(self.pixels[:-1], self.case, self.metadata)['status'], 'FAIL')


if __name__ == '__main__':
    unittest.main()
