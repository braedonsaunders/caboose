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
    # A job's state as the polls see it: how many polls still find it running.
    pending = 0
    # What the poll answers once the job is no longer running: 0 (it wrote its status) or 2
    # (its runner is gone without one).
    ended = 0

    def log_message(self, *args):
        pass

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_POST(self):
        assert self.headers["Authorization"] == "Bearer secret"
        request = json.loads(self.body())
        Host.requests.append(("exec", self.path, request))
        script = request["args"][1] if request["args"][:1] == ["-c"] else ""
        if script.startswith("test -f ") and ".rc && exit 0" in script:
            Host.pending -= 1
            answer = {"exitCode": 1 if Host.pending >= 0 else Host.ended, "stdout": "", "stderr": ""}
        elif script.startswith("setsid "):
            answer = {"exitCode": 0, "stdout": "", "stderr": ""}
        else:
            answer = Host.answer
        data = json.dumps(answer).encode()
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
        Host.pending = 0
        Host.ended = 0

    def scripts(self):
        found = []
        for kind, path, request in Host.requests:
            if kind == "exec":
                self.assertEqual(path, "/v1/host/computers/c-1/exec")
                self.assertEqual(request["command"], "/bin/sh")
                found.append(request["args"][1])
        return found

    def script(self):
        """The command a check ran: the job started (or the detached command)."""
        return next(s for s in self.scripts() if s.startswith("setsid "))

    def job_command(self):
        """The command a check ran, as the job's script file holds it."""
        (data, mode), = [v for k, v in Host.files.items() if k.endswith(".sh")]
        self.assertEqual(mode, "0644")
        return data.decode()

    def test_an_exec_runs_as_the_user_in_the_capped_slice_and_returns_its_status(self):
        Host.answer = {"exitCode": 3, "stdout": "out", "stderr": ""}
        status = computer.run_exec(["-u", "caboose", "-e", "A=b c", "-w", "/tmp", "vm:c-1", "sh", "-c", "echo $A"])
        self.assertEqual(status, 3)
        runner = self.script()
        self.assertIn("systemd-run --quiet --scope --collect --slice=caboose-check.slice", runner)
        self.assertIn("MemoryMax=4G", runner)
        self.assertIn("prlimit --core=0:0 -- nice -n 19 runuser -u caboose -- /bin/sh /var/tmp/caboose-check-job-", runner)
        command = self.job_command()
        self.assertIn("cd /tmp", command)
        self.assertIn("'A=b c'", command)

    def test_the_command_never_appears_on_a_command_line(self):
        computer.run_exec(["vm:c-1", "pkill", "-TERM", "-f", "/home/x/.check-1/repo/"])
        self.assertIn("pkill -TERM -f /home/x/.check-1/repo/", self.job_command())
        for script in self.scripts():
            self.assertNotIn(".check-1", script)

    def test_standard_input_is_written_to_the_guest_first_and_removed(self):
        computer.run_exec(["-i", "vm:c-1", "sh", "-c", "cat > /x"], stdin=io.BytesIO(b"bat\r\n"))
        path, = [k for k in Host.files if k.endswith(".in")]
        self.assertEqual(Host.files[path], (b"bat\r\n", "0644"))
        self.assertIn(f"< {path}", self.job_command())
        self.assertIn("rm -f /var/tmp/caboose-check-job-", self.scripts()[-1])

    def test_a_long_command_runs_as_a_job_polled_to_its_end(self):
        Host.pending = 3
        Host.answer = {"exitCode": 7, "stdout": "done\n", "stderr": "warn\n"}
        self.assertEqual(computer.run_exec(["vm:c-1", "sleep", "60"]), 7)
        scripts = self.scripts()
        self.assertTrue(scripts[0].startswith("setsid /bin/sh -c "))
        self.assertIn(".part; mv ", scripts[0])
        self.assertEqual(sum(1 for s in scripts if s.startswith("test -f ")), 4)
        self.assertIn("status=$(cat ", scripts[-1])

    def test_a_job_whose_runner_ended_is_not_waited_for_forever(self):
        Host.pending, Host.ended = 1, 2
        Host.answer = {"exitCode": 137, "stdout": "", "stderr": ""}
        self.assertEqual(computer.run_exec(["vm:c-1", "true"]), 137)
        self.assertIn("|| echo 137", self.scripts()[-1])

    def test_a_detached_command_is_left_running_in_its_own_session(self):
        computer.run_exec(["-d", "-u", "caboose", "vm:c-1", "sleep", "60"])
        self.assertEqual(len(self.scripts()), 1)
        script = self.script()
        self.assertTrue(script.startswith("setsid /bin/sh -c "))
        self.assertTrue(script.endswith("< /dev/null > /dev/null 2>&1 &"))
        self.assertIn("rm -f /var/tmp/caboose-check-job-", script)

    def test_a_copy_sends_a_tar_and_unpacks_it_into_a_directory_or_as_the_path(self):
        source = Path(self.tmp.name) / "tree"
        (source / "sub").mkdir(parents=True, exist_ok=True)
        (source / "sub" / "f").write_text("x")
        self.assertEqual(computer.run_cp(["-q", str(source), "vm:c-1:/srv/repo/"]), 0)
        (path, (data, _)), = Host.files.items()
        with tarfile.open(fileobj=io.BytesIO(data)) as tar:
            self.assertIn("tree/sub/f", tar.getnames())
        script = self.scripts()[-1]
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
