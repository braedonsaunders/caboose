#!/usr/bin/env bash
# Checks a bundle from bundle.sh the way an installer uses it: extract it, start
# bin/caboose-host through a symlink with a fresh state directory, and expect the console
# at / (200), the API to require the generated owner token (401 without, 200 with), and the
# bundled Node (and Cloud Hypervisor on Linux) to be the ones in use.
#
#   apps/host/scripts/check-bundle.sh <caboose-host-<os>-<arch>.tar.zst>
set -euo pipefail

bundle=${1:?usage: check-bundle.sh <bundle.tar.zst>}
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-bundle.XXXXXX")
pid=
cleanup() {
  if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

zstd -dc "$bundle" | tar -xf - -C "$work"
host=$work/caboose-host
for path in bin/caboose-host bin/caboose-setup-disks node/bin/node app/apps/host/dist/index.js app/apps/web/dist/index.html \
  app/guest/components/manifest.json app/guest/catalog/catalog.json VERSION defaults.env; do
  [[ -e $host/$path ]] || { echo "FAIL: the bundle lacks $path" >&2; exit 1; }
done
missing=$(cd "$host/app/guest" && "$host/node/bin/node" -e '
  const fs = require("fs")
  console.log(JSON.parse(fs.readFileSync("components/manifest.json", "utf8")).filter(name => !fs.existsSync(name)).join(" "))')
[[ -z $missing ]] || { echo "FAIL: the bundle lacks guest components: $missing" >&2; exit 1; }
[[ $("$host/node/bin/node" --version) == v22.* ]] || { echo 'FAIL: the bundled Node is not 22' >&2; exit 1; }
case $bundle in
  *linux-*) [[ -x $host/bin/cloud-hypervisor ]] || { echo 'FAIL: a Linux bundle lacks Cloud Hypervisor' >&2; exit 1; } ;;
esac

port=$("$host/node/bin/node" -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
mkdir -p "$work/state" "$work/bin"
ln -s "$host/bin/caboose-host" "$work/bin/caboose-host"
env -i PATH=/usr/bin:/bin HOME="$work" CABOOSE_PORT="$port" CABOOSE_IMAGE_ROOT="$work/state" CABOOSE_MDNS=off \
  "$work/bin/caboose-host" >"$work/host.log" 2>&1 &
pid=$!

for _ in $(seq 1 100); do
  [[ -s $work/state/owner-token ]] && curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
  kill -0 "$pid" 2>/dev/null || { cat "$work/host.log" >&2; echo 'FAIL: the host exited' >&2; exit 1; }
  sleep 0.2
done
token=$(cat "$work/state/owner-token")
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
[[ $(status "http://127.0.0.1:$port/") == 200 ]] || { echo 'FAIL: the console is not served' >&2; exit 1; }
[[ $(status "http://127.0.0.1:$port/v1/health") == 401 ]] || { echo 'FAIL: /v1/health answers without a token' >&2; exit 1; }
[[ $(status -H "authorization: Bearer $token" "http://127.0.0.1:$port/v1/health") == 200 ]] || { echo 'FAIL: /v1/health refuses the owner token' >&2; exit 1; }
echo "ok: $(basename "$bundle") $(cat "$host/VERSION") serves the console and API on port $port"
