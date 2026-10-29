"""Root catalog operations, invoked by the host through its argument-only guest channel."""
from collections import deque
import fcntl
import hashlib
import json
import os
import pwd
import re
from pathlib import Path
import shutil
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
# Games (docs/game-handoff.md): the bundles the guest components ship, and where an installed
# game's desktop entry and icon go.
SHIPPED = Path('/usr/local/share/caboose/games')
APPLICATIONS = Path('/usr/local/share/applications')
ICONS = Path('/usr/local/share/icons/hicolor')
RUNNER = '/usr/local/bin/caboose-game-run'
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}')
PROGRAM = re.compile(r'native/[A-Za-z0-9][A-Za-z0-9_.+-]*')

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

def game_dir(ident):
    return Path(pwd.getpwnam('caboose').pw_dir) / '.local/share/caboose/games' / ident

def game_version(app):
    """The version in the game's desktop entry, while its directory has a manifest."""
    if not NAME.fullmatch(app['id']) or not NAME.fullmatch(app.get('desktopId') or ''):
        return None
    try:
        entry = (APPLICATIONS / app['desktopId']).read_text(encoding='utf-8')
    except FileNotFoundError:
        return None
    found = re.search(r'^X-Caboose-Catalog-Version=(.+)$', entry, re.M)
    return found[1] if found and (game_dir(app['id']) / 'caboose-game.json').is_file() else None

def listing():
    apps = {}
    for app in args:
        source = app['source']
        if source['kind'] == 'flatpak':
            continue
        if source['kind'] == 'game':
            apps[app['id']] = state(app['id'], game_version(app))
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

# Runs as the owner, so root never writes through a path the owner controls.
OWNER = r'''
import ctypes, os, shutil, sys, tarfile, tempfile
from pathlib import Path
action, *rest = sys.argv[1:]

def exchange(a, b):
    """Swap two paths atomically: renameat2(RENAME_EXCHANGE), or renamex_np(RENAME_SWAP)."""
    libc = ctypes.CDLL(None, use_errno=True)
    if hasattr(libc, 'renameat2'):
        result = libc.renameat2(-100, os.fsencode(a), -100, os.fsencode(b), 2)
    else:
        result = libc.renamex_np(os.fsencode(a), os.fsencode(b), 2)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), b)

def discard(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)

if action == 'begin':
    games, ident = Path(rest[0]), rest[1]
    games.mkdir(parents=True, exist_ok=True)
    # A tilde is not in a catalog id, so another game's leftovers never match.
    for stale in games.glob('.' + ident + '~*'):
        shutil.rmtree(stale, ignore_errors=True)
    print(tempfile.mkdtemp(prefix='.' + ident + '~', dir=games))
elif action == 'unpack':
    target = Path(rest[0], rest[1])
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=sys.stdin.buffer, mode='r|*') as archive:
        archive.extractall(target, filter='data')
elif action == 'copy':
    shutil.copytree(rest[0], rest[1], dirs_exist_ok=True)
elif action == 'program':
    target = Path(rest[0], rest[1])
    target.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(target):
        discard(target)
    with open(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755), 'wb') as output:
        shutil.copyfileobj(sys.stdin.buffer, output)
    os.chmod(target, 0o755)
elif action == 'commit':
    staging, target = rest
    if os.path.lexists(target):
        exchange(staging, target)
        discard(staging)
    else:
        os.rename(staging, target)
elif action == 'remove':
    target = Path(rest[0])
    if os.path.lexists(target):
        # Renamed away first, so the game is gone at once even if deleting it is slow.
        doomed = target.parent / ('.' + target.name + '~' + os.urandom(8).hex())
        os.rename(target, doomed)
        discard(doomed)
elif action == 'abort':
    shutil.rmtree(rest[0], ignore_errors=True)
'''

def as_owner(arguments, source=None):
    # Isolated (-I) and from /, so nothing in the owner's or root's working directory or
    # environment is imported.
    result = subprocess.run(['runuser', '-u', 'caboose', '--', 'python3', '-I', '-c', OWNER, *arguments],
                            stdin=source or subprocess.DEVNULL, capture_output=True, text=True, cwd='/')
    if result.returncode:
        raise RuntimeError((result.stderr.strip().splitlines() or [f'owner step {arguments[0]} failed'])[-1][-3000:])
    return result.stdout.strip()

def write_root_file(target, data):
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + target.name + '.', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)

def refresh_icons():
    if (ICONS / 'icon-theme.cache').exists() and shutil.which('gtk-update-icon-cache'):
        run(['gtk-update-icon-cache', '--quiet', '--force', '--ignore-theme-index', str(ICONS)])

def desktop_value(text):
    return ' '.join(str(text).split()).replace('\\', '\\\\')

