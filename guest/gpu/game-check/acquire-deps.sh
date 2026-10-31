#!/bin/sh
# Run only in a disposable Debian trixie/amd64 container, /task private mount.
set -eu
export DEBIAN_FRONTEND=noninteractive
mkdir -p /task/debs/partial /task/lists/partial
opts='-o Dir::State::status=/task/decoder-status -o Dir::State::lists=/task/lists -o Dir::Cache::archives=/task/debs -o APT::Install-Recommends=false'
apt-get $opts update
apt-get $opts --print-uris --yes --reinstall install make pkg-config libsdl2-dev glslang-tools spirv-tools libvorbis-dev libmpg123-dev > /task/dependency-uris.txt
python3 - <<'PY'
import pathlib,shlex,json,subprocess,urllib.parse
rows=[]
for line in pathlib.Path('/task/dependency-uris.txt').read_text().splitlines():
 if not line.startswith("'"): continue
 url,name,size=shlex.split(line)[:3]
 assert url.startswith(('http://deb.debian.org/','https://deb.debian.org/'))
 package,version,arch=name.rsplit('_',2)
 version=urllib.parse.unquote(version)
 metadata=subprocess.check_output(['apt-cache','-o','Dir::State::lists=/task/lists','show',package+'='+version],text=True)
 fields=dict(line.split(': ',1) for line in metadata.split('\n\n')[0].splitlines() if ': ' in line and not line.startswith(' '))
 assert fields['Size']==size
 digest='SHA256:'+fields['SHA256']
 assert '/' not in name and '..' not in name
 rows.append(dict(url=url,name=name,size=int(size),sha256=digest[7:]))
assert rows and sum(r['size'] for r in rows)<=256*1024**2
pathlib.Path('/task/dependencies.json').write_text(json.dumps(rows,indent=2)+'\n')
print('Download bound',len(rows),sum(r['size'] for r in rows))
PY
apt-get $opts --yes --download-only --reinstall install make pkg-config libsdl2-dev glslang-tools spirv-tools libvorbis-dev libmpg123-dev
python3 /task/scripts/extract-debs.py
