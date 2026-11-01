"""App scopes: the pure logic of caboose-scopes, without any I/O.

Every app the owner runs lives in a cgroup v2 scope of its own, named as systemd names
transient scopes (`app-<escaped key>-<n>.scope`), so its whole process tree is accounted
and can be ended together. This module names scopes, parses the kernel's cgroup and /proc
files, decides which processes move into which scope, and builds the versioned snapshot
the host serves. caboose-scopes does the reading, moving and signalling.
"""
import os
import re

VERSION = 1
SESSION = 'session.scope'
# Bounds on what one snapshot carries.
MAX_PROCESSES = 256
MAX_COMMAND = 512
MAX_NAME = 200
MAX_COMM = 64
# A scope made by a split adopts its source's stragglers for this long: children forked
# after the split was decided but before their parent moved.
STRAGGLER_SECONDS = 5.0

_SCOPE = re.compile(r'app-(.+)-([0-9]{1,10})\.scope')
_PLAIN = re.compile(r'[A-Za-z0-9:_.]')


# -- Names --------------------------------------------------------------------------------

def escape(key):
    """systemd's unit-name escaping (systemd-escape): anything outside [A-Za-z0-9:_.], and a
    leading '.', becomes \\xNN per UTF-8 byte."""
    out = []
    for index, char in enumerate(key):
        if _PLAIN.fullmatch(char) and not (index == 0 and char == '.'):
            out.append(char)
        else:
            out.extend(f'\\x{byte:02x}' for byte in char.encode('utf-8'))
    return ''.join(out)


def unescape(text):
    data = bytearray()
    index = 0
    while index < len(text):
        if text.startswith('\\x', index) and re.fullmatch(r'[0-9a-fA-F]{2}', text[index + 2:index + 4]):
            data.append(int(text[index + 2:index + 4], 16))
            index += 4
        else:
            data.extend(text[index].encode('utf-8'))
            index += 1
    return data.decode('utf-8', 'replace')


def scope_key(desktop_id):
    """The key a desktop id names its scopes by: the id without `.desktop`."""
    return desktop_id[:-len('.desktop')] if desktop_id.endswith('.desktop') else desktop_id


def scope_name(key, number):
    return f'app-{escape(key)}-{number}.scope'


def parse_scope_name(name):
    """(key, number) for an app scope's name, else None."""
    match = _SCOPE.fullmatch(name)
    if not match or '/' in name:
        return None
    return unescape(match.group(1)), int(match.group(2))


def valid_scope_id(name):
    return name == SESSION or (parse_scope_name(name) is not None and len(name) <= 255)


def valid_desktop_id(ident):
    """A desktop id as entries are named (the compositor's launch marks use the same rule)."""
    return (isinstance(ident, str) and len('.desktop') < len(ident) <= 255 and ident.endswith('.desktop')
            and all(c.isascii() and (c.isalnum() or c in '._-+@') for c in ident))


def valid_entry_id(ident):
    """Any installed entry's id, as the dock launches it: a file name ending in `.desktop`
    (Steam names game entries after the game, spaces and all)."""
    return (isinstance(ident, str) and len('.desktop') < len(ident) <= 255 and ident.endswith('.desktop')
            and '/' not in ident and not any(ord(c) < 32 or ord(c) == 127 for c in ident))


# -- /proc and cgroup files ----------------------------------------------------------------

def parse_stat(line):
    """/proc/<pid>/stat: (comm, state, ppid, controlling tty, cpu ticks, start ticks). comm may
    hold spaces and parentheses, so the fields after it are found from its last ')'. A
    process that ended before it was read has none: ValueError, as for a malformed one."""
    if not line:
        raise ValueError('no stat')
    start, end = line.find('('), line.rfind(')')
    if start < 0 or end < start or line[end + 1:end + 2] != ' ':
        raise ValueError('malformed stat')
    fields = line[end + 2:].split()
    if len(fields) < 20:
        raise ValueError('truncated stat')
    return line[start + 1:end], fields[0], int(fields[1]), int(fields[4]), int(fields[11]) + int(fields[12]), int(fields[19])


STATES = {'R': 'running', 'S': 'sleeping', 'D': 'waiting', 'T': 'stopped', 't': 'stopped', 'Z': 'zombie', 'I': 'idle'}


def state_name(code):
    return STATES.get(code, 'other')


def parse_uid(status):
    """The real uid from /proc/<pid>/status (ValueError for a process that has ended)."""
    for line in (status or '').splitlines():
        if line.startswith('Uid:'):
            return int(line.split()[1])
    raise ValueError('no Uid line')


