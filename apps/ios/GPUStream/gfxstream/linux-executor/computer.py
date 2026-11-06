#!/usr/bin/env python3
"""The checks' way into a computer: a container (by name, through Docker) or a virtual machine
(vm:ID, through the host's operator routes, POST /v1/host/computers/ID/exec and PUT
/v1/host/computers/ID/file, with caboose-release's client and host settings).

  computer.py docker ARGS...   the subset of `docker` the checks use: `exec [-d] [-i] [-u USER]
                               [-e K=V] [-w DIR] TARGET COMMAND...` and `cp [-q] SOURCE TARGET:PATH`.
                               With a vm: target they run in the guest, anything else is Docker's.
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
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
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


def in_check_slice(command):
    """COMMAND (shell) run in the checks' capped slice, at the lowest priority, without core dumps."""
    return (f"systemctl set-property --runtime {CHECK_SLICE} {CHECK_LIMITS} > /dev/null 2>&1; "
            f"exec systemd-run --quiet --scope --collect --slice={CHECK_SLICE} -- "
            f"prlimit --core=0:0 -- nice -n 19 /bin/sh -c {shlex.quote(command)}")


def guest_command(argv, user=None, env=(), workdir=None, stdin_path=None):
    """The shell command running ARGV in the guest as `docker exec` would."""
    command = shlex.join(["env", *env, *argv]) if env else shlex.join(argv)
    if workdir:
        command = f"cd {shlex.quote(workdir)} && {command}"
    if stdin_path:
        command = f"{command} < {shlex.quote(stdin_path)}"
    if user:
        command = shlex.join(["runuser", "-u", user, "--", "/bin/sh", "-c", command])
    return command


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
    stdin_path = None
    if interactive and not detach:
        data = (stdin if stdin is not None else sys.stdin.buffer).read()
        stdin_path = f"/var/tmp/caboose-check-stdin-{uuid.uuid4().hex}"
        machine.put(stdin_path, data, 0o644)
    command = in_check_slice(guest_command(argv, user=user, env=env, workdir=workdir, stdin_path=stdin_path))
    if detach:
        result = machine.run("/bin/sh", "-c", f"setsid /bin/sh -c {shlex.quote(command)} < /dev/null > /dev/null 2>&1 &",
                             timeout=60, check=False)
        return int(result.get("exitCode", 1))
    if stdin_path:
        command = f"{command}; status=$?; rm -f {shlex.quote(stdin_path)}; exit $status"
    status, out, err = run_as_job(machine, command)
    sys.stdout.write(out)
    sys.stdout.flush()
    sys.stderr.write(err)
    return status


def run_as_job(machine, command):
    """Runs COMMAND in the guest as a job of its own, polled to its end: the host's exec route
    serves one guest command at a time, so a long one (a program the check runs for a minute)
    held directly would hold every other command of the checks behind it. Its exit status,
    standard output and error."""
    job = shlex.quote(f"/var/tmp/caboose-check-job-{uuid.uuid4().hex}")
    machine.run("/bin/sh", "-c",
                f"setsid /bin/sh -c {shlex.quote(f'({command}) > {job}.out 2> {job}.err; echo $? > {job}.part; mv {job}.part {job}.rc')} "
                f"< /dev/null > /dev/null 2>&1 &", timeout=60)
    delay = 0.05
    while machine.run("/bin/sh", "-c", f"test -f {job}.rc", timeout=60, check=False).get("exitCode") != 0:
        time.sleep(delay)
        delay = min(delay * 2, 1.0)
    result = machine.run("/bin/sh", "-c", f"cat {job}.out; cat {job}.err >&2; status=$(cat {job}.rc); "
                         f"rm -f {job}.out {job}.err {job}.rc; exit $status", timeout=120, check=False)
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


def main(argv):
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
