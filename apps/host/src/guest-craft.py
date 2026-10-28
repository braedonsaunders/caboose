"""Run one host-whitelisted operation as the guest owner, in a staged job directory."""
import json, os, signal, stat, subprocess, sys, tempfile, time


def execute(request, root='/home/caboose'):
    directory = os.path.join(root, '.caboose-jobs', request['job'])
    # The host validates every name and job id. Reject symlinked directories and inputs too.
    for path in (os.path.join(root, '.caboose-jobs'), directory):
        mode = os.lstat(path).st_mode
        if not stat.S_ISDIR(mode) or stat.S_ISLNK(mode):
            raise ValueError('invalid job directory')
    inputs = [os.path.join(directory, name) for name in request['inputs']]
    for path in inputs:
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ValueError('invalid input file')
    app = request['app']
    commands = []
    outputs = []
    count = len(inputs) if app == 'photocraft' else 1
    for index in range(count):
        output_name = 'output-' + str(index) + '.' + request['format']
        output = os.path.join(directory, output_name)
        if os.path.lexists(output):
            raise ValueError('output already exists')
        if app == 'photocraft':
            command = ['/usr/bin/photocraft-cli', 'convert', inputs[index], output]
        elif app == 'pdfcraft':
            command = ['/usr/bin/pdfcraft-cli', 'combine', *inputs, '--out', output]
        elif app == 'lightcraft':
            command = ['/usr/bin/lightcraft-cli', 'render', inputs[0], '-o', output]
        elif app == 'filmcraft':
            command = ['/usr/bin/filmcraft-cli', '--project', inputs[0], 'export', output]
        else:
            raise ValueError('invalid app')
        commands.append((command, output, output_name))
    warnings = []
    deadline = time.monotonic() + 3450
    for command, output, output_name in commands:
        # Keep verbose encoders from accumulating unbounded output in memory. Kill the
        # whole child process group on timeout, including an encoder started by the CLI.
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Craft operation timed out')
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen(['/usr/sbin/runuser', '-u', 'caboose', '--', *command], cwd=directory, stdout=log, stderr=log, start_new_session=True)
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise RuntimeError('Craft operation timed out')
            log.seek(0, os.SEEK_END)
            size = log.tell()
            log.seek(max(0, size - 4000))
            detail = log.read().decode('utf-8', errors='replace').strip()
        if code:
            raise RuntimeError((detail or 'Craft command failed')[-1000:])
        if detail:
            warnings.append(detail[-1000:])
        if not os.path.isfile(output) or os.path.islink(output):
            raise RuntimeError('Craft did not produce the expected file')
        outputs.append('.caboose-jobs/' + request['job'] + '/' + output_name)
    return {'outputs': outputs, 'warnings': warnings}


if __name__ == '__main__':
    print(json.dumps(execute(json.loads(sys.argv[1]))))
