#!/usr/bin/env python3
"""Replay the reviewed dependency lock; does not resolve or install packages."""
import hashlib, json, pathlib, subprocess, sys, time
rows=json.loads(pathlib.Path(__file__).with_name('dependencies.json').read_text())
assert sum(r['size'] for r in rows)<=256*1024**2
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
deadline=time.monotonic()+180
for r in rows:
    assert pathlib.Path(r['name']).name==r['name']
    p=root/r['name']
    if not p.exists():
        remaining=int(deadline-time.monotonic()); assert remaining>0
        part=p.with_suffix('.part')
        subprocess.run(['curl','-fL','--max-time',str(remaining),'--max-filesize',str(r['size']),'-o',str(part),r['url']],check=True)
        assert part.stat().st_size==r['size']
        assert hashlib.file_digest(part.open('rb'),'sha256').hexdigest()==r['sha256']
        part.rename(p)
    assert p.stat().st_size==r['size']
    assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==r['sha256']
