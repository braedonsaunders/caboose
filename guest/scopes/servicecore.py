"""Services: the pure logic of caboose-scopes' service manager, without any I/O.

A service is a long-running program the computer keeps running whether or not anyone is
looking: a database, a media server, a dev server. Each is declared in a unit file, a small
subset of systemd's format, and runs in a cgroup of its own. This module parses and writes
unit files, orders services by their dependencies, decides when a stopped service starts
again, and reads the kernel's socket tables for the ports services listen on.
"""
import configparser
import re
import shlex

NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}')
SUFFIX = '.service'
RESTARTS = ('no', 'on-failure', 'always')
TYPES = ('simple', 'forking', 'oneshot')
# A service that starts this many times within the window stops being restarted.
BURST, BURST_SECONDS = 5, 60.0
MAX_UNIT = 64 * 1024
MAX_ARGS = 256
MAX_ENV = 128


class UnitError(ValueError):
    pass


def valid_name(name):
    return isinstance(name, str) and bool(NAME.fullmatch(name)) and not name.endswith(SUFFIX)


def _words(value):
    return [w for w in value.replace(',', ' ').split() if w]


def _deps(value):
    out = []
    for word in _words(value):
        name = word[:-len(SUFFIX)] if word.endswith(SUFFIX) else word
        if not valid_name(name):
            raise UnitError(f'invalid dependency {word!r}')
        if name not in out:
            out.append(name)
    return out


def _environment(lines):
    env = {}
    for line in lines:
        try:
            words = shlex.split(line)
        except ValueError as error:
            raise UnitError(f'Environment: {error}') from None
        for word in words:
            key, sep, value = word.partition('=')
            if not sep or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
                raise UnitError(f'Environment: invalid assignment {word!r}')
            env[key] = value
    if len(env) > MAX_ENV:
        raise UnitError('Environment: too many variables')
    return env


def _seconds(value, key, default):
    if value is None or value == '':
        return default
    match = re.fullmatch(r'([0-9]+(?:\.[0-9]+)?)\s*(ms|s|min)?', value.strip())
    if not match:
        raise UnitError(f'{key}: not a duration')
    number = float(match.group(1)) * {'ms': 0.001, 's': 1, 'min': 60, None: 1}[match.group(2)]
    if number > 3600:
        raise UnitError(f'{key}: at most an hour')
    return number


def parse_unit(name, text, system):
    """A unit file's settings, checked. `system` units (under /etc) may name a User; the
    owner's always run as the owner."""
    if not valid_name(name):
        raise UnitError('invalid service name')
    if len(text) > MAX_UNIT:
        raise UnitError('unit file too large')
    parser = configparser.ConfigParser(interpolation=None, strict=False, delimiters=('=',),
                                       comment_prefixes=('#', ';'), empty_lines_in_values=False)
    parser.optionxform = str
    try:
        parser.read_string(_join_repeats(text))
    except configparser.Error as error:
        raise UnitError(f'unit file: {error}') from None
    unit = parser['Unit'] if parser.has_section('Unit') else {}
    service = parser['Service'] if parser.has_section('Service') else None
    install = parser['Install'] if parser.has_section('Install') else {}
    if service is None or not service.get('ExecStart', '').strip():
        raise UnitError('a [Service] section with ExecStart is required')
    try:
        argv = shlex.split(service['ExecStart'].strip().lstrip('-@+!:'))
    except ValueError as error:
        raise UnitError(f'ExecStart: {error}') from None
    if not argv or len(argv) > MAX_ARGS:
        raise UnitError('ExecStart: no command, or too many arguments')
    kind = service.get('Type', 'simple').strip() or 'simple'
    if kind not in TYPES:
        raise UnitError(f'Type: one of {", ".join(TYPES)}')
    restart = service.get('Restart', 'on-failure').strip() or 'on-failure'
    if restart not in RESTARTS:
        raise UnitError(f'Restart: one of {", ".join(RESTARTS)}')
    user = (service.get('User') or '').strip() or None
    if user is not None and not system:
        raise UnitError('User: only system services may choose their user')
    directory = (service.get('WorkingDirectory') or '').strip() or None
    if directory is not None and not (directory.startswith('/') or directory == '~'):
        raise UnitError('WorkingDirectory: an absolute path')
    wanted = _words(install.get('WantedBy', ''))
    return {
        'name': name,
        'description': (unit.get('Description') or '').strip()[:200] or name,
        'argv': argv,
        'type': kind,
        'restart': restart,
        'restartSec': _seconds(service.get('RestartSec'), 'RestartSec', 2.0),
        'stopSec': _seconds(service.get('TimeoutStopSec'), 'TimeoutStopSec', 10.0),
        'user': user,
        'directory': directory,
        'environment': _environment((service.get('Environment') or '').split('\n')),
        'requires': _deps(unit.get('Requires', '')),
        'after': _deps(unit.get('After', '')),
        'autostart': any(w in ('default.target', 'multi-user.target') for w in wanted),
    }


