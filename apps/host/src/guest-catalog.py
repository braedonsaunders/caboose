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
import time

ROOT = Path('/var/lib/caboose/catalog')
DEPOT = Path('/var/lib/caboose/depot')
ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
action = sys.argv[1]
args = json.loads(sys.argv[2])
UNSANDBOXED = "Flathub apps can't run on this computer yet: its container was created before Caboose allowed Flatpak's sandbox. Recreate the computer to add them; its home folder is kept."
APP_ID = re.compile(r'[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}')

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

def flatpak():
    """libflatpak, or None on a computer whose components predate Flatpak support."""
    try:
        import gi
        gi.require_version('Flatpak', '1.0')
        from gi.repository import Flatpak
        return Flatpak
    except (ImportError, ValueError):
        return None

def depot(Flatpak):
    """The host's shared runtimes, when this computer has them mounted."""
    if not (DEPOT / 'repo' / 'config').is_file():
        return None
    from gi.repository import Gio
    return Flatpak.Installation.new_for_path(Gio.File.new_for_path(str(DEPOT)), False, None)

def sandbox_works():
    """Whether Flatpak's sandbox can start here, as the computer's user. bubblewrap gives each
    app fresh namespaces and its own /proc; in a container whose /proc Docker masks, the
    kernel refuses that /proc, and no Flatpak app could start. Probed once per boot."""
    marker = Path('/run/caboose-flatpak-sandbox')
    try:
        return marker.read_text() == 'yes'
    except OSError:
        pass
    probe = subprocess.run(['runuser', '-u', 'caboose', '--', 'bwrap', '--unshare-all', '--die-with-parent',
                            '--ro-bind', '/', '/', '--proc', '/proc', '--dev', '/dev', 'true'], capture_output=True)
    works = probe.returncode == 0
    try:
        marker.write_text('yes' if works else 'no')
    except OSError:
        pass
    return works

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
    if result['operation'] not in ('install', 'update', 'remove'):
        result['operation'] = 'update'
    if interrupted:
        result['message'] = 'Operation interrupted. Retry to complete package setup.'
    elif record.get('error'):
        result['message'] = record['error']
    elif record.get('message'):
        result['message'] = record['message']
    if running and result['stage'] == 'downloading' and record.get('size'):
        if record.get('downloadFile'):
            try:
                downloaded = (ROOT / record['downloadFile']).stat().st_size
            except FileNotFoundError:
                downloaded = 0
        else:
            downloaded = int(record.get('downloaded') or 0)
        result.update(downloadedBytes=downloaded, totalBytes=record['size'],
                      value=min(1, downloaded / record['size']))
    return result

def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def state(ident, installed, extra=None):
    record, running = snapshot(ident)
    return {'installedVersion': installed, 'lastError': record.get('error'),
            'interrupted': bool(record.get('running') and not running), 'active': running,
            'operationId': record.get('operationId'), 'progress': progress(record, running), **(extra or {})}

def listing():
    apps = {}
    for app in args:
        source = app['source']
        if source['kind'] == 'flatpak':
            continue
        versions = [version(p) for p in (source['packages'] if source['kind'] == 'apt' else [source['package']])]
        apps[app['id']] = state(app['id'], versions[0] if all(versions) else None)
    environment = {'flatpak': False, 'sandbox': False, 'depot': False, 'arch': None}
    Flatpak = flatpak()
    installed = {}
    if Flatpak:
        environment.update(flatpak=True, arch=Flatpak.get_default_arch(), sandbox=sandbox_works(),
                           depot=(DEPOT / 'repo' / 'config').is_file())
        system = Flatpak.Installation.new_system(None)
        for ref in system.list_installed_refs_by_kind(Flatpak.RefKind.APP, None):
            if ref.get_origin() != 'flathub' or not APP_ID.fullmatch(ref.get_name() or ''):
                continue
            runtime = None
            try:
                metadata = ref.load_metadata(None).get_data().decode('utf-8', 'replace')
                found = re.search(r'^runtime=(\S+)$', metadata, re.M)
                runtime = found[1] if found else None
            except Exception:
                pass
            installed[ref.get_name()] = {'version': ref.get_appdata_version() or ref.get_commit()[:12],
                                         'name': (ref.get_appdata_name() or '')[:160], 'summary': (ref.get_appdata_summary() or '')[:500],
                                         'runtime': runtime}
    # Flathub apps with an operation record or an installation, whatever the host already knows.
    names = set(installed) | {f.stem[len('flathub-'):] for f in ROOT.glob('flathub-*.json')}
    for name in sorted(names)[:500]:
        if not APP_ID.fullmatch(name):
            continue
        info = installed.get(name)
        apps['flathub-' + name] = state('flathub-' + name, info['version'] if info else None,
                                        {'flatpak': info or None})
    print(json.dumps({'apps': apps, 'environment': environment}))

def updates():
    """Installed apps with something newer: Flathub commits, and Debian packages APT can
    upgrade. Contacts Flathub and the Debian mirrors."""
    result = {'flatpak': [], 'apt': []}
    Flatpak = flatpak()
    if Flatpak:
        system = Flatpak.Installation.new_system(None)
        refs = system.list_installed_refs_for_update(None)
        result['flatpak'] = sorted({ref.get_name() for ref in refs if ref.get_kind() == Flatpak.RefKind.APP and ref.get_origin() == 'flathub'})
    if args:
        with (ROOT / 'install.lock').open('a') as shared:
            fcntl.flock(shared, fcntl.LOCK_EX)
            subprocess.run(['apt-get', 'update'], capture_output=True, env={**os.environ, 'LC_ALL': 'C'}, timeout=600)
        listed = subprocess.run(['apt', 'list', '--upgradable'], capture_output=True, text=True, env={**os.environ, 'LC_ALL': 'C'}).stdout
        upgradable = {line.split('/', 1)[0] for line in listed.splitlines() if '/' in line}
        result['apt'] = [app['id'] for app in args if app['source']['kind'] == 'apt' and upgradable & set(app['source']['packages'])]
    print(json.dumps(result))

