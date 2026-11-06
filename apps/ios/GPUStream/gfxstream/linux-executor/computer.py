#!/usr/bin/env python3
"""The checks' way into a computer: a container (by name, through Docker) or a virtual machine
(vm:ID, through the host's operator routes, POST /v1/host/computers/ID/exec and PUT
/v1/host/computers/ID/file, with caboose-release's client and host settings).

  computer.py docker ARGS...   the subset of `docker` the checks use: `exec [-d] [-i] [-u USER]
                               [-e K=V] [-w DIR] TARGET COMMAND...` and `cp [-q] SOURCE TARGET:PATH`.
                               With a vm: target they run in the guest, anything else is Docker's.
  computer.py hold TARGET      keeps a virtual machine awake until ended: the host freezes a
                               computer 3 s after its last lease goes, and an exec holds one only
                               for its own request, so a check's program between two commands
                               would be frozen. A control connection (/v1/control) holds a lease
                               for as long as it is open; it reconnects if the host closes it.
                               For a container it returns at once.
  computer.py net TARGET       how an executor container on this host reaches a server the checks
                               start in TARGET, as three words: the `docker run --network` value,
                               the address to connect to and the address that server listens on.
                               A container shares its network (container:NAME, 127.0.0.1, 127.0.0.1);
                               a virtual machine is reached at its own address (host, the guest's
                               address, 0.0.0.0).

The checks' shell scripts route their `docker` calls through `docker` here when their computer
is vm:ID, so they read the same for both; check_chaos.py calls it directly. A detached command
(-d) is started in its own session and left running; standard input (-i) is written to a file
in the guest first. Commands run as root unless -u names a user (runuser)."""
import base64
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
RELEASE_TOOL = HERE.parents[4] / "guest/release/caboose-release"


