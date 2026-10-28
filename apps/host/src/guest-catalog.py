"""Root catalog operations, invoked by the host through its argument-only guest channel."""
import fcntl
import hashlib
import json
import os
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

def run(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'})
    if result.returncode:
        raise RuntimeError('\n'.join(result.stdout.splitlines()[-12:])[-3000:] or f'{command[0]} failed ({result.returncode})')

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
        record = load(ROOT / (app['id'] + '.json'))
        previous = record.get('previous')
        can_rollback = bool(installed and previous and (ROOT / previous['file']).is_file())
        result[app['id']] = {'installedVersion': installed, 'canRollback': can_rollback, 'lastError': record.get('error'), 'interrupted': record.get('running', False)}
    print(json.dumps(result))

if action == 'list':
    listing()
    sys.exit(0)
if action == 'progress':
    record = load(ROOT / (args + '.json'))
    stage = record.get('stage', 'installing')
    progress = None
    if stage == 'downloading' and record.get('downloadFile') and record.get('size'):
        try:
            progress = min(0.75, (ROOT / record['downloadFile']).stat().st_size / record['size'] * 0.75)
        except FileNotFoundError:
            progress = 0
    elif stage == 'verifying': progress = 0.8
    elif stage == 'installing': progress = 0.85
    print(json.dumps({'stage': stage, 'value': progress}))
    sys.exit(0)

app = args
ident, source = app['id'], app['source']
path = ROOT / (ident + '.json')
with (ROOT / 'install.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    record = load(path)
    record.update(running=True, error=None, stage='installing')
    save(path, record)
    try:
        if action == 'remove':
            packages = source['packages'] if source['kind'] == 'apt' else [source['package']]
            run(['apt-get', 'remove', '-y', *packages])
        elif source['kind'] == 'apt':
            if action != 'install' and action != 'update':
                raise RuntimeError('Rollback is unavailable for Debian packages')
            run(['apt-get', 'update'])
            run(['apt-get', 'install', '-y', '--no-install-recommends', *(['--no-upgrade'] if action == 'install' else []), *source['packages']])
        else:
            current = record.get('current')
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
                    record.update(stage='downloading', downloadFile=Path(temporary).name, size=source['size'])
                    save(path, record)
                    try:
                        run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--output', temporary, source['url']])
                        downloaded = Path(temporary)
                        record['stage'] = 'verifying'
                        save(path, record)
                        if downloaded.stat().st_size != source['size'] or checksum(downloaded) != source['sha256']:
                            raise RuntimeError('Downloaded release size or SHA-256 does not match the catalog')
                        os.replace(temporary, artifact)
                    finally:
                        Path(temporary).unlink(missing_ok=True)
                target = {'file': artifact.name, 'sha256': source['sha256'], 'version': source['version']}
            record['stage'] = 'installing'
            save(path, record)
            run(['apt-get', 'update'])
            run(['apt-get', 'install', '-y', '--no-install-recommends', '--allow-downgrades', str(artifact)])
            if current and current != target:
                record['previous'] = current
            record['current'] = target
        record['running'] = False
        save(path, record)
    except Exception as error:
        record.update(running=False, error=str(error))
        save(path, record)
        raise SystemExit(str(error))
