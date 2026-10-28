"""Real Linux process checks; run as root in the disposable container documented in README."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
import urllib.request

SOURCE = Path(__file__).with_name('container-services.sh')

class ServiceReplacement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o755)
        self.functions = self.root / 'functions.sh'
        self.functions.write_text(SOURCE.read_text().split('MODE=${1:-}')[0])
        self.pids = set()
        self.addCleanup(self.stop_owned)

    def stop_owned(self):
        for pid in self.pids:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass

    def script(self, name, version, port):
        path = self.root / name
        path.write_text(f'''from http.server import HTTPServer, BaseHTTPRequestHandler
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.end_headers(); self.wfile.write({version.encode()!r})
 def log_message(self, *args): pass
HTTPServer(('127.0.0.1', {port}), Handler).serve_forever()
''')
        return path

    def run_service(self, name, script, port, mode='', check=True):
        result = subprocess.run(['bash', '-c', 'source "$1"; MODE=$2; owner_service "$3" "$4" "$5" fixture', 'sh', str(self.functions), mode, name, str(script), str(port)], capture_output=True, text=True, timeout=20)
        pidfile = Path('/run/caboose', name + '.pid')
        if pidfile.exists():
            try: self.pids.add(int(pidfile.read_text()))
            except ValueError: pass
        if check: self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def read(self, port):
        return urllib.request.urlopen(f'http://127.0.0.1:{port}', timeout=2).read()

    def test_repairs_lost_pid_and_replaces_loaded_code(self):
        script = self.script('service.py', 'old', 14881)
        self.run_service('fixture', script, 14881)
        pidfile = Path('/run/caboose/fixture.pid')
        old = int(pidfile.read_text())
        self.assertEqual(self.read(14881), b'old')
        # The old upgrader replaced a useful pid file after its cross-uid identity read failed.
        pidfile.write_text('1\n')
        self.script('service.py', 'new', 14881)
        self.run_service('fixture', script, 14881, 'restart')
        new = int(pidfile.read_text())
        self.assertNotEqual(new, old)
        self.assertEqual(self.read(14881), b'new')
        pidfile.unlink()
        self.run_service('fixture', script, 14881)
        self.assertEqual(int(pidfile.read_text()), new)
        self.assertEqual(self.read(14881), b'new')

    def test_unrelated_listener_never_counts_as_readiness(self):
        foreign = self.script('foreign.py', 'foreign', 14882)
        self.run_service('foreign-fixture', foreign, 14882)
        wanted = self.script('wanted.py', 'wanted', 14882)
        result = self.run_service('wanted-fixture', wanted, 14882, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read(14882), b'foreign')

if __name__ == '__main__': unittest.main()