def release_tool():
    loader = importlib.machinery.SourceFileLoader("caboose_release", str(RELEASE_TOOL))
    spec = importlib.util.spec_from_loader("caboose_release", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def vm(target):
    """The virtual machine named by TARGET (vm:ID)."""
    return release_tool().VirtualMachine(target[3:])


def real_docker():
    """Docker's own command, past any `docker` of these checks earlier on PATH."""
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / "docker"
        if candidate.is_file() and os.access(candidate, os.X_OK) and candidate.resolve() != Path(__file__).resolve() \
                and Path(directory).resolve() != (HERE / "computer-bin").resolve():
            return str(candidate)
    return "docker"


# Everything a check runs in a virtual machine runs in one cgroup slice of its own, capped, so
# the checks can never take the guest's (or the host's) memory from the owner's session: an
# out-of-memory there ends a check's process, never the owner's.
CHECK_SLICE = "caboose-check.slice"
CHECK_LIMITS = os.environ.get("CABOOSE_CHECK_LIMITS", "MemoryMax=4G MemorySwapMax=0 CPUQuota=400% CPUWeight=1")


def guest_command(argv, env=(), workdir=None, stdin_path=None):
    """The shell command running ARGV in the guest as `docker exec` would (its user aside)."""
    command = shlex.join(["env", *env, *argv]) if env else shlex.join(argv)
    if workdir:
        command = f"cd {shlex.quote(workdir)} && {command}"
    if stdin_path:
        command = f"{command} < {shlex.quote(stdin_path)}"
    return command


def runner(job, user=None, detach=False):
    """The shell that runs job JOB's command (JOB.sh) in the checks' capped slice, at the lowest
    priority, without core dumps, as USER if given. Only the job's file names appear on any
    command line, never the command: a check's `pkill -f PATTERN` would otherwise match the
    wrapper running it and end itself. It records its pid (JOB.pid) and, unless detached, the
    command's output (JOB.out, JOB.err) and exit status (JOB.rc, written last)."""
    as_user = f"runuser -u {shlex.quote(user)} -- " if user else ""
    run = (f"systemd-run --quiet --scope --collect --slice={CHECK_SLICE} -- prlimit --core=0:0 -- nice -n 19 "
           f"{as_user}/bin/sh {job}.sh")
    head = f"echo $$ > {job}.pid; systemctl set-property --runtime {CHECK_SLICE} {CHECK_LIMITS} > /dev/null 2>&1; "
    if detach:
        return head + f"{run} < /dev/null > /dev/null 2>&1; rm -f {job}.sh {job}.pid"
    return head + f"{run} < /dev/null > {job}.out 2> {job}.err; echo $? > {job}.part; mv {job}.part {job}.rc"


def run_exec(args, stdin=None):
    """`docker exec`: the exit status, with the command's output written through."""
    detach = interactive = False
    user, workdir, env = None, None, []
    i = 0
    while i < len(args) and args[i].startswith("-"):
        option = args[i]
        if option in ("-d", "--detach"):
            detach = True
        elif option in ("-i", "--interactive"):
            interactive = True
        elif option in ("-t", "-it", "-ti"):
            interactive = interactive or "i" in option
        elif option in ("-u", "--user"):
            i += 1; user = args[i]
        elif option in ("-e", "--env"):
            i += 1; env.append(args[i])
        elif option in ("-w", "--workdir"):
            i += 1; workdir = args[i]
        else:
            raise SystemExit(f"computer.py: unsupported docker exec option {option}")
        i += 1
    target, argv = args[i], args[i + 1:]
    machine = vm(target)
    job = f"/var/tmp/caboose-check-job-{uuid.uuid4().hex}"
    stdin_path = None
    if interactive and not detach:
        data = (stdin if stdin is not None else sys.stdin.buffer).read()
        stdin_path = f"{job}.in"
        machine.put(stdin_path, data, 0o644)
    command = guest_command(argv, env=env, workdir=workdir, stdin_path=stdin_path)
    machine.put(f"{job}.sh", f"{command}\n".encode(), 0o644)
    machine.run("/bin/sh", "-c", f"setsid /bin/sh -c {shlex.quote(runner(job, user, detach))} < /dev/null > /dev/null 2>&1 &",
                timeout=60)
    if detach:
        return 0
    status, out, err = wait_for_job(machine, job)
    sys.stdout.write(out)
    sys.stdout.flush()
    sys.stderr.write(err)
    return status


def wait_for_job(machine, job):
    """Polls job JOB to its end: the host's exec route serves one guest command at a time, so a
    long one (a program a check runs for a minute) held directly would hold every other command
    of the checks behind it. Its exit status (137 if the job's runner itself was ended),
    standard output and error; its files are removed."""
    delay = 0.05
    while True:
        state = machine.run("/bin/sh", "-c", f"test -f {job}.rc && exit 0; p=$(cat {job}.pid 2>/dev/null) || exit 1; "
                            f"kill -0 \"$p\" 2>/dev/null && exit 1; exit 2", timeout=60, check=False).get("exitCode")
        if state in (0, 2):
            break
        time.sleep(delay)
        delay = min(delay * 2, 1.0)
    result = machine.run("/bin/sh", "-c", f"[ ! -f {job}.out ] || cat {job}.out; [ ! -f {job}.err ] || cat {job}.err >&2; "
                         f"status=$(cat {job}.rc 2>/dev/null || echo 137); rm -f {job}.*; exit $status",
                         timeout=120, check=False)
    return int(result.get("exitCode", 1)), result.get("stdout", ""), result.get("stderr", "")


def run_cp(args):
    """`docker cp SOURCE vm:ID:PATH`: SOURCE (a file or a directory) into the guest at PATH, as
    Docker does: into PATH when it is a directory, else as PATH."""
    args = [a for a in args if a not in ("-q", "--quiet", "-a", "--archive")]
    source, target = args
    if not target.startswith("vm:"):
        raise SystemExit("computer.py: copies out of a virtual machine are not supported")
    name, _, path = target[3:].partition(":")
    machine = vm(f"vm:{name}")
    source = Path(source)
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        tar.add(str(source), arcname=source.name)
    staged = f"/var/tmp/caboose-check-copy-{uuid.uuid4().hex}.tar"
    machine.put(staged, archive.getvalue(), 0o600)
    quoted, base = shlex.quote(path.rstrip("/") or "/"), shlex.quote(source.name)
    script = (f"set -e; t={quoted}; if [ -d \"$t\" ]; then tar -C \"$t\" --no-same-owner -xf {staged}; "
              f"else d=$(mktemp -d); tar -C \"$d\" --no-same-owner -xf {staged}; mkdir -p \"$(dirname \"$t\")\"; "
              f"rm -rf \"$t\"; mv \"$d\"/{base} \"$t\"; rm -rf \"$d\"; fi; rm -f {staged}")
    result = machine.run("/bin/sh", "-c", script, timeout=600, check=False)
    sys.stderr.write(result.get("stderr", ""))
    return int(result.get("exitCode", 1))


def network(target):
    """(docker run --network, connect address, listen address) for a server in TARGET."""
    if not target.startswith("vm:"):
        return f"container:{target}", "127.0.0.1", "127.0.0.1"
    address = os.environ.get("CABOOSE_VM_ADDRESS")
    if not address:
        result = vm(target).run("/bin/sh", "-c",
                                "ip -4 -o addr show scope global | grep -v -E ' (docker|br-|veth)' | awk '{print $4}' | cut -d/ -f1 | head -1",
                                timeout=60)
        address = result.get("stdout", "").strip()
    if not address:
        raise SystemExit(f"computer.py: no address for {target}")
    return "host", address, "0.0.0.0"


def hold(target, rounds=None):
    """Holds a control connection to the host (a lease on its computer) until killed; ROUNDS
    connections at most, for tests."""
    if not target.startswith("vm:"):
        return 0
    machine = vm(target)
    url = urllib.parse.urlsplit(machine.url)
    host, port = url.hostname, url.port or (443 if url.scheme == "https" else 80)
    path = (url.path.rstrip("/") or "") + "/v1/control"
    count = 0
    while rounds is None or count < rounds:
        count += 1
        try:
            with socket.create_connection((host, port), timeout=30) as sock:
                key = base64.b64encode(os.urandom(16)).decode()
                sock.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                              f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                              f"Authorization: Bearer {machine.token}\r\n\r\n").encode())
                head = b""
                while b"\r\n\r\n" not in head:
                    data = sock.recv(4096)
                    if not data:
                        raise ConnectionError("closed during the upgrade")
                    head += data
                if head.startswith(b"HTTP/1.1 409"):
                    # Parked: booted (POST /v1/computers/ID/boot), then held again.
                    boot(machine)
                    raise ConnectionError("parked; booting it")
                if not head.startswith(b"HTTP/1.1 101"):
                    raise ConnectionError(head.split(b"\r\n", 1)[0].decode(errors="replace"))
                print(f"holding {target}", flush=True)
                sock.settimeout(None)
                buffer = head.split(b"\r\n\r\n", 1)[1]
                while True:
                    frame = read_frame(sock, buffer)
                    if frame is None:
                        break
                    opcode, payload, buffer = frame
                    if opcode == 0x9:  # ping: answer, or the host drops the lease
                        sock.sendall(client_frame(0xA, payload))
                    elif opcode == 0x8:
                        break
        except OSError as error:
            print(f"hold {target}: {error}", file=sys.stderr, flush=True)
        if rounds is None or count < rounds:
            time.sleep(2)
    return 0


