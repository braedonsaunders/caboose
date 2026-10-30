#!/usr/bin/env python3
"""Exercise the session's readiness ordering without starting a display or a bus."""
from pathlib import Path
import subprocess
import unittest

source = Path(__file__).with_name('caboose-session').read_text()
ready = source.split('seat_ready() {', 1)[1].split('\n}', 1)[0]

class SeatReadyTests(unittest.TestCase):
    def run_ready(self, port, envfile, bus, display=0, activation=0):
        script = '''
        caboose-display-ready() { echo "display:$*"; return "$DISPLAY_STATUS"; }
        activation_environment() { echo "activation:$*"; return "$ACTIVATION_STATUS"; }
        a11y_bus() { echo "accessibility:$*"; }
        seat_ready() { READY_BODY
        }
        seat_ready "$1" "$2" "$3"
        '''.replace('READY_BODY', ready)
        result = subprocess.run(['bash', '-c', script, 'test', port, envfile, bus],
                                env={'PATH': '/usr/bin:/bin', 'DISPLAY_STATUS': str(display),
                                     'ACTIVATION_STATUS': str(activation)}, text=True, capture_output=True)
        return result.returncode, result.stdout.splitlines()

    def test_owner_and_agent_keep_separate_buses(self):
        for port, envfile, bus in [('14600', '/run/caboose/display.env', '/run/user/1000/bus'),
                                   ('14601', '/run/caboose/agent-display.env', '/run/user/1000/agent-bus')]:
            code, lines = self.run_ready(port, envfile, bus)
            self.assertEqual(code, 0)
            self.assertEqual(lines, [f'display:120 {port}', f'activation:{envfile} {bus}',
                                     f'accessibility:{envfile} {bus}'])

    def test_unready_display_does_not_publish_old_environment(self):
        code, lines = self.run_ready('14600', 'env', 'bus', display=1)
        self.assertEqual(code, 1)
        self.assertEqual(lines, ['display:120 14600'])

    def test_activation_failure_does_not_report_ready(self):
        code, lines = self.run_ready('14600', 'env', 'bus', activation=124)
        self.assertEqual(code, 124)
        self.assertEqual(lines, ['display:120 14600', 'activation:env bus'])

if __name__ == '__main__':
    unittest.main()
