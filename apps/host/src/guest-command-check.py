import base64, importlib.util, json, os, sys, tempfile, threading, time, unittest
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('guest_command', os.path.join(os.path.dirname(__file__), 'guest-command.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

ID = '0123456789abcdef0123456789abcdef'


def request(**changes):
    value = {'id': ID, 'cwd': None, 'timeout': 30, 'stdin': False, 'inputs': []}
    value.update(changes)
    return value


class GuestCommandTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = self.temporary.name
        self.job = os.path.join(self.root, '.caboose-jobs', 'cmd-' + ID)
        self.limit = module.LIMIT

    def tearDown(self):
        module.LIMIT = self.limit
        self.temporary.cleanup()

    def stage(self, script, stdin=None):
        module.prepare({'id': ID}, self.root)
        with open(os.path.join(self.job, 'command.sh'), 'w') as file:
            file.write(script)
        if stdin is not None:
            with open(os.path.join(self.job, 'stdin'), 'wb') as file:
                file.write(stdin)

    def run_command(self, script, stdin=None, **changes):
        self.stage(script, stdin)
        module.supervise(self.job, self.job, request(stdin=stdin is not None, **changes), self.root, poll_interval=0.05, grace=0.2)
        return module.result({'id': ID}, self.root)

    def test_prepare_creates_the_job_once_and_refuses_symlinks(self):
        self.assertEqual(module.prepare({'id': ID}, self.root), {})
        self.assertTrue(os.path.isdir(os.path.join(self.job, 'in')) and os.path.isdir(os.path.join(self.job, 'out')))
        self.assertEqual(module.prepare({'id': ID}, self.root), {})
        open(os.path.join(self.job, 'command.sh'), 'w').close()
        with self.assertRaisesRegex(module.Refused, 'already exists'):
            module.prepare({'id': ID}, self.root)
        with self.assertRaisesRegex(module.Refused, 'invalid command id'):
            module.prepare({'id': '../x'}, self.root)
        other = tempfile.mkdtemp(dir=self.root)
        os.rename(os.path.join(self.root, '.caboose-jobs'), os.path.join(self.root, 'moved'))
        os.symlink(other, os.path.join(self.root, '.caboose-jobs'))
        with self.assertRaisesRegex(module.Refused, 'invalid job directory'):
            module.prepare({'id': ID}, self.root)

    def test_start_checks_staged_files_and_records_the_supervisor(self):
        self.stage('true\n')
        with self.assertRaisesRegex(module.Refused, 'input file not found: a.txt'):
            module.start(request(inputs=['a.txt']), self.root, launch=lambda: 4242)
        os.symlink('/etc/passwd', os.path.join(self.job, 'in', 'a.txt'))
        with self.assertRaisesRegex(module.Refused, 'input file not found'):
            module.start(request(inputs=['a.txt']), self.root, launch=lambda: 4242)
        with self.assertRaisesRegex(module.Refused, 'input is missing'):
            module.start(request(stdin=True), self.root, launch=lambda: 4242)
        with self.assertRaisesRegex(module.Refused, 'working directory'):
            module.start(request(cwd='missing'), self.root, launch=lambda: 4242)
        self.assertEqual(module.start(request(cwd=''), self.root, launch=lambda: 4242), {'pid': 4242})
        with open(os.path.join(self.job, 'pid')) as file:
            self.assertEqual(file.read(), '4242')
        with self.assertRaisesRegex(module.Refused, 'already started'):
            module.start(request(), self.root, launch=lambda: 4242)

    def test_runs_a_login_shell_with_stdin_inputs_and_outputs(self):
        script = 'cat > "$CABOOSE_OUT/copy.txt"\necho "out $CABOOSE_COMMAND_ID $(basename "$PWD")"\necho err >&2\nmkdir "$CABOOSE_OUT/folder"\nln -s /etc/passwd "$CABOOSE_OUT/link"\nexit 3\n'
        result = self.run_command(script, stdin=b'hello')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['exitCode'], 3)
        self.assertIsNone(result['signal'])
        self.assertEqual(result['outputs'], ['copy.txt'])
        self.assertEqual(result['truncated'], {'stdout': False, 'stderr': False})
        with open(os.path.join(self.job, 'out', 'copy.txt'), 'rb') as file:
            self.assertEqual(file.read(), b'hello')
        stdout = base64.b64decode(module.read({'id': ID, 'stream': 'stdout'}, self.root))
        self.assertEqual(stdout, ('out ' + ID + ' cmd-' + ID + '\n').encode())
        self.assertEqual(base64.b64decode(module.read({'id': ID, 'stream': 'stderr'}, self.root)), b'err\n')
        self.assertEqual(module.poll({'ids': [ID, 'f' * 32]}, self.root), {ID: 'done', 'f' * 32: 'gone'})
        self.assertEqual(module.cancel({'id': ID}, self.root), {'finished': True})

    def test_keeps_the_head_of_stdout_and_the_tail_of_stderr(self):
        module.LIMIT = 8
        result = self.run_command('printf 0123456789\nprintf abcdefghij >&2\n')
        self.assertEqual(result['status'], 'succeeded')
        self.assertEqual(result['truncated'], {'stdout': True, 'stderr': True})
        self.assertEqual(base64.b64decode(module.read({'id': ID, 'stream': 'stdout'}, self.root)), b'01234567')
        self.assertEqual(base64.b64decode(module.read({'id': ID, 'stream': 'stderr'}, self.root)), b'cdefghij')

    def test_times_out_and_stops_what_the_script_left_behind(self):
        started = time.monotonic()
        result = self.run_command('trap "" TERM\nsleep 30\n', timeout=1)
        self.assertEqual(result['status'], 'timed-out')
        self.assertLess(time.monotonic() - started, 10)
        started = time.monotonic()
        result = self.run_command_again('sleep 30 &\necho done\n')
        self.assertEqual(result['status'], 'succeeded')
        self.assertLess(time.monotonic() - started, 4)

    def run_command_again(self, script):
        self.temporary.cleanup()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = self.temporary.name
        self.job = os.path.join(self.root, '.caboose-jobs', 'cmd-' + ID)
        return self.run_command(script)

    def test_cancel_stops_a_running_command(self):
        self.stage('sleep 30\n')
        def later():
            time.sleep(0.3)
            self.assertEqual(module.cancel({'id': ID}, self.root), {'finished': False})
        thread = threading.Thread(target=later)
        thread.start()
        module.supervise(self.job, self.job, request(), self.root, poll_interval=0.05, grace=0.2)
        thread.join()
        result = module.result({'id': ID}, self.root)
        self.assertEqual(result['status'], 'cancelled')
        self.assertIsNone(result['exitCode'])
        self.assertEqual(result['signal'], 'SIGTERM')


if __name__ == '__main__':
    unittest.main()
