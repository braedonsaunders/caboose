"""Bounded JSON-line RPC for one read-only libguestfs appliance.

Guest bytes are data only. Never run a program from the mounted computer.
"""
import ast
import base64
import json
import os
import posixpath
import signal
import sys

MAX_FRAME = 2 * 1024 * 1024


def literal_mime(g):
    """Read the guest Python MIME data without importing/executing guest code."""
    sources = g.glob_expand('/usr/lib/python3.*/mimetypes.py')
    if len(sources) != 1:
        raise ValueError('ambiguous guest MIME database')
    source = bounded_read(g, sources[0], 256 * 1024).decode('utf8')
    tree = ast.parse(source)
    tables = {}
    known = None
    nodes = list(tree.body)
    for branch in tree.body:
        # Python 3.15 excludes these POSIX paths on Windows. Select only this
        # recognized platform branch; never evaluate a guest expression.
        if (isinstance(branch, ast.If) and isinstance(branch.test, ast.Compare)
            and isinstance(branch.test.left, ast.Attribute) and branch.test.left.attr == 'platform'
            and isinstance(branch.test.left.value, ast.Name) and branch.test.left.value.id == 'sys'
            and len(branch.test.ops) == 1 and isinstance(branch.test.ops[0], ast.Eq)
            and len(branch.test.comparators) == 1 and isinstance(branch.test.comparators[0], ast.Constant)
            and branch.test.comparators[0].value == 'win32'):
            nodes.extend(branch.orelse)
    for node in nodes:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'knownfiles' for t in node.targets):
            known = ast.literal_eval(node.value)
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == 'knownfiles':
            known = ast.literal_eval(node.value)
        if isinstance(node, ast.FunctionDef) and node.name == '_default_mime_types':
            for assignment in node.body:
                if isinstance(assignment, ast.Assign):
                    for target in assignment.targets:
                        if isinstance(target, ast.Name) and target.id in ('types_map', 'suffix_map', 'encodings_map'):
                            tables[target.id] = ast.literal_eval(assignment.value)
    if set(tables) != {'types_map', 'suffix_map', 'encodings_map'} or not isinstance(known, list) or len(known) > 32:
        raise ValueError('unsupported guest MIME database')
    for table in tables.values():
        if not isinstance(table, dict) or len(table) > 10000 or any(not isinstance(k, str) or not isinstance(v, str) for k, v in table.items()):
            raise ValueError('invalid guest MIME table')
    for path in known:
        if not isinstance(path, str) or not path.startswith('/') or len(path) > 512:
            raise ValueError('invalid MIME path')
        if g.is_file(path):
            for line in bounded_read(g, path, 2 * 1024 * 1024).decode('utf8').splitlines():
                words = line.split('#', 1)[0].split()
                if words:
                    for extension in words[1:]:
                        tables['types_map']['.' + extension] = words[0]
    return tables


def bounded_read(g, path, limit):
    size = g.filesize(path)
    if size < 0 or size > limit:
        raise ValueError('appliance input exceeds limit')
    return g.read_file(path)


def guess_type(tables, name):
    base, ext = posixpath.splitext(name)
    for _ in range(16):
        suffix = tables['suffix_map'].get(ext.lower())
        if suffix is None:
            break
        base, ext = posixpath.splitext(base + suffix)
    else:
        raise ValueError('cyclic MIME suffix')
    if ext in tables['encodings_map']:
        base, ext = posixpath.splitext(base)
    result = tables['types_map'].get(ext.lower(), 'application/octet-stream')
    if not isinstance(result, str) or len(result) > 200 or any(ord(c) < 32 or ord(c) > 126 for c in result):
        raise ValueError('invalid MIME type')
    return result


def dispatch(g, request, mime):
    command, args = request['command'], request['args']
    if not isinstance(args, list) or len(args) > 4 or any(not isinstance(a, str) or len(a) > 4096 or '\0' in a for a in args):
        raise ValueError('invalid request')
    if command == 'lstatns' and len(args) == 1:
        return ''.join(f'{k}: {v}\n' for k, v in g.lstatns(args[0]).items())
    if command == 'lgetxattrs' and len(args) == 1:
        return 'present' if g.lgetxattrs(args[0]) else ''
    if command == 'readdir' and len(args) == 1:
        entries = g.readdir(args[0])
        if len(entries) > 130:
            raise ValueError('directory exceeds limit')
        return json.dumps(entries)
    if command == 'mime' and len(args) == 1:
        if not mime:
            mime.update(literal_mime(g))
        return guess_type(mime, args[0])
    if command == 'pread' and len(args) == 3:
        offset, count = int(args[1]), int(args[2])
        if offset < 0 or count < 0 or count > 256 * 1024:
            raise ValueError('invalid read range')
        return base64.b64encode(g.pread(args[0], count, offset)).decode('ascii')
    raise ValueError('unsupported operation')


def mount_root(g):
    filesystems = g.list_filesystems()
    # A partitioned image must use its root partition; do not fall back to a
    # different volume when that partition has an unsupported filesystem.
    root = '/dev/sda3' if '/dev/sda3' in filesystems else '/dev/sda'
    options = {'ext4': 'ro,noload', 'btrfs': 'ro,nologreplay'}
    filesystem = filesystems.get(root)
    if filesystem not in options:
        raise ValueError('unsupported root filesystem')
    # Read-only attachment alone uses a disposable COW overlay. Suppress replay
    # as well so the parked view reflects the frozen disk, not recovered state.
    g.mount_options(options[filesystem], root, '/')


def main():
    import guestfs
    image = sys.argv[1]
    if not os.path.isabs(image):
        raise ValueError('absolute image required')
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    g = guestfs.GuestFS(python_return_dict=True)
    try:
        g.set_backend('direct')
        g.set_network(False)
        g.set_memsize(256)
        g.add_drive_opts(image, readonly=True, format='raw')
        g.launch()
        mount_root(g)
        print(json.dumps({'ready': True}), flush=True)
        mime = {}
        while True:
            line = sys.stdin.buffer.readline(MAX_FRAME + 1)
            if not line:
                break
            if len(line) > MAX_FRAME or not line.endswith(b'\n'):
                raise ValueError('oversized RPC frame')
            request = json.loads(line)
            if set(request) != {'id', 'command', 'args'} or type(request['id']) is not int:
                raise ValueError('invalid RPC frame')
            result = dispatch(g, request, mime)
            frame = json.dumps({'id': request['id'], 'result': result}, ensure_ascii=True)
            if len(frame) > MAX_FRAME:
                raise ValueError('oversized RPC result')
            print(frame, flush=True)
    finally:
        g.close()


if __name__ == '__main__':
    main()
