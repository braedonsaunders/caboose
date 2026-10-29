"""Root catalog operations, invoked by the host through its argument-only guest channel."""
from collections import deque
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path('/var/lib/caboose/catalog')
ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
action = sys.argv[1]
args = json.loads(sys.argv[2])

def save(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value), encoding='utf-8')
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

def load(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return {}

def version(package):
    result = subprocess.run(['dpkg-query', '-W', '-f=${db:Status-Status}\t${Version}', package], capture_output=True, text=True)
    parts = result.stdout.split('\t', 1)
    return parts[1] if result.returncode == 0 and len(parts) == 2 and parts[0] == 'installed' else None

def stage(name, message=None):
    record.update(stage=name, message=message)
    save(path, record)

def run(command):
    # Children retain the locks if the guest command channel loses this worker.
    # A surviving apt/dpkg must never be mistaken for an interrupted operation.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, pass_fds=(lock.fileno(), app_lock.fileno()),
                          env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive', 'LC_ALL': 'C'}) as process:
        tail = deque(maxlen=12)
        for line in process.stdout:
            tail.append(line.rstrip())
            trigger = re.match(r'Processing triggers for ([a-zA-Z0-9.+:-]+)', line)
            if trigger:
                stage('configuring', f'Completing package setup ({trigger[1]})')
        if process.wait():
            raise RuntimeError('\n'.join(tail)[-3000:] or f'{command[0]} failed ({process.returncode})')

def snapshot(ident):
    with (ROOT / (ident + '.lock')).open('a') as probe:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            record = load(ROOT / (ident + '.json'))
            # An existing worker may only hold the shared lock. Never offer recovery
            # while its package operation is still running.
            if record.get('running') and 'operation' not in record:
                with (ROOT / 'install.lock').open('a') as shared:
                    try:
                        fcntl.flock(shared, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return record, True
            return record, False
        except BlockingIOError:
            return load(ROOT / (ident + '.json')), True

def progress(record, running):
    if not record and not running:
        return None
    interrupted = bool(record.get('running') and not running)
    phase = 'installing' if running else 'failed' if interrupted or record.get('error') else 'finished'
    result = {'operation': record.get('operation', 'install'), 'phase': phase,
              'stage': record.get('stage', 'installing'), 'value': None}
    if interrupted:
        result['message'] = 'Operation interrupted. Retry to complete package setup.'
    elif record.get('error'):
        result['message'] = record['error']
    elif record.get('message'):
        result['message'] = record['message']
    if running and result['stage'] == 'downloading' and record.get('downloadFile') and record.get('size'):
        try:
            downloaded = (ROOT / record['downloadFile']).stat().st_size
        except FileNotFoundError:
            downloaded = 0
        result.update(downloadedBytes=downloaded, totalBytes=record['size'],
                      value=min(1, downloaded / record['size']))
    return result

def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def listing():
    result = {}
    for app in args:
        source = app['source']
        versions = [version(p) for p in (source['packages'] if source['kind'] == 'apt' else [source['package']])]
        installed = versions[0] if all(versions) else None
        record, running = snapshot(app['id'])
        previous = record.get('previous')
        can_rollback = bool(installed and previous and (ROOT / previous['file']).is_file())
        result[app['id']] = {'installedVersion': installed, 'canRollback': can_rollback,
                             'lastError': record.get('error'), 'interrupted': bool(record.get('running') and not running),
                             'active': running, 'operationId': record.get('operationId'), 'progress': progress(record, running)}
    print(json.dumps(result))

if action == 'list':
    listing()
    sys.exit(0)
if action == 'progress':
    record, running = snapshot(args)
    print(json.dumps(progress(record, running)))
    sys.exit(0)

app = args
ident, source = app['id'], app['source']
path = ROOT / (ident + '.json')
with (ROOT / 'install.lock').open('a') as lock, (ROOT / (ident + '.lock')).open('a') as app_lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(app_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('Another catalog operation is still running. Wait for it to finish.')
    record = load(path)
    recover = record.get('running') or record.get('error')
    if app.get('storeComponent'):
        record['storeComponent'] = app['storeComponent']
    record.update(running=True, operation=action, operationId=app.get('operationId'), error=None, stage='preparing', message=None)
    save(path, record)
    try:
        if recover:
            stage('configuring', 'Completing interrupted package setup')
            run(['dpkg', '--configure', '-a'])
        if action == 'remove':
            stage('removing')
            packages = source['packages'] if source['kind'] == 'apt' else [source['package']]
            run(['apt-get', 'remove', '-y', *packages])
        elif source['kind'] == 'apt':
            if action != 'install' and action != 'update':
                raise RuntimeError('Rollback is unavailable for Debian packages')
            stage('refreshing')
            run(['apt-get', 'update'])
            stage('installing')
            run(['apt-get', 'install', '-y', '--no-install-recommends', *(['--no-upgrade'] if action == 'install' else []), *source['packages']])
        else:
            current = record.get('current')
            stage('verifying')
            if action == 'rollback':
                target = record.get('previous')
                if not target:
                    raise RuntimeError('No previous release is available')
                artifact = ROOT / target['file']
                if not artifact.is_file() or checksum(artifact) != target['sha256']:
                    raise RuntimeError('Previous release is missing or its checksum is wrong')
            else:
                artifact = ROOT / f"{ident}-{source['version']}.deb"
                if not artifact.is_file() or artifact.stat().st_size != source['size'] or checksum(artifact) != source['sha256']:
                    fd, temporary = tempfile.mkstemp(prefix=ident + '-', suffix='.download', dir=ROOT)
                    os.close(fd)
                    record.update(stage='downloading', message=None, downloadFile=Path(temporary).name, size=source['size'])
                    save(path, record)
                    try:
                        run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--output', temporary, source['url']])
                        downloaded = Path(temporary)
                        stage('verifying')
                        if downloaded.stat().st_size != source['size'] or checksum(downloaded) != source['sha256']:
                            raise RuntimeError('Downloaded release size or SHA-256 does not match the catalog')
                        os.replace(temporary, artifact)
                    finally:
                        Path(temporary).unlink(missing_ok=True)
                target = {'file': artifact.name, 'sha256': source['sha256'], 'version': source['version']}
            stage('refreshing')
            run(['apt-get', 'update'])
            stage('installing')
            run(['apt-get', 'install', '-y', '--no-install-recommends', '--allow-downgrades', str(artifact), 'mesa-vulkan-drivers', 'libgl1-mesa-dri'])
            if current and current != target:
                record['previous'] = current
            record['current'] = target
        record.update(running=False, stage='finished', message=None)
        save(path, record)
    except Exception as error:
        record.update(running=False, error=str(error))
        save(path, record)
        raise SystemExit(str(error))
