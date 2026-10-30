#!/bin/sh
# Inside the pinned decoder image, private task mounted at /task, network disabled.
set -eu
export PATH=/task/deps/usr/bin:$PATH
export LD_LIBRARY_PATH=/task/deps/usr/lib/x86_64-linux-gnu:/task/deps/usr/lib/x86_64-linux-gnu/pulseaudio
export SOURCE_DATE_EPOCH=1793318400
export LC_ALL=C TZ=UTC
cd /task
python3 - <<'PY'
import pathlib,json,hashlib
from prepare import extract
for row in json.loads(pathlib.Path('inputs.json').read_text()):
 if row['name']=='librequake-source.tar.gz': continue
 p=pathlib.Path(row['name']); assert p.stat().st_size==row['size']
 assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==row['sha256']
 dest=pathlib.Path(row['name']+'.extracted')
 if not dest.exists(): extract(p,dest,row['extracted_limit'])
PY
src=/task/vkquake.tar.gz.extracted/vkQuake-749b4fd43fe8b8554b34163dc9469c4a08a4def1
mkdir -p /task/bundle
export CFLAGS='-I/task/vulkan-headers.tar.gz.extracted/Vulkan-Headers-b5c8f996196ba4aa6d8f97e52b5d3b6e70f7e4e2/include -I/task/deps/usr/include -I/task/deps/usr/include/x86_64-linux-gnu'
make -C "$src/Quake" -j2 USE_SDL3=0 SDL_CONFIG='/task/deps/usr/bin/sdl2-config --prefix=/task/deps/usr' LDFLAGS='-L/task/deps/usr/lib/x86_64-linux-gnu -Wl,-rpath-link,/task/deps/usr/lib/x86_64-linux-gnu -Wl,-rpath-link,/task/deps/usr/lib/x86_64-linux-gnu/pulseaudio'
cp "$src/Quake/vkquake" /task/bundle/
cp -a /task/lite.zip.extracted/lite/id1 /task/bundle/
ldd /task/bundle/vkquake > /task/ldd.txt
sha256sum /task/bundle/vkquake > /task/binary.sha256
readelf -d /task/bundle/vkquake > /task/elf-dynamic.txt
python3 /task/package.py /task
