#!/usr/bin/env python3
"""Fetch hash-locked inputs into a new private directory and safely extract them."""
import hashlib, json, pathlib, shutil, subprocess, sys, tarfile, zipfile

def validate(names, sizes, limit):
    seen = set()
    assert sum(sizes) <= limit, 'extracted size exceeds bound'
    for name in names:
        p = pathlib.PurePosixPath(name)
        assert name and not p.is_absolute() and '..' not in p.parts and '\\' not in name
        assert str(p) not in seen, 'duplicate member'
        seen.add(str(p))

def extract(path, dest, limit):
    assert not dest.exists(), 'destination must be new'
    if path.suffix == '.zip':
        with zipfile.ZipFile(path) as z:
            entries = z.infolist()
            validate([x.filename for x in entries], [x.file_size for x in entries], limit)
            assert all((x.external_attr >> 16 & 0o170000) in (0,0o040000,0o100000) for x in entries)
            z.extractall(dest)
    else:
        with tarfile.open(path) as t:
            entries=t.getmembers()
            validate([x.name for x in entries], [x.size for x in entries], limit)
            assert all(x.isfile() or x.isdir() for x in entries), 'links/devices forbidden'
            t.extractall(dest)

def main():
    root=pathlib.Path(sys.argv[1]).resolve(); root.mkdir(parents=True,exist_ok=True)
    for row in json.loads(pathlib.Path(__file__).with_name('inputs.json').read_text()):
        p=root/row['name']
        if not p.exists():
            part=p.with_suffix(p.suffix+'.part')
            subprocess.run(['curl','--fail','--location','--max-time','120','--max-filesize',str(row['size']),'--output',str(part),row['url']],check=True)
            assert part.stat().st_size == row['size']
            assert hashlib.file_digest(part.open('rb'),'sha256').hexdigest()==row['sha256']
            part.rename(p)
        assert p.stat().st_size == row['size']
        assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==row['sha256']
        extract(p, root/(row['name']+'.extracted'),row['extracted_limit'])
if __name__=='__main__': main()
