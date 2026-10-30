#!/usr/bin/env python3
"""Run only the existing Vulkan feedback renderer against a private phone broker.

The caller supplies an existing private same-UID Unix socket and a writable trial
folder. This tool does not start a broker, receiver, or phone session.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys
import uuid

IMAGE = 'sha256:b94dd0452b1d2164d52115722c333cbb51f903e736fa7e7e782d21c52cf40442'
ICD = Path('/data/bb/caboose-private-icd-test/libvulkan_gfxstream.so')
BUILD = Path('/data/bb/caboose-gpu-v2-oracle/build')
ORACLE = Path('/data/bb/caboose-gpu-v2-decoder/draw-oracle')
EXPECTED = {
    ICD: 'd65b75bb403410cd3f2d7bb974829f625d2105c7a03339a06ba7d71fde064b7f',
    BUILD / 'caboose_vulkan_acceptance': 'ffc277e364b3995989ec33186dc89c97b0126d2ebff9cb065640fec4b00c556a',
    BUILD / 'shaders/feedback.comp.spv': '0444b44e058a2972eb44d8e0252b92cfcfbd49669e16c9132c9afb12ab637fb3',
    BUILD / 'shaders/control.vert.spv': '4fe83b763868e107b89e6cc83dcee7e8ff9197499e6e10c4dfbf053213d65d64',
    BUILD / 'shaders/color.frag.spv': '4436e4cf1f8b2f05ec0d5b540a28de81ad5b98f43019d18fd9b7319e0976ec89',
    ORACLE / 'verify.py': '28f18c0c661c51014dc396ad76e2871ec446fbb555d3235c2b80dfa9e22d7b4d',
    ORACLE / 'expected.json': '0270f078434b755def856ed7b67e7ffcffc9ceb77fbf0838122e27049e66be62',
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def container_name(trial):
    digest = hashlib.sha256(os.fsencode(str(trial))).hexdigest()
    return 'caboose-phone-oracle-' + digest[:24], digest


def run_locked(trial, socket_path):
    trial = Path(trial).resolve(strict=True)
    if not trial.is_dir() or trial.stat().st_uid != 1000 or os.getuid() != 1000:
        raise ValueError('trial directory and runner must be owned by UID 1000')
    if trial.stat().st_mode & 0o077:
        raise ValueError('trial directory must be private (mode 0700)')
    if ',' in str(trial):
        raise ValueError('trial directory cannot contain a comma')
    sock = Path(socket_path)
    if not sock.is_absolute() or sock.parent.resolve(strict=True) != trial or sock.name in ('.', '..'):
        raise ValueError('socket must be an absolute path directly in the trial directory')
    socket_name = sock.name
    socket_stat = sock.lstat()
    if not stat.S_ISSOCK(socket_stat.st_mode) or socket_stat.st_uid != 1000:
        raise ValueError('socket must be an existing UID 1000 Unix socket')
    hashes = {str(path): sha256(path) for path in EXPECTED}
    for path, expected in EXPECTED.items():
        if hashes[str(path)] != expected:
            raise ValueError(f'artifact hash mismatch: {path}')
    spec = importlib.util.spec_from_file_location('caboose_phone_oracle', ORACLE / 'verify.py')
    if spec is None or spec.loader is None:
        raise ValueError('oracle loader unavailable')
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)
    cases = json.loads((ORACLE / 'expected.json').read_text())['tests']
    case = next(c for c in cases if c['name'] == 'compute_cpu_feedback')
    seed = secrets.randbits(30) * 4 + 3
    run_id = uuid.uuid4().hex
    evidence = trial / ('oracle-' + run_id)
    evidence.mkdir(mode=0o700)
    manifest = {'file_format_version': '1.0.1', 'ICD': {
        'library_path': '/icd/libvulkan_gfxstream.so', 'library_arch': '64', 'api_version': '1.3.358'}}
    (evidence / 'icd.json').write_text(json.dumps(manifest) + '\n')
    name, trial_digest = container_name(trial)
    existing = subprocess.run(['docker', 'ps', '-aq', '--filter', f'name=^{name}$'],
                              capture_output=True, text=True, timeout=10, check=True)
    if existing.stdout.strip():
        raise ValueError(f'owned trial container already exists: {name}')
    cidfile = evidence / 'container.id'
    argv = ['docker', 'run', '--name', name, '--cidfile', str(cidfile), '--rm', '--pull', 'never', '--network', 'none',
            '--label', f'caboose.phone-trial={trial_digest}',
            '--cpus', '2', '--memory', '3g', '--memory-swap', '3g', '--pids-limit', '256',
            '--user', '1000:1000',
            '--mount', f'type=bind,src={trial},dst=/trial',
            '--mount', f'type=bind,src={ICD},dst=/icd/libvulkan_gfxstream.so,readonly',
            '--mount', f'type=bind,src={BUILD},dst=/oracle-build,readonly',
            '--mount', f'type=bind,src={ORACLE},dst=/oracle,readonly',
            '-e', f'CABOOSE_GFXSTREAM_SOCKET=/trial/{socket_name}',
            '-e', f'VK_DRIVER_FILES=/trial/{evidence.name}/icd.json',
            '-e', f'VK_ICD_FILENAMES=/trial/{evidence.name}/icd.json',
            IMAGE, '/oracle-build/caboose_vulkan_acceptance', '/oracle-build/shaders',
            'compute_cpu_feedback', f'/trial/{evidence.name}/output.rgba', str(seed)]
    result = {'status': 'FAIL', 'seed': seed, 'image_id': IMAGE, 'artifact_hashes': hashes,
              'container': name, 'trial_sha256': trial_digest, 'evidence_dir': str(evidence),
              'result_file': str(evidence / 'result.json'),
              'executor_identity_verified': False,
              'scope': 'guest CPU and encoder; remote Vulkan executor requires independent identity verification'}
    try:
        with (evidence / 'stdout.log').open('wb') as out, (evidence / 'stderr.log').open('wb') as err:
            try:
                process = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                         timeout=40, check=False)
                result['exit_code'] = process.returncode
            except subprocess.TimeoutExpired:
                result['reason'] = 'renderer timeout'
        if 'reason' not in result:
            if result['exit_code'] != 0:
                result['reason'] = 'renderer exited unsuccessfully'
            else:
                data = (evidence / 'stdout.log').read_bytes()
                if len(data) > 65536:
                    raise ValueError('renderer output exceeds 64 KiB')
                lines = data.decode('utf-8').splitlines()
                if len(lines) != 1:
                    raise ValueError('renderer must emit one JSON object')
                metadata = json.loads(lines[0])
                if metadata.get('status') != 'RENDERED' or metadata.get('feedback_seed') != seed:
                    raise ValueError('missing or stale renderer metadata')
                pixels = (evidence / 'output.rgba').read_bytes()
                verdict = oracle.verify_pixels(pixels, case, metadata, expected_seed=seed)
                result['renderer'] = metadata
                result['oracle'] = verdict
                if verdict.get('status') != 'PASS':
                    raise ValueError('independent pixel/feedback oracle failed')
                result['status'] = 'PASS'
    except (OSError, ValueError, KeyError, UnicodeError, json.JSONDecodeError) as exc:
        result['reason'] = str(exc)
    finally:
        # This unique name is created only by this invocation. Docker rm -f also
        # stops a daemon-side container left alive after client timeout.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            if cidfile.exists():
                cid = cidfile.read_text().strip()
                if len(cid) != 64 or any(c not in '0123456789abcdef' for c in cid):
                    raise ValueError('invalid Docker container ID')
                result['container_id'] = cid
                cleanup = subprocess.run(['docker', 'rm', '-f', cid], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, timeout=3, check=False)
                # --rm may already have removed the exited container.
                result['cleanup_exit'] = cleanup.returncode
            check = subprocess.run(['docker', 'ps', '-aq', '--filter', f'name=^{name}$'],
                                   capture_output=True, text=True, timeout=2, check=True)
            if check.stdout.strip():
                result['status'] = 'FAIL'
                result['cleanup_error'] = 'owned container still exists'
        except (OSError, ValueError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as exc:
            result['status'] = 'FAIL'
            result['cleanup_error'] = str(exc)
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def run(trial, socket_path):
    trial = Path(trial).resolve(strict=True)
    if not trial.is_dir() or trial.stat().st_uid != 1000 or os.getuid() != 1000:
        raise ValueError('trial directory and runner must be owned by UID 1000')
    if trial.stat().st_mode & 0o077:
        raise ValueError('trial directory must be private (mode 0700)')
    lock_fd = os.open(trial / '.oracle.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return run_locked(trial, socket_path)
    finally:
        os.close(lock_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--socket', required=True)
    args = parser.parse_args()
    def terminate(_signum, _frame):
        # A second SIGTERM cannot interrupt cleanup once the first arrives.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise InterruptedError('runner terminated by parent')
    signal.signal(signal.SIGTERM, terminate)
    try:
        result = run(args.directory, args.socket)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({'status': 'FAIL', 'reason': str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
