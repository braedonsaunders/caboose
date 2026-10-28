import importlib.util, io, json, os, sys, tempfile, unittest
sys.dont_write_bytecode = True
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guest_craft', os.path.join(os.path.dirname(__file__), 'guest-craft.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class GuestCraftTest(unittest.TestCase):
    def test_fixed_vectors_and_output_validation(self):
        with tempfile.TemporaryDirectory() as root:
            job = '0123456789abcdef0123456789abcdef'
            directory = os.path.join(root, '.caboose-jobs', job)
            os.makedirs(directory)
            for name in ['input-0.pdf', 'input-1.pdf']:
                open(os.path.join(directory, name), 'wb').close()
            commands = []
            class Process:
                pid = 1
                stdout = io.BytesIO()
                def wait(self, timeout=None): return 0
            def spawn(args, **kwargs):
                commands.append(args)
                open(args[-1], 'wb').close()
                return Process()
            with patch.object(module.subprocess, 'Popen', spawn):
                result = module.execute({'job': job, 'app': 'pdfcraft', 'format': 'pdf', 'inputs': ['input-0.pdf', 'input-1.pdf']}, root)
            self.assertEqual(commands[0][:5], ['/usr/sbin/runuser', '-u', 'caboose', '--', '/usr/bin/pdfcraft-cli'])
            self.assertEqual(commands[0][5], 'combine')
            self.assertEqual(result['outputs'], [f'.caboose-jobs/{job}/output-0.pdf'])
            with self.assertRaisesRegex(ValueError, 'output already exists'):
                module.execute({'job': job, 'app': 'pdfcraft', 'format': 'pdf', 'inputs': ['input-0.pdf', 'input-1.pdf']}, root)
            os.unlink(os.path.join(directory, 'output-0.pdf'))
            os.unlink(os.path.join(directory, 'input-0.pdf'))
            os.symlink('/etc/passwd', os.path.join(directory, 'input-0.pdf'))
            with self.assertRaisesRegex(ValueError, 'invalid input'):
                module.execute({'job': job, 'app': 'pdfcraft', 'format': 'pdf', 'inputs': ['input-0.pdf', 'input-1.pdf']}, root)

if __name__ == '__main__': unittest.main()