def parse_keyed(text):
    """`key value` lines (cpu.stat, memory.stat, cgroup.events)."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip('-').isdigit():
            out[parts[0]] = int(parts[1])
    return out


def parse_io_stat(text):
    """io.stat summed over devices: (bytes read, bytes written)."""
    read = written = 0
    for line in text.splitlines():
        for field in line.split()[1:]:
            key, _, value = field.partition('=')
            if value.isdigit():
                if key == 'rbytes':
                    read += int(value)
                elif key == 'wbytes':
                    written += int(value)
    return read, written


def memory_in_use(current, stat):
    """What the scope holds, as `docker stats` counts it: charged memory less the page cache
    the kernel can drop at once."""
    return max(0, current - stat.get('inactive_file', 0))


def variable(environ, name):
    """One variable's value from a NUL-separated environment block, or None."""
    prefix = name.encode() + b'='
    for entry in environ.split(b'\0'):
        if entry.startswith(prefix):
            try:
                return entry[len(prefix):].decode('utf-8')
            except UnicodeDecodeError:
                return None
    return None


def launch_marks(environ):
    """(desktop id, launched pid) a launch marked a process's environment with, or None.
    Caboose's launcher sets CABOOSE_DESKTOP_ID; GLib sets GIO_LAUNCHED_DESKTOP_FILE and
    GIO_LAUNCHED_DESKTOP_FILE_PID for every entry it launches (guest/display launch.rs reads
    the same marks for windows)."""
    ident = variable(environ, 'CABOOSE_DESKTOP_ID')
    if not valid_desktop_id(ident):
        path = variable(environ, 'GIO_LAUNCHED_DESKTOP_FILE')
        ident = path.rsplit('/', 1)[-1] if path else None
        if not valid_desktop_id(ident):
            return None
    launched = variable(environ, 'GIO_LAUNCHED_DESKTOP_FILE_PID')
    return ident, int(launched) if launched and launched.isdigit() else None


def steam_game(argv):
    """The Steam app id a process launches, when it is Steam's game reaper
    (`reaper SteamLaunch AppId=N -- …`), else None."""
    if not argv or os.path.basename(argv[0]) != 'reaper' or 'SteamLaunch' not in argv:
        return None
    for arg in argv:
        if arg == '--':
            break
        if arg.startswith('AppId='):
            value = arg[len('AppId='):]
            return int(value) if value.isdigit() and 0 < int(value) < 1 << 32 else None
    return None


def environ_game(environ):
    """The Steam app id a process runs for, from its environment: Steam gives a game's
    whole launch `SteamGameId` (and `SteamAppId`), and pressure-vessel and Proton pass it to
    every process of the game, including those a portal starts in a sandbox of their own."""
    for name in ('SteamGameId', 'SteamAppId'):
        value = variable(environ, name)
        if value and value.isdigit() and 0 < int(value) < 1 << 32:
            return int(value)
    return None


def terminal_service(argv):
    """Whether a process is Caboose's terminal service, whose children are phone terminal
    sessions."""
    return bool(argv) and len(argv) > 1 and os.path.basename(argv[0]).startswith('python') and \
        os.path.basename(argv[1]) == 'caboose-terminal.py'


def agent_runner(argv):
    """Whether a process is one of Caboose's agent task runners (`caboose-agentd.mjs run`)."""
    if not argv:
        return False
    for index, arg in enumerate(argv[:-1]):
        if os.path.basename(arg) == 'caboose-agentd.mjs' and argv[index + 1] == 'run':
            return True
    return False


def flatpak_app(info):
    """The application id in a sandbox's /.flatpak-info, else None."""
    section = None
    for line in info.splitlines():
        line = line.strip()
        if line.startswith('['):
            section = line
        elif section == '[Application]' and line.startswith('name='):
            ident = line[len('name='):].strip()
            return ident if re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', ident) and len(ident) <= 255 else None
    return None


SANDBOX_LAUNCHERS = ('bwrap', 'bwrap.distrib', 'caboose-bwrap', 'flatpak')


PLACEMENTS = ('cpu-until-relaunch', 'phone')


