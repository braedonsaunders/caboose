#!/bin/bash
# Check Flathub installs on the shared runtime depot in disposable Debian guests, never the
# owner's computer: the builder adds a runtime to a fresh depot volume, a second guest that
# mounts it read-only installs an app on it, runs it in Flatpak's sandbox under Caboose's
# seccomp profile, and removes it. Needs Docker and about 1 GB from Flathub.
#
#   apps/host/scripts/check-flathub.sh [app id]   (default: XClicker, a small app on the
#                                                  Freedesktop runtime)
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
app=${1:-xyz.xclicker.xclicker}
image=caboose-flathub-check
volume=caboose-flathub-check-$$
trap 'docker volume rm -f "$volume" >/dev/null 2>&1 || :' EXIT
docker build -q -t "$image" - >/dev/null <<'DOCKERFILE'
FROM debian:trixie-slim
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends flatpak gir1.2-flatpak-1.0 python3-gi ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
DOCKERFILE
security=(--security-opt "seccomp=$root/guest/container/caboose-seccomp.json")
guest=(-v "$root/guest/flatpak:/opt/flatpak:ro" -v "$root/apps/host/src:/opt/host:ro")
runtime=$(curl -fsS -X POST https://flathub.org/api/v2/search -H 'content-type: application/json' \
  -d "{\"query\":\"$app\",\"hits_per_page\":5}" | python3 -c "import json,sys; print(next(h['runtime'] for h in json.load(sys.stdin)['hits'] if h['app_id']==sys.argv[1]))" "$app")
arch=$(docker run --rm "$image" flatpak --default-arch)
runtime=${runtime/\/x86_64\//\/$arch\/}
echo "== builder adds $runtime to the depot"
docker run --rm "${security[@]}" "${guest[@]}" -v "$volume:/depot" "$image" sh -c \
  'sh /opt/flatpak/install.sh >/dev/null && python3 /opt/host/depot-builder.py /depot ensure "\"$1\""' sh "$runtime" | tail -n 1
echo "== a computer with the depot read-only installs, runs and removes $app"
docker run --rm -i "${security[@]}" "${guest[@]}" -v "$volume:/var/lib/caboose/depot:ro" "$image" bash -s "$app" "$runtime" <<'GUEST'
set -euo pipefail
app=$1 runtime=$2
sh /opt/flatpak/install.sh >/dev/null
entry=$(printf '{"id":"flathub-%s","operationId":"check","source":{"kind":"flatpak","appId":"%s","runtime":"%s"}}' "$app" "$app" "$runtime")
python3 /opt/host/guest-catalog.py install "$entry"
listing=$(python3 /opt/host/guest-catalog.py list '[]')
python3 - "$listing" "$app" "$runtime" <<'PY'
import json, sys
listing, app, runtime = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
state = listing['apps']['flathub-' + app]
assert listing['environment'] == {'flatpak': True, 'depot': True, 'arch': listing['environment']['arch']}, listing['environment']
assert state['installedVersion'] and not state['active'] and not state['lastError'], state
assert state['flatpak']['runtime'] == runtime, state
PY
# The runtime is the depot's: the computer's own installation holds only the app.
if flatpak list --system --runtime --columns=application,branch | grep -q "^${runtime%%/*}"; then
  echo "FAIL: $runtime was installed into the computer instead of used from the depot" >&2; exit 1
fi
flatpak list --installation=caboose-depot --runtime --columns=application,branch | grep -q "^${runtime%%/*}"
if touch /var/lib/caboose/depot/write-test 2>/dev/null; then echo 'FAIL: the depot is writable from a computer' >&2; exit 1; fi
test -f "/var/lib/flatpak/exports/share/applications/$app.desktop"
flatpak run --command=true "$app"
python3 /opt/host/guest-catalog.py remove "$entry"
python3 - "$(python3 /opt/host/guest-catalog.py list '[]')" "$app" <<'PY'
import json, sys
state = json.loads(sys.argv[1])['apps'].get('flathub-' + sys.argv[2], {})
assert not state.get('installedVersion'), state
PY
echo "PASS $app on $runtime from the read-only depot, sandboxed run, removed"
GUEST
