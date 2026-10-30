#!/usr/bin/env python3
"""Finite private phone GPU diagnostic orchestration; no shipping service."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import signal
import ssl
import subprocess
import sys
import time


def private_directory(path):
    st = path.lstat()
    if path.is_symlink() or not path.is_dir() or st.st_uid != os.geteuid() or st.st_mode & 0o077:
        raise ValueError("directory must be owned and mode 0700")


@contextmanager
def lock_directory(directory):
    private_directory(directory)
    fd = os.open(directory / ".session.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def stop(child):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=8)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)


def prepare(directory, bind):
    address = ipaddress.IPv4Address(bind)
    if address not in ipaddress.ip_network("100.64.0.0/10"):
        raise ValueError("diagnostic binds only an explicit Tailscale IPv4 address")
    directory.mkdir(mode=0o700)
    private_directory(directory)
    try:
        (directory / "transport").mkdir(mode=0o700)
        write_private(directory / "token", secrets.token_bytes(32))
        # Fresh certificate/key; values are neither printed nor command arguments.
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(directory / "key.pem"), "-out", str(directory / "cert.pem"),
                        "-days", "1", "-subj", "/CN=Caboose GPU Diagnostic"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        os.chmod(directory / "key.pem", 0o600)
        pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert((directory / "cert.pem").read_text())).hexdigest()
        config = dict(CABOOSE_GPU_HOST=bind, CABOOSE_GPU_PORT=str(49152 + secrets.randbelow(16384)),
                      CABOOSE_GPU_CERT_SHA256=pin, CABOOSE_GPU_TOKEN=(directory / "token").read_bytes().hex(),
                      CABOOSE_GPU_SESSION=secrets.token_hex(16), CABOOSE_GPU_GENERATION="1",
                      CABOOSE_GPU_PROCESS="1")
        write_private(directory / "phone-environment.json", json.dumps(config).encode())
        print(json.dumps({"event": "prepared", "listener_started": False}))
    except BaseException:
        cleanup_secrets(directory)
        raise


def cleanup_secrets(directory):
    for name in ("token", "key.pem", "cert.pem", "phone-environment.json"):
        (directory / name).unlink(missing_ok=True)


def cleanup_container(transport):
    digest = hashlib.sha256(os.fsencode(str(transport.resolve()))).hexdigest()
    name = "caboose-phone-oracle-" + digest[:24]
    lookup = subprocess.run(["docker", "ps", "-aq", "--filter", "name=^" + name + "$"],
                            capture_output=True, text=True, check=True, timeout=3)
    ids = lookup.stdout.split()
    if not ids:
        return
    if len(ids) != 1:
        raise RuntimeError("ambiguous diagnostic container")
    inspection = subprocess.run(["docker", "inspect", ids[0]], capture_output=True,
                                text=True, check=True, timeout=3)
    data = json.loads(inspection.stdout)[0]
    if data["Name"] != "/" + name or data["Config"]["Labels"].get("caboose.phone-trial") != digest:
        raise RuntimeError("container identity mismatch")
    subprocess.run(["docker", "rm", "-f", data["Id"]], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True, timeout=3)
    remaining = subprocess.run(["docker", "ps", "-aq", "--filter", "name=^" + name + "$"],
                               capture_output=True, text=True, check=True, timeout=3)
    if remaining.stdout.strip():
        raise RuntimeError("diagnostic container remains")


def run(directory, guest_runner):
    with lock_directory(directory):
        return run_locked(directory, guest_runner)


def run_locked(directory, guest_runner):
    transport = directory / "transport"
    broker = guest = None
    started = time.monotonic()
    deadline = started + 90
    result = {"status": "FAIL", "phone_execution": "UNVERIFIED"}
    def interrupted(signum, frame):
        raise InterruptedError("diagnostic interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGALRM, interrupted)
    signal.alarm(100)
    try:
        private_directory(transport)
        config = json.loads((directory / "phone-environment.json").read_text())
        with (directory / "broker.log").open("x") as log, (directory / "guest-runner.log").open("x") as guest_log:
            broker = subprocess.Popen([sys.executable, str(Path(__file__).with_name("phone_broker.py")),
                "--bind", config["CABOOSE_GPU_HOST"], "--port", config["CABOOSE_GPU_PORT"],
                "--directory", str(transport), "--cert", str(directory / "cert.pem"),
                "--key", str(directory / "key.pem"), "--token", str(directory / "token"),
                "--session", config["CABOOSE_GPU_SESSION"], "--generation", config["CABOOSE_GPU_GENERATION"],
                "--seconds", "90"], stdout=log, stderr=log)
            # Broker creates this socket only after successful phone authentication.
            while not (transport / "guest.sock").exists():
                if broker.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("phone authentication did not complete")
                time.sleep(0.05)
            result["phone_authenticated"] = True
            guest = subprocess.Popen([sys.executable, str(guest_runner), "--directory", str(transport),
                                      "--socket", str(transport / "guest.sock")],
                                     stdout=guest_log, stderr=guest_log)
            guest.wait(timeout=max(0.01, deadline-time.monotonic()))
            result["guest_runner_exit"] = guest.returncode
            if guest.returncode:
                raise RuntimeError("guest oracle failed")
            broker.wait(timeout=max(0.01, deadline-time.monotonic()))
            result["broker_exit"] = broker.returncode
            if broker.returncode:
                raise RuntimeError("broker did not finish cleanly")
            result["status"] = "HOST_ORACLE_PASS_PENDING_PHONE_IDENTITY_AND_TEARDOWN"
            # Actual physical device identity and app cleanup are independent root evidence.
    except Exception as error:
        result["error_type"] = type(error).__name__
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        for child in (guest, broker):
            try:
                stop(child)
            except Exception as error:
                result["status"] = "FAIL"
                result["cleanup_error"] = type(error).__name__
        if guest is not None:
            try:
                cleanup_container(transport)
            except Exception as error:
                result["status"] = "FAIL"
                result["container_cleanup_error"] = type(error).__name__
        cleanup_secrets(directory)
        (transport / "guest.sock").unlink(missing_ok=True)
        result["elapsed_seconds"] = time.monotonic() - started
        (directory / "session-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"].startswith("HOST_ORACLE_PASS") else 1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["prepare", "run", "cleanup"])
    p.add_argument("--directory", type=Path, required=True)
    p.add_argument("--bind")
    p.add_argument("--guest-runner", type=Path)
    a = p.parse_args()
    if a.action == "prepare":
        if not a.bind: p.error("prepare requires --bind")
        prepare(a.directory, a.bind)
        return 0
    private_directory(a.directory)
    if a.action == "cleanup":
        with lock_directory(a.directory):
            cleanup_secrets(a.directory)
        return 0
    if not a.guest_runner: p.error("run requires --guest-runner")
    return run(a.directory, a.guest_runner)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        # Do not print config, endpoints, tokens or exception text.
        print(json.dumps({"event": "failed", "error_type": type(error).__name__}))
        raise SystemExit(1)
