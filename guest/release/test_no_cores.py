"""The release's checks start no program that can leave a core dump: python3 -m unittest guest/release/test_no_cores.py"""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
EXECUTOR = REPO / "apps/ios/GPUStream/gfxstream/linux-executor"
SHELL = sorted(EXECUTOR.glob("check*.sh")) + [REPO / "guest/release/check-packaged.sh", REPO / "guest/release/prepare-check-home.sh"]
PYTHON = [EXECUTOR / "check_chaos.py", REPO / "guest/release/caboose-release"]


class NoCores(unittest.TestCase):
    def test_every_shell_check_turns_core_dumps_off_for_itself_its_containers_and_the_computer(self):
        for path in SHELL:
            text = path.read_text()
            with self.subTest(path=path.name):
                self.assertRegex(text, r"(?m)^ulimit -c 0$")
                self.assertIn("command docker run --ulimit core=0", text)
                self.assertIn("prlimit --core=0:0 --", text)
                # The wrapper comes before the first docker call.
                first = re.search(r"(?m)^[^#\n]*\bdocker (run|exec)\b", text.split("docker() {", 1)[1].split("\n}\n", 1)[1])
                self.assertIsNotNone(first)
                self.assertLess(text.index("docker() {"), text.index(first.group(0)))

    def test_every_python_check_turns_core_dumps_off(self):
        for path in PYTHON:
            with self.subTest(path=path.name):
                self.assertIn("resource.setrlimit(resource.RLIMIT_CORE, (0, 0))", path.read_text())
        chaos = (EXECUTOR / "check_chaos.py").read_text()
        self.assertIn("*NO_CORES, 'sh', '-c'", chaos)
        for call in re.findall(r"run\('docker', 'run',[^)]*", chaos):
            self.assertIn("'--ulimit', 'core=0'", call)


if __name__ == "__main__":
    unittest.main()