def _join_repeats(text):
    """configparser keeps the last of repeated keys; Environment= may repeat, so repeats of it
    become one value of several lines."""
    out, seen = [], {}
    section = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('['):
            section = stripped
            out.append(line)
            continue
        key, sep, value = stripped.partition('=')
        if sep and key.strip() == 'Environment' and (section, 'Environment') in seen:
            out[seen[(section, 'Environment')]] += '\n  ' + value.strip()
            continue
        if sep and key.strip() == 'Environment':
            seen[(section, 'Environment')] = len(out)
        out.append(line)
    return '\n'.join(out) + '\n'


def render_unit(definition):
    """A unit file from the API's definition: {description?, command: [argv], workingDirectory?,
    environment?: {K: V}, restart?, autostart?, requires?}. Checked by parsing it back."""
    if not isinstance(definition, dict):
        raise UnitError('a definition is an object')
    known = {'description', 'command', 'workingDirectory', 'environment', 'restart', 'autostart', 'requires'}
    unknown = set(definition) - known
    if unknown:
        raise UnitError(f'unknown field {sorted(unknown)[0]}')
    command = definition.get('command')
    if not isinstance(command, list) or not command or len(command) > MAX_ARGS or \
            not all(isinstance(a, str) and a and '\0' not in a and '\n' not in a for a in command):
        raise UnitError('command: a list of 1 to 256 arguments')
    lines = ['[Unit]']
    description = definition.get('description')
    if description is not None:
        if not isinstance(description, str) or len(description) > 200 or re.search(r'[\x00-\x1f\x7f]', description):
            raise UnitError('description: one line of at most 200 characters')
        lines.append(f'Description={description}')
    requires = definition.get('requires', [])
    if not isinstance(requires, list) or not all(valid_name(r) for r in requires):
        raise UnitError('requires: service names')
    if requires:
        names = ' '.join(f'{r}{SUFFIX}' for r in requires)
        lines += [f'Requires={names}', f'After={names}']
    lines += ['', '[Service]', 'ExecStart=' + shlex.join(command)]
    directory = definition.get('workingDirectory')
    if directory is not None:
        if not isinstance(directory, str) or not directory.startswith('/') or re.search(r'[\x00-\x1f\x7f]', directory):
            raise UnitError('workingDirectory: an absolute path')
        lines.append(f'WorkingDirectory={directory}')
    environment = definition.get('environment', {})
    if not isinstance(environment, dict) or len(environment) > MAX_ENV:
        raise UnitError('environment: an object of at most 128 variables')
    for key, value in environment.items():
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key) or not isinstance(value, str) or re.search(r'[\x00\n\r]', value):
            raise UnitError(f'environment: invalid variable {key!r}')
        lines.append('Environment=' + shlex.quote(f'{key}={value}'))
    restart = definition.get('restart', 'on-failure')
    if restart not in RESTARTS:
        raise UnitError(f'restart: one of {", ".join(RESTARTS)}')
    lines.append(f'Restart={restart}')
    autostart = definition.get('autostart', True)
    if not isinstance(autostart, bool):
        raise UnitError('autostart: a boolean')
    if autostart:
        lines += ['', '[Install]', 'WantedBy=default.target']
    return '\n'.join(lines) + '\n'


def set_autostart(text, enabled):
    """The unit file with its [Install] WantedBy set or removed, other lines untouched."""
    out, section, done = [], None, False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('['):
            if section == '[Install]' and enabled and not done:
                out.append('WantedBy=default.target')
                done = True
            section = stripped
        elif section == '[Install]' and stripped.partition('=')[0].strip() == 'WantedBy':
            if enabled and not done:
                out.append('WantedBy=default.target')
                done = True
            continue
        out.append(line)
    if enabled and not done:
        if section != '[Install]':
            out += ['', '[Install]']
        out.append('WantedBy=default.target')
    return '\n'.join(out).rstrip('\n') + '\n'


