#!/bin/sh
# Check that a Debian app installed through AppStream discovery, before the Library offered
# Flathub, is rediscovered from its operation record. Runs in a disposable guest.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
docker run --rm -i -v "$root/apps/host/src/guest-store.py:/tmp/store.py:ro" -v "$root/apps/host/src/guest-catalog.py:/tmp/catalog.py:ro" debian:trixie-slim sh -s <<'GUEST'
set -eu
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends appstream gir1.2-appstream-1.0 python3-gi >/dev/null
apt-get update -qq
/usr/bin/python3 - <<'PY'
import json, subprocess
run = lambda *args: subprocess.check_output(args, text=True)
app = {'id': 'debian-mousepad', 'source': {'kind': 'apt', 'packages': ['mousepad']}, 'storeComponent': 'org.xfce.mousepad'}
subprocess.run(['/usr/bin/python3', '/tmp/catalog.py', 'install', json.dumps(app)], check=True)
state = json.loads(run('/usr/bin/python3', '/tmp/catalog.py', 'list', json.dumps([app])))['apps'][app['id']]
assert state['installedVersion'] and not state['active'] and not state['interrupted'], state
restored = json.loads(run('/usr/bin/python3', '/tmp/store.py', json.dumps({'restore': True})))
item = next(item for item in restored if item['id'] == app['id'])
assert subprocess.run(['test', '-f', '/usr/share/applications/' + item['desktopId']]).returncode == 0
print('PASS', app['id'], state['installedVersion'], item['desktopId'], 'restored')
PY
GUEST