def gpu_placements(files, starts):
    """{pid: placement} from the GPU layer's placement files ({file name: content}), each
    `<placement> <start ticks>` named by the writer's pid as it sees it (a Flatpak sandbox's
    own pid namespace). `starts` maps the computer's pids to their start ticks; a file whose
    pid is not that process is matched by its start time, and dropped when nothing matches."""
    by_start = {}
    for pid, start in sorted(starts.items()):
        by_start.setdefault(start, pid)
    out = {}
    for name, content in files.items():
        words = content.split()
        if not name.isdigit() or len(words) != 2 or words[0] not in PLACEMENTS or not words[1].isdigit():
            continue
        pid, start = int(name), int(words[1])
        if starts.get(pid) != start:
            pid = by_start.get(start)
        if pid is not None:
            out[pid] = words[0]
    return out


def app_placement(placements):
    """An app's placement from its processes': any still on the CPU until relaunched wins."""
    values = set(placements)
    return 'cpu-until-relaunch' if 'cpu-until-relaunch' in values else 'phone' if 'phone' in values else None


def acf_name(text):
    """The game's name from a Steam appmanifest_<id>.acf."""
    match = re.search(r'^\s*"name"\s+"((?:[^"\\]|\\.)*)"', text, re.MULTILINE)
    return match.group(1).replace('\\"', '"').replace('\\\\', '\\')[:MAX_NAME] if match else None


# -- Classification ------------------------------------------------------------------------

class Proc:
    """One process as classification sees it."""
    __slots__ = ('pid', 'ppid', 'uid', 'comm', 'argv', 'marks', 'tty', 'state', 'ticks', 'start', 'flatpak', 'game')

    def __init__(self, pid, ppid, uid=1000, comm='', argv=None, marks=None, tty=0, state='S', ticks=0, start=0, flatpak=None,
                 game=None):
        self.pid, self.ppid, self.uid, self.comm, self.argv, self.marks = pid, ppid, uid, comm, argv, marks
        self.tty, self.state, self.ticks, self.start, self.flatpak, self.game = tty, state, ticks, start, flatpak, game


class NewScope:
    """A scope to make: its key, how it came to be, and naming hints."""
    __slots__ = ('key', 'origin', 'desktop_id', 'app_id', 'game', 'source', 'flatpak')

    def __init__(self, key, origin, desktop_id=None, app_id=None, game=None, source=None, flatpak=None):
        self.key, self.origin, self.desktop_id, self.app_id, self.game, self.source = \
            key, origin, desktop_id, app_id, game, source
        self.flatpak = flatpak

    def __eq__(self, other):
        return isinstance(other, NewScope) and all(getattr(self, s) == getattr(other, s) for s in self.__slots__)

    def __repr__(self):
        return 'NewScope(' + ', '.join(f'{s}={getattr(self, s)!r}' for s in self.__slots__) + ')'


def children_of(procs):
    children = {}
    for proc in procs.values():
        children.setdefault(proc.ppid, []).append(proc.pid)
    return children


def subtree(root, children, membership):
    """`root` and its descendants that are in the same scope as `root`."""
    scope = membership.get(root)
    found, stack = [], [root]
    while stack:
        pid = stack.pop()
        if pid in found or membership.get(pid) != scope:
            continue
        found.append(pid)
        stack.extend(children.get(pid, ()))
    return found


def ancestors(pid, procs):
    seen, out = {pid}, []
    while pid in procs and procs[pid].ppid not in seen and procs[pid].ppid > 0:
        pid = procs[pid].ppid
        seen.add(pid)
        out.append(pid)
    return out


