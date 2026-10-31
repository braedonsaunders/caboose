"""Run a command for the computer's owner in a job directory, detached from the host.

The host passes one mode and one JSON argument, every field of which it has validated:

  prepare {id}                          create .caboose-jobs/cmd-<id>/ with in/ and out/
  start {id, cwd, timeout, stdin, inputs}
                                        check the staged files and start the supervisor
  poll {ids}                            {id: "running" | "done" | "gone"} for each command
  result {id}                           the supervisor's result record
  read {id, stream}                     base64 of the kept stdout or stderr
  cancel {id}                           ask the supervisor to stop the command

The script itself is never an argument: the host writes it to command.sh (and any stdin to
stdin) through the file service. The host runs `start` as caboose through runuser; the other
modes start as root and drop to caboose before touching the home. A refused request exits 2
with `caboose-command input: …` or `caboose-command conflict: …` on stderr.
"""
import base64, json, os, pwd, re, signal, stat, subprocess, sys, threading, time

ROOT = '/home/caboose'
JOBS = '.caboose-jobs'
# Each stream keeps this much: stdout its first bytes, stderr its last.
LIMIT = 1024 * 1024
MAX_OUTPUTS = 100
# How long a cancelled or timed-out command has between SIGTERM and SIGKILL.
GRACE = 5
CONTROL = re.compile('[\x00-\x1f\x7f]')


