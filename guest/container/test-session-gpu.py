"""caboose-session leaves a virtual machine's broker to systemd: python3 guest/container/test-session-gpu.py"""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "caboose-session"


def systemd_broker(run_dir, units):
    body = subprocess.run(["sed", "-n", "/^systemd_broker()/,/^}/p", str(SCRIPT)], capture_output=True, text=True, check=True).stdout
    return subprocess.run(["bash", "-c", body + "\nsystemd_broker"],
                          env={"CABOOSE_SYSTEMD_RUN": str(run_dir), "CABOOSE_SYSTEMD_UNITS": str(units), "PATH": "/usr/bin:/bin"}).returncode == 0


class SessionGPU(unittest.TestCase):
    def test_a_virtual_machines_broker_is_systemds(self):
        with tempfile.TemporaryDirectory() as tmp:
            run, units = Path(tmp) / "run", Path(tmp) / "units"
            run.mkdir(); units.mkdir()
            self.assertFalse(systemd_broker(run, units))  # no unit: the session runs it (a container)
            (units / "caboose-gpu-broker.service").write_text("[Service]\n")
            self.assertTrue(systemd_broker(run, units))
            self.assertFalse(systemd_broker(Path(tmp) / "no-systemd", units))  # no systemd running

    def test_start_gpu_defers_to_systemd(self):
        body = subprocess.run(["sed", "-n", "/^start_gpu()/,/^}/p", str(SCRIPT)], capture_output=True, text=True, check=True).stdout
        self.assertIn("systemd_broker && return", body)
        self.assertLess(body.index("systemd_broker && return"), body.index("supervise caboose-gpu-broker"))


if __name__ == "__main__":
    unittest.main()
