"""Validate the entire signed-metadata-locked closure before private extraction."""
import hashlib, json, pathlib, subprocess, tarfile, tempfile
root = pathlib.Path('/task')
rows = json.loads((root / 'dependencies.json').read_text())
total = 0
archives = []
for row in rows:
    deb = root / 'debs' / row['name']
    assert deb.stat().st_size == row['size']
    assert hashlib.file_digest(deb.open('rb'), 'sha256').hexdigest() == row['sha256']
    # dpkg-deb only decompresses here; no maintainer scripts are executed.
    tmp = tempfile.TemporaryFile()
    subprocess.run(['dpkg-deb', '--fsys-tarfile', str(deb)], stdout=tmp, check=True)
    tmp.seek(0)
    tar = tarfile.open(fileobj=tmp)
    for item in tar.getmembers():
        path = pathlib.PurePosixPath(item.name)
        assert not path.is_absolute() and '..' not in path.parts
        assert item.isfile() or item.isdir() or item.issym() or item.islnk()
        # Package links may refer to /usr: rewrite absolute links into this sysroot.
        if item.issym() or item.islnk():
            target = pathlib.PurePosixPath(item.linkname)
            stack = [] if target.is_absolute() or item.islnk() else list(path.parent.parts)
            for part in target.parts:
                if part in ('/', '.', ''): continue
                if part == '..':
                    assert stack
                    stack.pop()
                else: stack.append(part)
        total += item.size
        assert total <= 1024**3
    archives.append((tmp,tar))
print('Verified extracted bound', total)
dest = root / 'deps'
dest.mkdir(exist_ok=True)
# Python data filter confines links and removes dangerous permissions.
for tmp,tar in archives:
    for item in tar.getmembers():
        if item.issym() and item.linkname.startswith('/'):
            import os
            item.linkname = os.path.relpath(dest / item.linkname.lstrip('/'), dest / pathlib.Path(item.name).parent)
        tar.extract(item, dest, filter='data')
    tar.close(); tmp.close()
