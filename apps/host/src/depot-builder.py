"""Maintain the host's shared Flatpak runtimes. Runs only in the host's trusted builder:
a throwaway container or desk from the pristine computer image, with the depot writable.
Every computer sees the depot read-only. Each line printed is one JSON event."""
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time

import gi
gi.require_version('Flatpak', '1.0')
from gi.repository import Flatpak, Gio, GLib

DEPOT = Path(sys.argv[1])
action = sys.argv[2]
argument = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
RUNTIME = re.compile(r'[A-Za-z_][A-Za-z0-9_.-]{0,254}/(x86_64|aarch64)/[A-Za-z0-9_.-]{1,64}')
# A superseded runtime stays deployed this long, for apps that started on it and still run.
RETAIN_S = 14 * 86400
RETIRED = DEPOT / 'caboose-retired.json'

def emit(**event):
    print(json.dumps(event), flush=True)

def installation():
    DEPOT.mkdir(parents=True, exist_ok=True)
    inst = Flatpak.Installation.new_for_path(Gio.File.new_for_path(str(DEPOT)), False, None)
    try:
        inst.get_remote_by_name('flathub', None)
    except GLib.Error:
        data = Path('/usr/share/caboose/flathub.flatpakrepo').read_bytes()
        remote = Flatpak.Remote.new_from_file('flathub', GLib.Bytes.new(data))
        inst.add_remote(remote, True, None)
    return inst

def runtimes(inst):
    return {f"{ref.get_name()}/{ref.get_arch()}/{ref.get_branch()}": ref for ref in inst.list_installed_refs_by_kind(Flatpak.RefKind.RUNTIME, None)}

def deploys(inst):
    """Each installed runtime's deployed commit directory."""
    found = {}
    for ident, ref in runtimes(inst).items():
        path = ref.get_deploy_dir()
        if path and Path(path).is_dir():
            found[ident] = Path(path)
    return found

def transact(inst, add, critical):
    transaction = Flatpak.Transaction.new_for_installation(inst, None)
    transaction.set_no_interaction(True)
    add(transaction)
    totals = {'size': 0, 'done': 0, 'at': 0.0}
    def ready(t):
        totals['size'] = sum(op.get_download_size() for op in t.get_operations())
        emit(type='ready', size=totals['size'], refs=[op.get_ref() for op in t.get_operations()])
        return True
    def operation(t, op, progress):
        progress.set_update_frequency(1000)
        def changed(p):
            if time.monotonic() - totals['at'] > 1:
                totals['at'] = time.monotonic()
                emit(type='progress', ref=op.get_ref(), downloaded=totals['done'] + p.get_bytes_transferred(), size=totals['size'])
        progress.connect('changed', changed)
    def done(t, op, commit, result):
        totals['done'] += op.get_download_size()
        emit(type='done', ref=op.get_ref())
    def failed(t, op, error, details):
        # An optional extension (a locale, a codec) must not cost the whole runtime; the
        # runtime itself and its Mesa GL driver must install.
        emit(type='warning', ref=op.get_ref(), message=error.message[-500:])
        return not (op.get_ref() in critical or '.GL.default/' in op.get_ref())
    transaction.connect('ready', ready)
    transaction.connect('new-operation', operation)
    transaction.connect('operation-done', done)
    transaction.connect('operation-error', failed)
    transaction.run(None)

def retire(before, inst):
    """Put back commit directories an update replaced, and remember when they were retired."""
    retired = json.loads(RETIRED.read_text()) if RETIRED.is_file() else {}
    after = deploys(inst)
    for ident, old in before.items():
        kept = DEPOT / '.caboose-retained' / old.name
        if after.get(ident) == old or not kept.is_dir():
            shutil.rmtree(kept, ignore_errors=True)
            continue
        if not old.exists():
            os.replace(kept, old)
        retired[str(old)] = time.time()
    RETIRED.write_text(json.dumps(retired))

def prune_retired(now):
    retired = json.loads(RETIRED.read_text()) if RETIRED.is_file() else {}
    for path, at in list(retired.items()):
        target = Path(path)
        if now - at > RETAIN_S and DEPOT in target.parents:
            shutil.rmtree(target, ignore_errors=True)
            del retired[path]
    RETIRED.write_text(json.dumps(retired))

inst = installation()
if action == 'ensure':
    if not isinstance(argument, str) or not RUNTIME.fullmatch(argument):
        raise SystemExit('Invalid runtime')
    if argument not in runtimes(inst):
        transact(inst, lambda t: t.add_install('flathub', 'runtime/' + argument, None), {'runtime/' + argument})
    if argument not in runtimes(inst):
        raise SystemExit(f'{argument} was not installed')
elif action == 'update':
    before = deploys(inst)
    # Hard links keep the deployed files of every current commit while the update replaces it.
    retained = DEPOT / '.caboose-retained'
    shutil.rmtree(retained, ignore_errors=True)
    retained.mkdir()
    for path in before.values():
        shutil.copytree(path, retained / path.name, symlinks=True, copy_function=os.link)
    try:
        refs = [ref for ref in inst.list_installed_refs_for_update(None) if ref.get_kind() == Flatpak.RefKind.RUNTIME]
        if refs:
            transact(inst, lambda t: [t.add_update(ref.format_ref(), None, None) for ref in refs], set())
    finally:
        retire(before, inst)
        shutil.rmtree(retained, ignore_errors=True)
    prune_retired(time.time())
elif action == 'collect':
    # Runtimes no computer has used within the host's horizon; the host names those to keep.
    if not isinstance(argument, list) or not all(isinstance(ref, str) and RUNTIME.fullmatch(ref) for ref in argument):
        raise SystemExit('Invalid runtime list')
    installed = runtimes(inst)
    keep = {ref for ref in argument if ref in installed}
    # A kept runtime keeps the extensions installed with it (GL drivers, locales, codecs).
    for ref in list(keep):
        for related in inst.list_installed_related_refs_sync('flathub', installed[ref].format_ref(), None):
            keep.add(f"{related.get_name()}/{related.get_arch()}/{related.get_branch()}")
    unused = [ident for ident in installed if ident not in keep]
    if unused:
        transact(inst, lambda t: [t.add_uninstall(installed[ident].format_ref()) for ident in unused], set())
    inst.prune_local_repo(None)
    prune_retired(time.time())
elif action != 'list':
    raise SystemExit('Unknown action')
total, seen = 0, set()
for root, _, files in os.walk(DEPOT):
    for name in files:
        try:
            info = os.lstat(os.path.join(root, name))
        except OSError:
            continue
        # Deployed files are hard links into the repository; count each inode once.
        if (info.st_dev, info.st_ino) not in seen:
            seen.add((info.st_dev, info.st_ino))
            total += info.st_blocks * 512
emit(type='state', runtimes=sorted(runtimes(inst)), bytes=total)