def classify(procs, membership, scopes, windows, now):
    """Which processes move where, in order. `procs` maps pid to Proc; `membership` pid to
    its scope name (SESSION or an app scope; processes outside the owner's tree are absent);
    `scopes` scope name to its metadata (`origin`, `desktopId`, `game`, `source`,
    `createdAt`); `windows` the compositor's windows (`id`, `pid`, `parent`, `kind`,
    `app_id`, `desktop_id`). Returns [(pids, target)], target a scope name or a NewScope.

    The rules, first match wins for each process:
    1. Steam's reaper for game N, outside a scope for game N: its tree becomes game N's.
       Then any process whose environment names game N (`SteamGameId`), outside a scope for
       game N, with the sandbox launchers that started it: game N's scope. Flatpak Steam's
       pressure-vessel runs the game in a sandbox a portal starts, outside the reaper's tree.
    2. A child of a scope made in the last few seconds by a split, left behind in the scope
       it was split from: it follows its parent.
    3. A phone terminal session (a child of the terminal service), or an agent task's runner
       (`caboose-agentd.mjs run`) in the session scope: its own scope.
    4. In the session scope, a Flatpak application's sandboxes (with the bubblewrap and
       flatpak processes that started them): its scope, one per application.
    5. In the session scope, processes a launch marked: one scope per launch.
    6. A toplevel window whose process is in the session scope or a phone terminal session's
       scope, or in an app scope when the process runs on a terminal under a process of that
       scope that has a window of its own and is not on that terminal (a program run from a
       terminal app): the window's process tree becomes a scope of its own.
    """
    children = children_of(procs)
    taken = set()
    moves = []

    def move(pids, target):
        pids = [pid for pid in pids if pid not in taken]
        if pids:
            taken.update(pids)
            moves.append((pids, target))

    # 1. Games.
    for pid in sorted(procs):
        game = steam_game(procs[pid].argv)
        scope = membership.get(pid)
        if game is None or scope is None or pid in taken:
            continue
        if scopes.get(scope, {}).get('game') == game:
            continue
        move(subtree(pid, children, membership), NewScope(f'steam_app_{game}', 'game', game=game, source=scope))
    pending = {target.game for _, target in moves if isinstance(target, NewScope)}
    for pid in sorted(procs):
        game = procs[pid].game
        scope = membership.get(pid)
        if game is None or scope is None or pid in taken or scopes.get(scope, {}).get('game') == game:
            continue
        existing = sorted((m.get('createdAt', 0), name) for name, m in scopes.items() if m.get('game') == game)
        if not existing and game in pending:
            # The reaper's scope is made this pass; the rest joins it on the next.
            continue
        top = pid
        while procs[top].ppid in procs and membership.get(procs[top].ppid) == scope and \
                procs[procs[top].ppid].argv and os.path.basename(procs[procs[top].ppid].argv[0]) in SANDBOX_LAUNCHERS:
            top = procs[top].ppid
        target = existing[-1][1] if existing else NewScope(f'steam_app_{game}', 'game', game=game, source=scope)
        move(subtree(top, children, membership), target)
        if not existing:
            pending.add(game)

    # 2. Stragglers.
    for pid in sorted(procs):
        parent = procs[pid].ppid
        target = membership.get(parent)
        meta = scopes.get(target) if target else None
        if pid in taken or not meta or meta.get('source') is None or now - meta.get('createdAt', 0) > STRAGGLER_SECONDS:
            continue
        if membership.get(pid) == meta['source']:
            move(subtree(pid, children, membership), target)

    # 3. Phone terminal sessions.
    for pid in sorted(procs):
        proc = procs[pid]
        parent = procs.get(proc.ppid)
        if pid in taken or membership.get(pid) != SESSION or parent is None or not terminal_service(parent.argv):
            continue
        move(subtree(pid, children, membership), NewScope('caboose-terminal', 'terminal', source=SESSION))
    for pid in sorted(procs):
        if pid in taken or membership.get(pid) != SESSION or not agent_runner(procs[pid].argv):
            continue
        move(subtree(pid, children, membership), NewScope('caboose-agent', 'agent', source=SESSION))

    # 4. Flatpak sandboxes in the session scope, each application into its own scope.
    sandboxes = {}
    for pid in sorted(procs):
        proc = procs[pid]
        if pid in taken or membership.get(pid) != SESSION or not proc.flatpak:
            continue
        top = pid
        while procs.get(top) and procs[top].ppid in procs and membership.get(procs[top].ppid) == SESSION and \
                procs[procs[top].ppid].argv and os.path.basename(procs[procs[top].ppid].argv[0]) in SANDBOX_LAUNCHERS:
            top = procs[top].ppid
        sandboxes.setdefault(proc.flatpak, [])
        if top not in sandboxes[proc.flatpak]:
            sandboxes[proc.flatpak].append(top)
    for app, tops in sandboxes.items():
        tree = []
        for top in tops:
            tree.extend(p for p in subtree(top, children, membership) if p not in tree)
        existing = sorted((m.get('createdAt', 0), name) for name, m in scopes.items()
                          if m.get('flatpak') == app or m.get('desktopId') == f'{app}.desktop')
        move(tree, existing[-1][1] if existing else
             NewScope(app, 'launch', desktop_id=f'{app}.desktop', source=SESSION, flatpak=app))

    # 5. Launch marks in the session scope.
    launches = {}
    for pid in sorted(procs):
        proc = procs[pid]
        if pid in taken or membership.get(pid) != SESSION or not proc.marks:
            continue
        launches.setdefault(proc.marks, []).append(pid)
    for (desktop_id, launched), pids in launches.items():
        tree = []
        for pid in pids:
            tree.extend(p for p in subtree(pid, children, membership) if p not in tree)
        move(tree, NewScope(scope_key(desktop_id), 'launch', desktop_id=desktop_id, source=SESSION))

    # 6. Windows.
    owners = {w['pid'] for w in windows if isinstance(w.get('pid'), int)}
    for window in windows:
        pid = window.get('pid')
        if window.get('kind') != 'toplevel' or window.get('parent') is not None or not isinstance(pid, int):
            continue
        scope = membership.get(pid)
        if pid in taken or scope is None:
            continue
        if scope != SESSION and scopes.get(scope, {}).get('origin') not in ('terminal', 'agent'):
            tty = procs[pid].tty
            above = [a for a in ancestors(pid, procs) if membership.get(a) == scope]
            if not tty or not any(a in owners and procs[a].tty != tty for a in above):
                continue
        desktop_id = window.get('desktop_id') if valid_desktop_id(window.get('desktop_id')) else None
        app_id = window.get('app_id') or None
        key = scope_key(desktop_id) if desktop_id else (app_id or procs[pid].comm or 'app')
        move(subtree(pid, children, membership), NewScope(key, 'window', desktop_id=desktop_id, app_id=app_id, source=scope))
    return moves