class Refused(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def owner():
    """Drop root to the owner; nothing to do when already running as caboose."""
    if os.geteuid() != 0:
        return
    entry = pwd.getpwnam('caboose')
    os.initgroups('caboose', entry.pw_gid)
    os.setgid(entry.pw_gid)
    os.setuid(entry.pw_uid)


def job_name(identifier):
    if not isinstance(identifier, str) or not re.fullmatch('[0-9a-f]{32}', identifier):
        raise Refused('input', 'invalid command id')
    return 'cmd-' + identifier


def open_directory(root, parts, create=False):
    """Open root/parts… one component at a time without following symlinks."""
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                raise
            except OSError as error:
                # A symlink (ELOOP) or a file (ENOTDIR) where a directory belongs.
                raise Refused('input', 'invalid job directory') from error
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def lexists(name, fd):
    try:
        os.stat(name, dir_fd=fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def regular(name, fd):
    try:
        return stat.S_ISREG(os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode)
    except FileNotFoundError:
        return False


def read_file(name, fd, limit):
    """At most `limit` bytes of a regular file in fd; None when it is missing."""
    try:
        file = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    except FileNotFoundError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(file).st_mode):
            raise Refused('input', 'invalid job file')
        chunks, size = [], 0
        while size < limit:
            chunk = os.read(file, min(65536, limit - size))
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return b''.join(chunks)
    finally:
        os.close(file)


def write_file(name, fd, data):
    """Replace a file in fd atomically, never through a symlink."""
    temporary = '.' + name + '.tmp'
    try:
        os.unlink(temporary, dir_fd=fd)
    except FileNotFoundError:
        pass
    file = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        os.write(file, data)
        os.fsync(file)
    finally:
        os.close(file)
    os.rename(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)


def plain_name(name):
    if not name or name in ('.', '..') or '/' in name or CONTROL.search(name) or name.startswith('.caboose-upload-'):
        return False
    try:
        return len(name.encode('utf-8')) <= 255
    except UnicodeEncodeError:
        return False


def prepare(request, root=ROOT):
    fd = open_directory(root, [JOBS, job_name(request['id'])], create=True)
    try:
        for name in ('in', 'out'):
            try:
                os.mkdir(name, 0o700, dir_fd=fd)
            except FileExistsError:
                pass
            if not stat.S_ISDIR(os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode):
                raise Refused('input', 'invalid job directory')
        for name in ('command.sh', 'stdin', 'pid', 'result.json'):
            if lexists(name, fd):
                raise Refused('conflict', 'a command with this id already exists')
    finally:
        os.close(fd)
    return {}


def environment(job, identifier, root):
    uid = os.getuid()
    env = {
        'HOME': root, 'USER': 'caboose', 'LOGNAME': 'caboose', 'SHELL': '/bin/bash', 'LANG': 'C.UTF-8',
        'PATH': root + '/.local/bin:/usr/local/bin:/usr/bin:/bin',
        'XDG_RUNTIME_DIR': '/run/user/' + str(uid),
        'CABOOSE_COMMAND_ID': identifier, 'CABOOSE_JOB': job,
        'CABOOSE_IN': job + '/in', 'CABOOSE_OUT': job + '/out',
    }
    if os.path.exists('/run/user/' + str(uid) + '/bus'):
        env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=/run/user/' + str(uid) + '/bus'
    return env


def start(request, root=ROOT, launch=None):
    identifier = request['id']
    job = os.path.join(root, JOBS, job_name(identifier))
    fd = open_directory(root, [JOBS, job_name(identifier)])
    try:
        if not regular('command.sh', fd):
            raise Refused('input', 'the command script is missing')
        if request['stdin'] and not regular('stdin', fd):
            raise Refused('input', 'the command input is missing')
        for name in ('pid', 'result.json', 'cancel'):
            if lexists(name, fd):
                raise Refused('conflict', 'this command has already started')
        inputs = open_directory(job, ['in'])
        try:
            for name in request['inputs']:
                if not plain_name(name) or not regular(name, inputs):
                    raise Refused('input', 'input file not found: ' + name)
        finally:
            os.close(inputs)
        os.close(open_directory(job, ['out']))
        cwd = job if request['cwd'] is None else os.path.join(root, request['cwd'])
        if not os.path.isdir(cwd):
            raise Refused('input', 'the working directory does not exist')
        sys.stdout.flush()
        sys.stderr.flush()
        pid = os.fork() if launch is None else launch()
        if pid == 0:
            # The supervisor: its own session, so the host's command channel can end.
            code = 0
            try:
                os.setsid()
                null = os.open(os.devnull, os.O_RDWR)
                for target in (0, 1, 2):
                    os.dup2(null, target)
                supervise(job, cwd, request, root)
            except BaseException:
                code = 1
            finally:
                os._exit(code)
        write_file('pid', fd, str(pid).encode())
    finally:
        os.close(fd)
    return {'pid': pid}


def signal_group(pgid, number):
    try:
        os.killpg(pgid, number)
    except (ProcessLookupError, PermissionError):
        pass


def supervise(job, cwd, request, root=ROOT, poll_interval=0.5, grace=GRACE):
    """Run command.sh in a login shell, keep bounded output, and record how it ended."""
    fd = open_directory(job, [])
    try:
        deadline = time.monotonic() + request['timeout']
        truncated = {'stdout': False, 'stderr': False}
        tail = bytearray()
        stdin = open(os.path.join(job, 'stdin'), 'rb') if request['stdin'] else open(os.devnull, 'rb')
        try:
            process = subprocess.Popen(['/bin/bash', '--login', os.path.join(job, 'command.sh')], cwd=cwd,
                                       env=environment(job, request['id'], root), stdin=stdin,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        except OSError as error:
            finish(fd, job, {'status': 'failed', 'exitCode': None, 'signal': None, 'error': ('Could not start bash: ' + str(error))[:500]}, truncated)
            return
        finally:
            stdin.close()

        def keep_head():
            out = os.open('stdout', os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            kept = 0
            try:
                while chunk := process.stdout.read1(65536):
                    part = chunk[:max(0, LIMIT - kept)]
                    if part:
                        os.write(out, part)
                        kept += len(part)
                    if len(part) < len(chunk):
                        truncated['stdout'] = True
            finally:
                os.close(out)

        def keep_tail():
            while chunk := process.stderr.read1(65536):
                tail.extend(chunk)
                if len(tail) > LIMIT:
                    del tail[:-LIMIT]
                    truncated['stderr'] = True

        readers = [threading.Thread(target=keep_head, daemon=True), threading.Thread(target=keep_tail, daemon=True)]
        for reader in readers:
            reader.start()
        stopped, killed_at = None, None
        while True:
            try:
                code = process.wait(timeout=poll_interval)
                break
            except subprocess.TimeoutExpired:
                pass
            now = time.monotonic()
            if stopped is None:
                if lexists('cancel', fd):
                    stopped = 'cancelled'
                elif now >= deadline:
                    stopped = 'timed-out'
                if stopped:
                    signal_group(process.pid, signal.SIGTERM)
                    killed_at = now + grace
            elif now >= killed_at:
                signal_group(process.pid, signal.SIGKILL)
        # Whatever the script left running in its process group ends with it.
        signal_group(process.pid, signal.SIGKILL)
        for reader in readers:
            reader.join(timeout=5)
        # A process that left the group can still hold a pipe; never block on its reader.
        if not any(reader.is_alive() for reader in readers):
            process.stdout.close()
            process.stderr.close()
        write_file('stderr', fd, bytes(tail))
        if stopped:
            outcome = {'status': stopped}
        elif code == 0:
            outcome = {'status': 'succeeded'}
        else:
            outcome = {'status': 'failed'}
        outcome['exitCode'] = code if code >= 0 else None
        outcome['signal'] = signal.Signals(-code).name if code < 0 and -code in signal.valid_signals() else None
        outcome['error'] = None
        finish(fd, job, outcome, truncated)
    finally:
        os.close(fd)


def outputs(job):
    """The top-level regular files in out/, by name, at most MAX_OUTPUTS."""
    try:
        fd = open_directory(job, ['out'])
    except (FileNotFoundError, Refused):
        return []
    try:
        with os.scandir(fd) as entries:
            names = sorted(entry.name for entry in entries if entry.is_file(follow_symlinks=False) and plain_name(entry.name))
    finally:
        os.close(fd)
    return names[:MAX_OUTPUTS]


def finish(fd, job, outcome, truncated):
    record = dict(outcome)
    record['truncated'] = dict(truncated)
    record['outputs'] = outputs(job)
    record['finishedAt'] = int(time.time() * 1000)
    write_file('result.json', fd, json.dumps(record).encode())


def alive(fd, identifier):
    data = read_file('pid', fd, 32)
    if not data or not data.strip().isdigit():
        return False
    try:
        with open('/proc/' + data.strip().decode() + '/cmdline', 'rb') as file:
            # The supervisor is a fork of `start`, whose arguments name this command.
            return identifier.encode() in file.read(1 << 20)
    except OSError:
        return False


def poll(request, root=ROOT):
    states = {}
    for identifier in request['ids']:
        try:
            fd = open_directory(root, [JOBS, job_name(identifier)])
        except (FileNotFoundError, Refused):
            states[identifier] = 'gone'
            continue
        try:
            if regular('result.json', fd):
                states[identifier] = 'done'
            elif alive(fd, identifier):
                states[identifier] = 'running'
            else:
                # It may have written its result between the two checks.
                states[identifier] = 'done' if regular('result.json', fd) else 'gone'
        finally:
            os.close(fd)
    return states


def result(request, root=ROOT):
    fd = open_directory(root, [JOBS, job_name(request['id'])])
    try:
        data = read_file('result.json', fd, 65536)
    finally:
        os.close(fd)
    if data is None:
        raise Refused('conflict', 'the command has no result')
    return json.loads(data)


def read(request, root=ROOT):
    if request['stream'] not in ('stdout', 'stderr'):
        raise Refused('input', 'invalid stream')
    fd = open_directory(root, [JOBS, job_name(request['id'])])
    try:
        data = read_file(request['stream'], fd, LIMIT) or b''
    finally:
        os.close(fd)
    return base64.b64encode(data).decode()


def cancel(request, root=ROOT):
    fd = open_directory(root, [JOBS, job_name(request['id'])])
    try:
        if regular('result.json', fd):
            return {'finished': True}
        if not lexists('cancel', fd):
            os.close(os.open('cancel', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=fd))
        return {'finished': False}
    finally:
        os.close(fd)


MODES = {'prepare': prepare, 'start': start, 'poll': poll, 'result': result, 'read': read, 'cancel': cancel}

if __name__ == '__main__':
    try:
        owner()
        handler = MODES[sys.argv[1]]
        answer = handler(json.loads(sys.argv[2]))
    except Refused as refused:
        print('caboose-command ' + refused.kind + ': ' + str(refused), file=sys.stderr)
        sys.exit(2)
    print(answer if isinstance(answer, str) else json.dumps(answer))
