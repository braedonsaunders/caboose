#!/usr/bin/env bash
# Exercise install/upgrade/uninstall against an actual bundle in an isolated staging directory.
# --stage-home disables service operations; this never changes the login user's services.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
bundle=${1:?usage: check.sh caboose-host-darwin-arm64.tar.gz}
bundle=$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-macos-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage=$work/home
mkdir -p "$stage"
bash "$here/install.sh" --bundle "$bundle" --no-start --stage-home "$stage"
root=$stage/Library/Application\ Support/Caboose
node=$root/current/node/bin/node
[[ -x $stage/Applications/Caboose.app/Contents/MacOS/CabooseMenu ]]
[[ -x $root/current/bin/appkit-desk-vz ]]
plutil -lint "$stage/Library/LaunchAgents/"*.plist
"$node" - "$root" "$stage/Library/LaunchAgents/com.caboose.host.plist" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path')
const [root, plist] = process.argv.slice(2)
const xml = fs.readFileSync(plist, 'utf8')
assert(xml.includes('<key>ExitTimeOut</key><integer>150</integer>'))
assert(xml.includes('<key>CABOOSE_IMAGE_ROOT</key>'))
const file = path.join(root, 'install.json'), settings = JSON.parse(fs.readFileSync(file, 'utf8'))
assert.equal(settings.port, 7310)
settings.port = 8321; settings.memoryMb = 1536
fs.writeFileSync(file, JSON.stringify(settings))
fs.writeFileSync(path.join(root, 'disks/retained-computer'), 'persistent computer')
JS
bash "$here/install.sh" --bundle "$bundle" --no-start --stage-home "$stage"
"$node" - "$root" <<'JS'
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path')
const root = process.argv[2], settings = JSON.parse(fs.readFileSync(path.join(root,'install.json'),'utf8'))
assert.equal(settings.port, 8321); assert.equal(settings.memoryMb,1536)
assert.equal(fs.readFileSync(path.join(root,'disks/retained-computer'),'utf8'), 'persistent computer')
JS
bash "$here/uninstall.sh" --stage-home "$stage"
[[ ! -e $root/current && ! -e $stage/Applications/Caboose.app ]]
[[ -f $root/disks/retained-computer && -f $root/install.json ]]
bash "$here/install.sh" --bundle "$bundle" --no-start --stage-home "$stage"
[[ -f $root/disks/retained-computer ]]
bash "$here/uninstall.sh" --stage-home "$stage" --purge --yes
[[ ! -e $root ]]
echo 'ok: macOS bundle install, saved settings, upgrade, retained data, reinstall and explicit purge'
