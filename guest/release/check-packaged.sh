#!/bin/sh
# Exercise the sealed payload's session, display, launcher and modules in isolation.
set -eu
image=$1
release=$(realpath "$2")
out=$3
mkdir -p "$out"
name=caboose-release-packaged-$$
cleanup() {
  docker exec "$name" cat /home/caboose/.cache/caboose-display.log > "$out/packaged-display.log" 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
docker run -d --name "$name" --init --network none --cpus 4 --memory 6g --shm-size 256m \
  -v "$release:/release:ro" --entrypoint /bin/sh "$image" -c 'exec sleep infinity' >/dev/null
docker exec "$name" sh -ec '
  cp -a /release/files/. /
  for deb in /release/debs/*.deb; do [ ! -f "$deb" ] || dpkg -i "$deb" >/dev/null; done
  /usr/local/libexec/caboose-gpu-broker --help >/dev/null
  mkdir -p /run/caboose /usr/local/lib/caboose-gpu-live
  printf "release-check-token" > /run/caboose/display-token
  chmod 0644 /run/caboose/display-token
  printf "%s" "{\"file_format_version\":\"1.0.1\",\"ICD\":{\"library_path\":\"/usr/local/lib/caboose-gpu-live/libvulkan_gfxstream.so\",\"api_version\":\"1.3.0\"}}" > /usr/local/lib/caboose-gpu-live/icd.json
  caboose-session start >/dev/null
'
docker exec -i "$name" python3 - <<'PY'
import base64, os, pathlib, socket, time, uuid
last = 'no attempt'
for _ in range(30):
    try:
        token = pathlib.Path('/run/caboose/display-token').read_text().strip()
        headers = ['GET /gpu HTTP/1.1', 'Host: localhost', 'Upgrade: websocket', 'Connection: Upgrade',
                   'Sec-WebSocket-Version: 13', 'Sec-WebSocket-Protocol: caboose.gpu.live.v1',
                   'Sec-WebSocket-Key: ' + base64.b64encode(os.urandom(16)).decode(),
                   'Authorization: Bearer ' + token, 'X-Caboose-GPU-Computer: release-check',
                   'X-Caboose-GPU-Executor: ' + str(uuid.uuid4())]
        with socket.create_connection(('127.0.0.1', 14600), timeout=2) as s:
            s.sendall(('\r\n'.join(headers) + '\r\n\r\n').encode())
            last = s.recv(4096).split(b'\r\n')[0].decode()
            if last == 'HTTP/1.1 101 Switching Protocols':
                print('PASS packaged session/display/broker: authenticated /gpu upgrade')
                break
    except (OSError, ValueError) as e:
        last = str(e)
    time.sleep(1)
else:
    raise SystemExit('FAIL packaged GPU admission: ' + last)
PY