def boot(machine):
    """Boots a parked virtual machine through the host."""
    request = urllib.request.Request(f"{machine.url}/v1/computers/{urllib.parse.quote(machine.name)}/boot", data=b"{}",
                                     method="POST", headers={"Authorization": f"Bearer {machine.token}",
                                                             "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=300).read()
    except OSError as error:
        print(f"boot {machine.name}: {error}", file=sys.stderr, flush=True)


def read_frame(sock, buffer):
    """One WebSocket frame from SOCK (after BUFFER): (opcode, payload, rest), or None at its end."""
    def need(n):
        nonlocal buffer
        while len(buffer) < n:
            data = sock.recv(65536)
            if not data:
                return False
            buffer += data
        return True
    if not need(2):
        return None
    opcode, length = buffer[0] & 0x0F, buffer[1] & 0x7F
    offset = 2
    if length == 126:
        if not need(4):
            return None
        length, offset = int.from_bytes(buffer[2:4], "big"), 4
    elif length == 127:
        if not need(10):
            return None
        length, offset = int.from_bytes(buffer[2:10], "big"), 10
    if buffer[1] & 0x80:
        offset += 4
    if not need(offset + length):
        return None
    return opcode, buffer[offset:offset + length], buffer[offset + length:]


def client_frame(opcode, payload):
    """A masked client frame (final) carrying PAYLOAD (under 126 bytes, as control frames are)."""
    mask = os.urandom(4)
    return bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def main(argv):
    if argv[:1] == ["hold"] and len(argv) == 2:
        return hold(argv[1])
    if argv[:1] == ["net"] and len(argv) == 2:
        print(*network(argv[1]))
        return 0
    if argv[:1] == ["docker"]:
        argv = argv[1:]
    if argv and argv[0] in ("exec", "cp") and any(a.startswith("vm:") for a in argv[1:]):
        return run_exec(argv[1:]) if argv[0] == "exec" else run_cp(argv[1:])
    os.execvp(real_docker(), [real_docker(), *argv])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
