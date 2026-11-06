"""computer.py, the checks' way into a container or a virtual machine, against a stand-in host:
python3 -m unittest apps/ios/GPUStream/gfxstream/linux-executor/test_computer.py"""
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
import urllib.parse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import computer  # noqa: E402


class Host(BaseHTTPRequestHandler):
    """The host's operator routes: records each request, answers exec with `answer`."""
    requests = []
    files = {}
    answer = {"exitCode": 0, "stdout": "", "stderr": ""}

    def log_message(self, *args):
        pass

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_POST(self):
        assert self.headers["Authorization"] == "Bearer secret"
        request = json.loads(self.body())
        Host.requests.append(("exec", self.path, request))
        data = json.dumps(Host.answer).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        Host.files[query["path"][0]] = (self.body(), query["mode"][0])
        Host.requests.append(("put", self.path, None))
        self.send_response(204)
        self.end_headers()


class Computer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), Host)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory()
        token = Path(cls.tmp.name) / "token"
        token.write_text("secret\n")
        os.environ["CABOOSE_HOST_URL"] = f"http://127.0.0.1:{cls.server.server_port}"
        os.environ["CABOOSE_HOST_TOKEN_FILE"] = str(token)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Host.requests.clear()
        Host.files.clear()
        Host.answer = {"exitCode": 0, "stdout": "", "stderr": ""}

    def script(self):
        kind, path, request = Host.requests[-1]
        self.assertEqual((kind, path), ("exec", "/v1/host/computers/c-1/exec"))
        self.assertEqual(request["command"], "/bin/sh")
        return request["args"][1]

    def test_an_exec_runs_as_the_user_in_the_capped_slice_and_returns_its_status(self):
        Host.answer = {"exitCode": 3, "stdout": "out", "stderr": ""}
        status = computer.run_exec(["-u", "caboose", "-e", "A=b c", "-w", "/tmp", "vm:c-1", "sh", "-c", "echo $A"])
        self.assertEqual(status, 3)
        script = self.script()
        self.assertIn("systemd-run --quiet --scope --collect --slice=caboose-check.slice", script)
        self.assertIn("MemoryMax=4G", script)
        self.assertIn("prlimit --core=0:0 -- nice -n 19", script)
        self.assertIn("runuser -u caboose --", script)
        self.assertIn("cd /tmp", script)
        self.assertIn("'A=b c'", script)

    def test_standard_input_is_written_to_the_guest_first_and_removed(self):
        computer.run_exec(["-i", "vm:c-1", "sh", "-c", "cat > /x"], stdin=io.BytesIO(b"bat\r\n"))
        (path, (data, mode)), = Host.files.items()
        self.assertTrue(path.startswith("/var/tmp/caboose-check-stdin-"))
        self.assertEqual((data, mode), (b"bat\r\n", "0644"))
        script = self.script()
        self.assertIn(f"< {path}", script)
        self.assertIn(f"rm -f {path}", script)

    def test_a_detached_command_is_left_running_in_its_own_session(self):
        computer.run_exec(["-d", "-u", "caboose", "vm:c-1", "sleep", "60"])
        script = self.script()
        self.assertTrue(script.startswith("setsid /bin/sh -c "))
        self.assertTrue(script.endswith("< /dev/null > /dev/null 2>&1 &"))

    def test_a_copy_sends_a_tar_and_unpacks_it_into_a_directory_or_as_the_path(self):
        source = Path(self.tmp.name) / "tree"
        (source / "sub").mkdir(parents=True, exist_ok=True)
        (source / "sub" / "f").write_text("x")
        self.assertEqual(computer.run_cp(["-q", str(source), "vm:c-1:/srv/repo/"]), 0)
        (path, (data, _)), = Host.files.items()
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            self.assertIn("tree/sub/f", tar.getnames())
        script = self.script()
        self.assertIn("t=/srv/repo;", script)
        self.assertIn(f"tar -C \"$t\" --no-same-owner -xf {path}", script)
        self.assertIn(f"rm -f {path}", script)

    def test_a_container_shares_its_network_and_a_virtual_machine_is_reached_at_its_address(self):
        self.assertEqual(computer.network("caboose-c-1"), ("container:caboose-c-1", "127.0.0.1", "127.0.0.1"))
        Host.answer = {"exitCode": 0, "stdout": "192.0.2.14\n", "stderr": ""}
        self.assertEqual(computer.network("vm:c-1"), ("host", "192.0.2.14", "0.0.0.0"))
        os.environ["CABOOSE_VM_ADDRESS"] = "10.0.0.9"
        try:
            self.assertEqual(computer.network("vm:c-1"), ("host", "10.0.0.9", "0.0.0.0"))
        finally:
            del os.environ["CABOOSE_VM_ADDRESS"]

    def test_the_docker_shim_passes_anything_else_to_docker(self):
        fake = Path(self.tmp.name) / "bin"
        fake.mkdir(exist_ok=True)
        (fake / "docker").write_text('#!/bin/sh\necho "real $*"\n')
        (fake / "docker").chmod(0o755)
        env = {**os.environ, "PATH": f"{HERE / 'computer-bin'}{os.pathsep}{fake}{os.pathsep}/usr/bin:/bin"}
        out = subprocess.run([str(HERE / "computer-bin/docker"), "logs", "caboose-x"], env=env,
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, "real logs caboose-x\n")


if __name__ == "__main__":
    unittest.main()
