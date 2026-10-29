#!/bin/sh
# Exercise Debian discovery and installation in a disposable guest, not the owner's computer.
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
store = lambda value: json.loads(run('/usr/bin/python3', '/tmp/store.py', json.dumps(value)))
catalog = lambda action, value: json.loads(run('/usr/bin/python3', '/tmp/catalog.py', action, json.dumps(value)))
item = next(item for item in store('mousepad') if item['package'] == 'mousepad')
app = {'id': item['id'], 'source': {'kind': 'apt', 'packages': [item['package']]}, 'storeComponent': item['componentId']}
subprocess.run(['/usr/bin/python3', '/tmp/catalog.py', 'install', json.dumps(app)], check=True)
state = catalog('list', [app])[app['id']]
assert state['installedVersion'] and not state['active'] and not state['interrupted'], state
assert subprocess.run(['test', '-f', '/usr/share/applications/' + item['desktopId']]).returncode == 0
assert app['id'] in [entry['id'] for entry in store({'restore': True})]
print('PASS', app['id'], state['installedVersion'], item['desktopId'], 'restored')
PY
GUEST
