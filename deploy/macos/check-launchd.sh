#!/usr/bin/env bash
# Real launchd check using a unique temporary label, port and data directory.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
bundle=${1:?usage: check-launchd.sh caboose-host-darwin-arm64.tar.gz}
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-launchd.XXXXXX")
label=com.caboose.check.$(basename "$work" | tr -cd 'a-zA-Z0-9')
domain=gui/$(id -u)
loaded=0
cleanup() {
  if [[ $loaded == 1 ]]; then launchctl bootout "$domain/$label" || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
bash "$here/install.sh" --bundle "$bundle" --no-start --stage-home "$work/home"
root=$work/home/Library/Application\ Support/Caboose
node=$root/current/node/bin/node
port=$("$node" -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
plutil -convert json -o "$work/host.json" "$work/home/Library/LaunchAgents/com.caboose.host.plist"
"$node" - "$work/host.json" "$label" "$port" <<'JS'
const fs = require('node:fs')
const [file,label,port] = process.argv.slice(2), data = JSON.parse(fs.readFileSync(file,'utf8'))
data.Label = label
Object.assign(data.EnvironmentVariables, { CABOOSE_PORT: port, CABOOSE_BIND: '127.0.0.1', CABOOSE_MDNS: 'off' })
// This lifecycle check never fetches or replaces a computer image.
data.EnvironmentVariables.CABOOSE_BASE_IMAGE = ''
fs.writeFileSync(file, JSON.stringify(data))
JS
plutil -convert xml1 -o "$work/host.plist" "$work/host.json"
ready() {
  for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$port/v1/setup" > "$work/setup.json" 2>/dev/null; then return; fi
    sleep 0.2
  done
  sed '/^Set up Caboose:/d' "$root/logs/host-error.log" >&2 || true
  echo 'LaunchAgent did not become ready' >&2
  return 1
}
for pass in first restart; do
  echo "Checking LaunchAgent $pass start"
  launchctl bootstrap "$domain" "$work/host.plist"
  loaded=1
  ready
  echo "LaunchAgent $pass start is ready"
  [[ -s $root/disks/owner-token && -s $root/disks/setup-code ]]
  "$node" - "$work/setup.json" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs')
assert.deepEqual(JSON.parse(fs.readFileSync(process.argv[2],'utf8')), { claimed: false, codeRequired: true })
JS
  if [[ $pass == first ]]; then cp "$root/disks/owner-token" "$work/first-token";
  else cmp "$root/disks/owner-token" "$work/first-token"; fi
  launchctl bootout "$domain/$label"
  loaded=0
  for _ in $(seq 1 100); do
    if ! launchctl print "$domain/$label" >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  for _ in $(seq 1 100); do
    if ! curl -fsS -o /dev/null "http://127.0.0.1:$port/v1/setup" 2>/dev/null; then break; fi
    sleep 0.2
  done
  if curl -fsS -o /dev/null "http://127.0.0.1:$port/v1/setup" 2>/dev/null; then echo 'Host still serves after bootout' >&2; exit 1; fi
done
echo 'ok: isolated LaunchAgent start, clean stop, restart and retained host identity'
