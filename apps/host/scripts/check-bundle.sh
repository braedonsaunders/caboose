#!/usr/bin/env bash
# Checks a bundle from bundle.sh the way an installer uses it: extract it, start
# bin/caboose-host through a symlink with a fresh state directory, and expect the console
# at / (200), the API to require the generated owner token (401 without, 200 with), and the
# bundled Node (and Cloud Hypervisor on Linux) to be the ones in use. Also claims
# the fresh embedded identity database using its setup code and checks the operator session.
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

case $bundle in
  *.tar.gz) tar -xzf "$bundle" -C "$work" ;;
  *.tar.zst) zstd -dc "$bundle" | tar -xf - -C "$work" ;;
  *) echo 'Expected a .tar.gz or .tar.zst bundle' >&2; exit 2 ;;
esac
host=$work/caboose-host
for path in bin/caboose-host bin/caboose-setup-disks node/bin/node app/apps/host/dist/index.js app/apps/web/dist/index.html \
  app/guest/components/manifest.json app/guest/catalog/catalog.json app/guest/container/caboose-seccomp.json app/apps/host/dist/depot-builder.py app/apps/host/migrations/meta/_journal.json VERSION defaults.env; do
  [[ -e $host/$path ]] || { echo "FAIL: the bundle lacks $path" >&2; exit 1; }
done
missing=$(cd "$host/app/guest" && "$host/node/bin/node" -e '
  const fs = require("fs")
  console.log(JSON.parse(fs.readFileSync("components/manifest.json", "utf8")).filter(name => !fs.existsSync(name)).join(" "))')
[[ -z $missing ]] || { echo "FAIL: the bundle lacks guest components: $missing" >&2; exit 1; }
[[ $("$host/node/bin/node" --version) == v22.* ]] || { echo 'FAIL: the bundled Node is not 22' >&2; exit 1; }
case $bundle in
  *darwin-*)
    [[ -x $host/bin/appkit-desk-vz && -x $host/Caboose.app/Contents/MacOS/CabooseMenu ]] || { echo 'FAIL: macOS native helper or menu is missing' >&2; exit 1; }
    codesign --verify --strict "$host/bin/appkit-desk-vz"
    codesign --verify --strict "$host/Caboose.app"
    ;;
  *linux-*) [[ -x $host/bin/cloud-hypervisor ]] || { echo 'FAIL: a Linux bundle lacks Cloud Hypervisor' >&2; exit 1; } ;;
esac

port=$("$host/node/bin/node" -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
mkdir -p "$work/state" "$work/bin"
ln -s "$host/bin/caboose-host" "$work/bin/caboose-host"
env -i PATH=/usr/bin:/bin CABOOSE_PORT="$port" CABOOSE_IMAGE_ROOT="$work/state" CABOOSE_MDNS=off CABOOSE_BASE_IMAGE= \
  "$work/bin/caboose-host" >"$work/host.log" 2>&1 &
pid=$!

for _ in $(seq 1 100); do
  [[ -s $work/state/owner-token && -s $work/state/setup-code ]] && curl -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
  kill -0 "$pid" 2>/dev/null || { sed '/^Set up Caboose:/d' "$work/host.log" >&2; echo 'FAIL: the host exited' >&2; exit 1; }
  sleep 0.2
done
token=$(cat "$work/state/owner-token")
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
[[ $(status "http://127.0.0.1:$port/") == 200 ]] || { echo 'FAIL: the console is not served' >&2; exit 1; }
[[ $(status "http://127.0.0.1:$port/v1/health") == 401 ]] || { echo 'FAIL: /v1/health answers without a token' >&2; exit 1; }
[[ $(status -H "authorization: Bearer $token" "http://127.0.0.1:$port/v1/health") == 200 ]] || { echo 'FAIL: /v1/health refuses the owner token' >&2; exit 1; }
curl -fsS -H "authorization: Bearer $token" "http://127.0.0.1:$port/v1/health" > "$work/health.json"
"$host/node/bin/node" -e '
  const assert = require("node:assert/strict"), fs = require("node:fs")
  assert.equal(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).image.reference, null, "An explicitly empty image override must disable bundle defaults")
' "$work/health.json"
base="http://127.0.0.1:$port"
[[ $(status "$base/setup") == 403 ]] || { echo 'FAIL: setup opens without its code on loopback' >&2; exit 1; }
curl -fsS "$base/v1/setup" >"$work/setup.json"
"$host/node/bin/node" -e '
  const assert = require("node:assert/strict"), fs = require("node:fs")
  assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[1], "utf8")), { claimed: false, codeRequired: true })
' "$work/setup.json"
[[ $(status -H 'content-type: application/json' -d '{}' "$base/v1/setup") == 400 ]] || { echo 'FAIL: setup accepts a claim without its code' >&2; exit 1; }
"$host/node/bin/node" -e '
  const fs = require("node:fs")
  const code = fs.readFileSync(process.argv[1], "utf8").trim()
  fs.writeFileSync(process.argv[2], JSON.stringify({ code, name: "Bundle check", email: "bundle@example.com", password: "bundle-check-password", tenantName: "Bundle check" }), { mode: 0o600 })
' "$work/state/setup-code" "$work/claim.json"
[[ $(status -c "$work/cookies" -H 'content-type: application/json' --data-binary "@$work/claim.json" "$base/v1/setup") == 201 ]] || { echo 'FAIL: the fresh identity database cannot be claimed' >&2; exit 1; }
[[ ! -e $work/state/setup-code ]] || { echo 'FAIL: the setup code survives claiming' >&2; exit 1; }
curl -fsS -b "$work/cookies" "$base/v1/me" >"$work/me.json"
"$host/node/bin/node" -e '
  const assert = require("node:assert/strict"), fs = require("node:fs")
  const me = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
  assert.equal(me.kind, "admin")
  assert.equal(me.operator, true)
  assert.equal(me.tenants.length, 1)
  assert.equal(me.tenants[0].name, "Bundle check")
' "$work/me.json"
[[ $(status -b "$work/cookies" "$base/v1/host/reach") == 200 ]] || { echo 'FAIL: the operator cannot see host reachability' >&2; exit 1; }
echo "ok: embedded identity migrations, one-time setup and operator session"
echo "ok: $(basename "$bundle") $(cat "$host/VERSION") serves the console and API on port $port"
