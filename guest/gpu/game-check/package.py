#!/usr/bin/env python3
"""Retain notices and hash every deliverable; does not execute the game."""
import hashlib,json,pathlib,shutil,sys,tarfile
root=pathlib.Path(sys.argv[1]).resolve(); bundle=root/'bundle'
source=root/'vkquake.tar.gz.extracted'/'vkQuake-749b4fd43fe8b8554b34163dc9469c4a08a4def1'
# Compilation must not have changed a single pre-existing upstream source file.
with tarfile.open(root/'vkquake.tar.gz') as t:
    for entry in t.getmembers():
        if not entry.isfile(): continue
        actual=root/'vkquake.tar.gz.extracted'/entry.name
        assert hashlib.sha256(actual.read_bytes()).digest()==hashlib.sha256(t.extractfile(entry).read()).digest(),entry.name
notices=bundle/'licenses'; notices.mkdir(exist_ok=True)
shutil.copy2(source/'LICENSE.txt',notices/'vkQuake-GPL-2.0.txt')
shutil.copy2(source/'Quake/mimalloc/LICENSE',notices/'mimalloc-MIT.txt')
for name in ('inputs.json','launch.sh'):
    shutil.copy2(pathlib.Path(__file__).with_name(name),bundle/name)
rows=[]
for p in sorted(bundle.rglob('*')):
    if p.is_file() and p.name!='manifest.json':
        rows.append(dict(path=str(p.relative_to(bundle)),size=p.stat().st_size,sha256=hashlib.file_digest(p.open('rb'),'sha256').hexdigest()))
(bundle/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n')
print('Verified unchanged upstream files; bundled',len(rows),'files')