# -- Snapshot ------------------------------------------------------------------------------

def percent(delta, seconds):
    return round(max(0.0, delta / seconds * 100), 1) if seconds > 0 else 0.0


def rate(delta, seconds):
    return max(0, round(delta / seconds)) if seconds > 0 else 0


def app_entry(name, meta, sample, previous, seconds, processes, windows, gpu):
    """One app of the snapshot. `sample` and `previous` are the scope's counters now and at
    the last sample (`cpu_usec`, `read`, `written`, `memory`); `processes` its processes,
    each with `cpu` already a percentage; `gpu` its summed GPU use or None."""
    cpu = sample['cpu_usec'] - previous['cpu_usec'] if previous else 0
    read = sample['read'] - previous['read'] if previous else 0
    written = sample['written'] - previous['written'] if previous else 0
    ordered = sorted(processes, key=lambda p: (-p['cpuPercent'], -p['memoryBytes'], p['pid']))
    return {
        'id': name,
        'kind': 'session' if name == SESSION else 'app',
        'desktopId': meta.get('desktopId'),
        'name': (meta.get('name') or 'App')[:MAX_NAME],
        'origin': meta.get('origin', 'session'),
        'startedAt': int(meta.get('createdAt', 0) * 1000),
        'windows': sorted(windows),
        'cpuPercent': percent(cpu / 1e6, seconds),
        'memoryBytes': sample['memory'],
        'io': {'readBytesPerSecond': rate(read, seconds), 'writeBytesPerSecond': rate(written, seconds)},
        'gpu': gpu,
        'processCount': len(processes),
        'processes': ordered[:MAX_PROCESSES],
    }


def process_entry(pid, ppid, comm, argv, state, cpu_percent, memory):
    command = ' '.join(argv) if argv else ''
    return {'pid': pid, 'ppid': ppid, 'name': comm[:MAX_COMM], 'command': command[:MAX_COMMAND],
            'state': state_name(state), 'cpuPercent': cpu_percent, 'memoryBytes': memory}


def gpu_usage(entries, previous, seconds):
    """Summed GPU use of an app's processes from the broker's per-process counters: live
    streams and surfaces, and bytes per second each way. None without a GPU connection."""
    if not entries:
        return None
    streams = sum(e['streams'] for e in entries)
    surfaces = sum(e['surfaces'] for e in entries)
    to_phone = from_phone = 0
    for e in entries:
        before = previous.get((e['pid'], e['start']))
        if before:
            to_phone += e['toPhoneBytes'] - before['toPhoneBytes']
            from_phone += e['fromPhoneBytes'] - before['fromPhoneBytes']
    return {'streams': streams, 'surfaces': surfaces,
            'toPhoneBytesPerSecond': rate(to_phone, seconds), 'fromPhoneBytesPerSecond': rate(from_phone, seconds)}


def parse_gpu_usage(data):
    """The broker's usage file: {version: 1, processes: [{pid, start, streams, surfaces,
    toPhoneBytes, fromPhoneBytes}]}, checked field by field."""
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('processes'), list):
        return []
    out = []
    for entry in data['processes'][:256]:
        if not isinstance(entry, dict):
            continue
        values = [entry.get(k) for k in ('pid', 'start', 'streams', 'surfaces', 'toPhoneBytes', 'fromPhoneBytes')]
        if all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in values) and values[0] > 0:
            out.append(dict(zip(('pid', 'start', 'streams', 'surfaces', 'toPhoneBytes', 'fromPhoneBytes'), values)))
    return out