def start_order(units, names):
    """`names` and everything they require, dependencies first (Requires and After order;
    After names a service only when it is being started too). Returns (order, cyclic), where
    `cyclic` are the services in or behind a dependency cycle, left out of `order`; a
    required service without a unit is reported as cyclic too, with the ones needing it."""
    wanted, stack = [], list(names)
    while stack:
        name = stack.pop()
        if name in wanted:
            continue
        wanted.append(name)
        stack.extend(units[name]['requires'] if name in units else [])
    order, done, broken = [], set(), set()

    def visit(name, path):
        if name in done:
            return name not in broken
        if name in path or name not in units:
            broken.update(path[path.index(name):] if name in path else [name])
            return False
        unit, ok = units[name], True
        for dep in unit['requires']:
            ok = visit(dep, [*path, name]) and ok
        for dep in unit['after']:
            if dep in wanted and dep in units and dep not in unit['requires']:
                visit(dep, [*path, name])
        done.add(name)
        if ok and name not in broken:
            order.append(name)
            return True
        broken.add(name)
        return False

    for name in sorted(wanted):
        visit(name, [])
    return order, sorted(broken)


def dependents(units, name):
    """Services that require `name`, directly or not: they stop before it does."""
    out, stack = [], [name]
    while stack:
        current = stack.pop()
        for other, unit in sorted(units.items()):
            if current in unit['requires'] and other not in out and other != name:
                out.append(other)
                stack.append(other)
    return out


def restart_decision(unit, exit_code, stopping, starts, now):
    """After a service's process ended: 'stop' (an asked stop, or nothing to restart),
    'restart', or 'fail' (a failure not restarted, or too many starts). `starts` are the
    times it was started."""
    if stopping:
        return 'stop'
    success = exit_code == 0
    again = unit['restart'] == 'always' or (unit['restart'] == 'on-failure' and not success)
    if unit['type'] == 'oneshot' and success:
        return 'stop'
    if not again:
        return 'stop' if success else 'fail'
    if len([t for t in starts if now - t <= BURST_SECONDS]) >= BURST:
        return 'fail'
    return 'restart'


# -- Listening sockets ----------------------------------------------------------------------

def _address(hex_address, family):
    if family == 4:
        raw = bytes.fromhex(hex_address)
        return '.'.join(str(b) for b in raw[::-1])
    raw = bytes.fromhex(hex_address)
    words = [raw[i:i + 4][::-1] for i in range(0, 16, 4)]
    data = b''.join(words)
    if data[:12] == b'\0' * 10 + b'\xff\xff':
        return '.'.join(str(b) for b in data[12:])
    groups = [f'{int.from_bytes(data[i:i + 2], "big"):x}' for i in range(0, 16, 2)]
    text = ':'.join(groups)
    # The usual shortening of the longest run of zero groups.
    best = max((m for m in re.finditer(r'(?:^|:)0(?::0)+(?::|$)', text)), key=lambda m: len(m.group()), default=None)
    if best:
        text = text[:best.start()] + '::' + text[best.end():]
    return text


def listening(table, protocol, family):
    """Listening sockets from /proc/net/{tcp,tcp6,udp,udp6}: [(protocol, address, port, inode)].
    TCP sockets in LISTEN; UDP sockets bound with no peer."""
    out = []
    for line in table.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 10:
            continue
        local, remote, state, inode = fields[1], fields[2], fields[3], fields[9]
        address, _, port = local.partition(':')
        if protocol == 'tcp' and state != '0A':
            continue
        if protocol == 'udp' and (state != '07' or not remote.endswith(':0000')):
            continue
        try:
            out.append((protocol, _address(address, family), int(port, 16), int(inode)))
        except ValueError:
            continue
    return out


def socket_inodes(links):
    """The socket inodes among a process's /proc/<pid>/fd link targets."""
    out = set()
    for link in links:
        match = re.fullmatch(r'socket:\[([0-9]+)\]', link)
        if match:
            out.add(int(match.group(1)))
    return out


def established(table, family):
    """(local port, peer address) of each ESTABLISHED connection in /proc/net/tcp{,6}."""
    out = []
    for line in table.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 4 or fields[3] != '01':
            continue
        local, remote = fields[1], fields[2]
        try:
            out.append((int(local.partition(':')[2], 16), _address(remote.partition(':')[0], family)))
        except ValueError:
            continue
    return out


def loopback(address):
    return address.startswith('127.') or address == '::1'