def game_names(app):
    if not NAME.fullmatch(ident) or not NAME.fullmatch(app['desktopId']) or not app['desktopId'].endswith('.desktop') or not NAME.fullmatch(app['icon']):
        raise RuntimeError('Invalid game identifiers')

def install_game(app, source, archive, native):
    """As the owner, unpack the web build into a staging directory and add the shipped bundle
    and the native build, then swap it in whole; as root, write the desktop entry and icon."""
    game_names(app)
    if not NAME.fullmatch(source['bundle']):
        raise RuntimeError('Invalid game bundle')
    shipped = SHIPPED / source['bundle']
    try:
        manifest = json.loads((shipped / 'caboose-game.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        raise RuntimeError(f"The game bundle {source['bundle']} is not installed; update the guest components") from None
    root = manifest.get('root', '.')
    if not isinstance(root, str) or root.startswith('/') or '..' in root.split('/'):
        raise RuntimeError('Invalid game bundle root')
    program = (manifest.get('native_fallback') or [None])[0]
    if native and not (isinstance(program, str) and PROGRAM.fullmatch(program)):
        raise RuntimeError('The game bundle has no native program for the native build')
    destination = game_dir(ident)
    if not re.fullmatch(r'[A-Za-z0-9/._+-]+', str(destination)):
        raise RuntimeError('The game directory cannot be named in a desktop entry')
    staging = as_owner(['begin', str(destination.parent), ident])
    try:
        with archive.open('rb') as build:
            as_owner(['unpack', staging, root], build)
        as_owner(['copy', str(shipped), staging])
        if native:
            with native.open('rb') as build:
                as_owner(['program', staging, program], build)
        as_owner(['commit', staging, str(destination)])
    except BaseException:
        try:
            as_owner(['abort', staging])
        except RuntimeError:
            pass
        raise
    icon = shipped / 'icon.png'
    if icon.is_file():
        write_root_file(ICONS / '128x128/apps' / (app['icon'] + '.png'), icon.read_bytes())
        refresh_icons()
    entry = ''.join(f'{key}={value}\n' for key, value in (
        ('Type', 'Application'), ('Name', desktop_value(app['name'])), ('Comment', desktop_value(app['summary'])),
        ('Exec', f'{RUNNER} {destination}'), ('TryExec', RUNNER), ('Icon', app['icon']), ('Categories', 'Game;'),
        ('Terminal', 'false'), ('X-Caboose-Catalog-Version', source['version'])))
    write_root_file(APPLICATIONS / app['desktopId'], ('[Desktop Entry]\n' + entry).encode())

def remove_game(app):
    game_names(app)
    # The desktop entry goes first: without it the listing no longer reports the game.
    (APPLICATIONS / app['desktopId']).unlink(missing_ok=True)
    as_owner(['remove', str(game_dir(ident))])
    (ICONS / '128x128/apps' / (app['icon'] + '.png')).unlink(missing_ok=True)
    refresh_icons()

def download(asset, artifact, mismatch):
    """Download a release asset to artifact, checked against its size and SHA-256."""
    fd, temporary = tempfile.mkstemp(prefix=ident + '-', suffix='.download', dir=ROOT)
    os.close(fd)
    record.update(stage='downloading', message=None, downloadFile=Path(temporary).name, size=asset['size'])
    save(path, record)
    try:
        run(['curl', '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--output', temporary, asset['url']])
        downloaded = Path(temporary)
        stage('verifying')
        if downloaded.stat().st_size != asset['size'] or checksum(downloaded) != asset['sha256']:
            raise RuntimeError(mismatch)
        os.replace(temporary, artifact)
    finally:
        Path(temporary).unlink(missing_ok=True)
        record.pop('downloadFile', None)
        record.pop('size', None)
    return artifact

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
        if recover and source['kind'] not in ('flatpak', 'game'):
            stage('configuring', 'Completing interrupted package setup')
            run(['dpkg', '--configure', '-a'])
        if source['kind'] == 'flatpak':
            flatpak_operation(app)
        elif source['kind'] == 'game' and action == 'remove':
            stage('removing')
            remove_game(app)
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
        elif source['kind'] == 'game':
            try:
                mismatch = 'Downloaded game size or SHA-256 does not match the catalog'
                archive = download(source, ROOT / f"{ident}-{source['version']}.archive", mismatch)
                native = download(source['native'], ROOT / f"{ident}-{source['version']}.native", mismatch) if source.get('native') else None
                stage('installing', 'Unpacking the game')
                install_game(app, source, archive, native)
            finally:
                # Like releases, a game's downloads are not kept once installed.
                for stale in [*ROOT.glob(f'{ident}-*.archive'), *ROOT.glob(f'{ident}-*.native')]:
                    stale.unlink(missing_ok=True)
        else:
            artifact = download(source, ROOT / f"{ident}-{source['version']}.deb", "Downloaded release size or SHA-256 does not match the release's published checksum")
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