if action == 'list':
    listing()
    sys.exit(0)
if action == 'progress':
    record, running = snapshot(args)
    print(json.dumps(progress(record, running)))
    sys.exit(0)
if action == 'updates':
    updates()
    sys.exit(0)

def flatpak_operation(app):
    Flatpak = flatpak()
    if not Flatpak:
        raise RuntimeError('Flatpak is not installed on this computer yet. Wake it again after Caboose components update.')
    if action != 'remove' and not sandbox_works():
        raise RuntimeError(UNSANDBOXED)
    from gi.repository import GLib
    app_id = app['source']['appId']
    if not APP_ID.fullmatch(app_id):
        raise RuntimeError('Invalid Flathub application')
    arch = Flatpak.get_default_arch()
    ref = f'app/{app_id}/{arch}/stable'
    system = Flatpak.Installation.new_system(None)
    transaction = Flatpak.Transaction.new_for_installation(system, None)
    transaction.set_no_interaction(True)
    shared = depot(Flatpak)
    if shared:
        transaction.add_dependency_source(shared)
    if action == 'remove':
        stage('removing')
        transaction.add_uninstall(ref)
    elif action == 'install':
        transaction.add_install('flathub', ref, None)
    else:
        transaction.add_update(ref, None, None)
    totals = {'size': 0, 'done': 0, 'saved': 0.0}
    def ready(t):
        totals['size'] = sum(op.get_download_size() for op in t.get_operations())
        if action != 'remove':
            if totals['size']:
                record.update(stage='downloading', message=None, size=totals['size'], downloaded=0)
                save(path, record)
            else:
                stage('installing')
        return True
    def operation(t, op, prog):
        prog.set_update_frequency(500)
        def changed(p):
            now = time.monotonic()
            if totals['size'] and now - totals['saved'] > 0.5:
                totals['saved'] = now
                record['downloaded'] = min(totals['size'], totals['done'] + p.get_bytes_transferred())
                save(path, record)
        prog.connect('changed', changed)
    def done(t, op, commit, result):
        totals['done'] += op.get_download_size()
    errors = []
    def failed(t, op, error, details):
        errors.append(error.message)
        return False
    transaction.connect('ready', ready)
    transaction.connect('new-operation', operation)
    transaction.connect('operation-done', done)
    transaction.connect('operation-error', failed)
    try:
        transaction.run(None)
    except GLib.Error as error:
        raise RuntimeError((errors[-1] if errors else error.message)[-3000:])
    if action == 'remove':
        # Runtimes this computer installed itself, and no app here still needs.
        subprocess.run(['flatpak', 'uninstall', '--system', '--unused', '--noninteractive', '-y'], capture_output=True)
    record.pop('downloaded', None)
    record.pop('size', None)

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
        if recover and source['kind'] != 'flatpak':
            stage('configuring', 'Completing interrupted package setup')
            run(['dpkg', '--configure', '-a'])
        if source['kind'] == 'flatpak':
            flatpak_operation(app)
        elif action == 'remove':
            stage('removing')
            packages = source['packages'] if source['kind'] == 'apt' else [source['package']]
            run(['apt-get', 'remove', '-y', *packages])
        elif action not in ('install', 'update'):
            raise RuntimeError(f'Unknown operation {action}')
        elif source['kind'] == 'apt':
            stage('refreshing')
            run(['apt-get', 'update'])
            stage('installing')
            run(['apt-get', 'install', '-y', '--no-install-recommends', *(['--no-upgrade'] if action == 'install' else []), *source['packages']])
        else:
            artifact = ROOT / f"{ident}-{source['version']}.deb"
            fd, temporary = tempfile.mkstemp(prefix=ident + '-', suffix='.download', dir=ROOT)
            os.close(fd)
            record.update(stage='downloading', message=None, downloadFile=Path(temporary).name, size=source['size'])
            save(path, record)
            try:
                run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--output', temporary, source['url']])
                downloaded = Path(temporary)
                stage('verifying')
                if downloaded.stat().st_size != source['size'] or checksum(downloaded) != source['sha256']:
                    raise RuntimeError("Downloaded release size or SHA-256 does not match the release's published checksum")
                os.replace(temporary, artifact)
            finally:
                Path(temporary).unlink(missing_ok=True)
                record.pop('downloadFile', None)
                record.pop('size', None)
            try:
                stage('refreshing')
                run(['apt-get', 'update'])
                stage('installing')
                run(['apt-get', 'install', '-y', '--no-install-recommends', '--allow-downgrades', str(artifact), 'mesa-vulkan-drivers', 'libgl1-mesa-dri'])
            finally:
                # Releases are not kept once installed; the latest is always downloaded again.
                for stale in ROOT.glob(f'{ident}-*.deb'):
                    stale.unlink(missing_ok=True)
            record.pop('current', None)
            record.pop('previous', None)
        record.update(running=False, stage='finished', message=None)
        save(path, record)
    except Exception as error:
        record.update(running=False, error=str(error))
        save(path, record)
        raise SystemExit(str(error))
