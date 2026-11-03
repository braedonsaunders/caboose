import os, stat, tempfile, unittest, importlib.util
spec = importlib.util.spec_from_file_location('launcher', os.path.join(os.path.dirname(__file__), 'launcher.py'))
launcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(launcher)


class Plan(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.environ['PATH']
        os.environ['PATH'] = self.dir + ':' + self.path

    def tearDown(self):
        os.environ['PATH'] = self.path

    def program(self, name, body=b'\x7fELF', files=()):
        sub = os.path.join(self.dir, name + '.d'); os.makedirs(sub, exist_ok=True)
        path = os.path.join(sub, name)
        with open(path, 'wb') as f: f.write(body)
        os.chmod(path, 0o755)
        for extra in files: open(os.path.join(sub, extra), 'w').close()
        link = os.path.join(self.dir, name)
        os.symlink(path, link)
        return path

    def test_a_chromium_build_gets_renderer_accessibility(self):
        self.program('browser', files=['resources.pak'])
        self.assertEqual(launcher.plan('browser https://example.com'), ['browser', '--force-renderer-accessibility', 'https://example.com'])

    def test_a_wrapper_script_is_followed_to_its_program(self):
        real = self.program('editor-bin', files=['v8_context_snapshot.bin'])
        self.program('editor', body=f'#!/bin/sh\nexec "{real}" "$@"\n'.encode())
        self.assertEqual(launcher.plan('editor notes.md')[:2], ['editor', '--force-renderer-accessibility'])

    def test_a_wrapper_naming_its_program_directory_is_followed(self):
        lib = os.path.join(self.dir, 'lib'); os.makedirs(lib); open(os.path.join(lib, 'resources.pak'), 'w').close()
        self.program('chromium', body=f'#!/bin/sh\nLIBDIR={lib}\nexec $LIBDIR/chromium "$@"\n'.encode())
        self.assertEqual(launcher.plan('chromium')[1], '--force-renderer-accessibility')

    def test_other_programs_and_shell_lines_start_as_asked(self):
        self.program('mousepad')
        self.assertEqual(launcher.plan('mousepad a.txt'), ['mousepad', 'a.txt'])
        self.assertIsNone(launcher.plan('mousepad a.txt && echo done'))
        self.assertEqual(launcher.plan('browser --force-renderer-accessibility'), ['browser', '--force-renderer-accessibility'])


if __name__ == '__main__':
    unittest.main()
