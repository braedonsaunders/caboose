"""check_session_features.findings names the component that dropped each feature."""
import unittest
from pathlib import Path

import check_session_features as check
import gpu_features

REPO = Path(__file__).resolve().parents[3]
EXPECTED = gpu_features.expected(REPO)
ALL = ','.join(sorted(EXPECTED['phone_features']))
FULL = f"CABOOSE_GPU_HELLO features={EXPECTED['hello_features']}"


def session(declared=ALL, forwarded=ALL, received=ALL, source='relay'):
    return f'CABOOSE_GPU_SESSION_FEATURES source={source} declared={declared} forwarded={forwarded} received={received} bits=0x0'


def without(names, *drop):
    return ','.join(n for n in names.split(',') if n not in drop)


class CheckSessionFeaturesTest(unittest.TestCase):
    def test_a_full_session_passes(self):
        problems, summary = check.findings([session(), FULL], EXPECTED)
        self.assertEqual(problems, [])
        self.assertIn(f"hello={EXPECTED['hello_features']}", summary)

    def test_each_dropping_component_is_named(self):
        lines = [session(declared=without(ALL, 'wait-serial'), forwarded=without(ALL, 'wait-serial', 'silent-success'),
                         received=without(ALL, 'wait-serial', 'silent-success', 'guest-set-ids')), FULL]
        problems = '\n'.join(check.findings(lines, EXPECTED)[0])
        self.assertIn('wait-serial: the phone app did not declare it', problems)
        self.assertIn('silent-success: the host relay dropped it', problems)
        self.assertIn('guest-set-ids: the broker\'s admission dropped it', problems)

    def test_a_short_hello_is_named(self):
        problems = check.findings([session(), 'CABOOSE_GPU_HELLO features=0xbff80'], EXPECTED)[0]
        self.assertEqual(len(problems), 1)
        self.assertIn('lacks completion-payloads, guest-set-ids, one-way-start, silent-success, wait-serial', problems[0])

    def test_the_last_relay_session_counts_and_direct_ones_are_ignored(self):
        lines = [session(received=without(ALL, 'wait-serial')), FULL, session(), FULL, session(source='direct', received='-')]
        self.assertEqual(check.findings(lines, EXPECTED)[0], [])

    def test_an_older_broker_is_checked_by_its_hellos(self):
        problems, summary = check.findings(['CABOOSE_GPU_HELLO features=0xbff80'], EXPECTED)
        self.assertIn('lacks completion-payloads', problems[0])
        self.assertIn('predates', summary)
        self.assertEqual(check.findings([FULL], EXPECTED)[0], [])

    def test_no_session_is_unchecked(self):
        self.assertIsNone(check.findings(['nothing'], EXPECTED)[0])


if __name__ == '__main__':
    unittest.main()
