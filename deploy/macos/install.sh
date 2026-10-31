#!/usr/bin/env bash
# Per-user Apple Silicon install: native host, signed VZ helper, menu app and launchd.
set -euo pipefail
version=latest
bundle=
dry=0
start=1
stage_home=
from_app=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --version) version=${2:?}; shift 2 ;;
    --bundle) bundle=${2:?}; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --no-start) start=0; shift ;;
    --from-app) from_app=1; shift ;;
    --stage-home) stage_home=${2:?}; shift 2 ;;
    -h|--help) echo 'Usage: install.sh [--version tag] [--bundle archive.tar.gz] [--dry-run] [--no-start] [--stage-home directory]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Requires an Apple Silicon Mac' >&2; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 14 ]] || { echo 'Requires macOS 14 or newer' >&2; exit 1; }
[[ $(id -u) != 0 ]] || { echo 'Run as your normal login user, without sudo' >&2; exit 1; }
[[ $version =~ ^[A-Za-z0-9._+-]+$ ]] || { echo 'Invalid release tag' >&2; exit 1; }
install_home=$HOME
if [[ -n $stage_home ]]; then
  [[ $start == 0 && $stage_home == /* && $stage_home != / && $stage_home != "$HOME" ]] || { echo '--stage-home needs --no-start and a separate absolute staging directory' >&2; exit 1; }
  install_home=$stage_home
fi
root=$install_home/Library/Application\ Support/Caboose
agents=$install_home/Library/LaunchAgents
label=gui/$(id -u)
if [[ $dry == 1 ]]; then
  printf 'Install the native host and menu app under %s\nWrite host/menu LaunchAgents under %s\nPreserve computers and settings across upgrades\n' "$root" "$agents"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-install.XXXXXX")
trap 'rm -rf "$work"' EXIT
asset=caboose-host-darwin-arm64.tar.gz
if [[ -z $bundle ]]; then
  if [[ $version == latest ]]; then base=https://github.com/braedonsaunders/caboose/releases/latest/download
  else base=https://github.com/braedonsaunders/caboose/releases/download/$version; fi
  curl -fsSL --retry 3 "$base/$asset" -o "$work/$asset"
  curl -fsSL --retry 3 "$base/SHA256SUMS" -o "$work/SHA256SUMS"
  expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$work/SHA256SUMS")
  [[ $expected =~ ^[0-9a-f]{64}$ && $(shasum -a 256 "$work/$asset" | cut -d' ' -f1) == "$expected" ]] || { echo 'Bundle checksum mismatch' >&2; exit 1; }
  bundle=$work/$asset
fi
tar -xzf "$bundle" -C "$work"
source=$work/caboose-host
for file in bin/caboose-host bin/appkit-desk-vz node/bin/node Caboose.app/Contents/MacOS/CabooseMenu; do
  [[ -x $source/$file ]] || { echo "Bundle lacks $file" >&2; exit 1; }
done
codesign --verify --strict "$source/bin/appkit-desk-vz"
codesign --verify --strict "$source/Caboose.app"
release=$(cat "$source/VERSION")
[[ $release =~ ^[A-Za-z0-9._+-]+$ ]] || { echo 'Invalid bundle version' >&2; exit 1; }
digest=$(shasum -a 256 "$bundle" | cut -c1-12)
mkdir -p "$root/versions" "$root/disks" "$root/logs" "$agents" "$install_home/Applications"
chmod 0700 "$root" "$root/disks" "$root/logs"
install=$root/versions/$release-$digest
[[ -d $install ]] || mv "$source" "$install"
node=$install/node/bin/node
# Refuse to replace unrelated files before stopping either service.
for link in "$root/current" "$install_home/Applications/Caboose.app"; do
  [[ ! -e $link || -L $link ]] || { echo "Refusing to replace $link; it is not an installer symlink" >&2; exit 1; }
done
# Validate and preserve settings before stopping a running service.
"$node" - "$root" <<'JS'
const fs = require('fs'), path = require('path')
const root = process.argv[2], file = path.join(root, 'install.json')
const settings = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { port: 7310, memoryMb: 3072, vcpus: 2, bind: '0.0.0.0' }
for (const [key, min, max] of [['port',1,65535], ['memoryMb',512,65536], ['vcpus',1,32]]) {
  if (!Number.isInteger(settings[key]) || settings[key] < min || settings[key] > max) throw new Error(`Invalid ${key} in ${file}`)
}
if (!['127.0.0.1','0.0.0.0'].includes(settings.bind)) throw new Error('bind must be 127.0.0.1 or 0.0.0.0')
fs.writeFileSync(file, JSON.stringify(settings, null, 2) + '\n', { mode: 0o600 })
JS
if [[ -z $stage_home ]]; then
  for service in com.caboose.menu com.caboose.host; do
    if launchctl print "$label/$service" >/dev/null 2>&1; then
      launchctl bootout "$label/$service"
      # bootout can return before the job is unloaded. Wait beyond ExitTimeOut before
      # switching versions or bootstrapping the same label again.
      for ((attempt=0; attempt<180; attempt++)); do
        if ! launchctl print "$label/$service" >/dev/null 2>&1; then break; fi
        sleep 1
      done
      if launchctl print "$label/$service" >/dev/null 2>&1; then
        echo "Timed out stopping $service; current version remains selected" >&2
        exit 1
      fi
    fi
  done
fi
"$node" - "$root" "$install" "$agents" "$install_home/Applications/Caboose.app" <<'JS'
const fs = require('fs'), path = require('path')
const [root, install, agents, app] = process.argv.slice(2)
const settings = JSON.parse(fs.readFileSync(path.join(root, 'install.json'), 'utf8'))
function link(target, name) {
  const temp = name + '.new'
  try { fs.unlinkSync(temp) } catch (error) { if (error.code !== 'ENOENT') throw error }
  fs.symlinkSync(target, temp)
  fs.renameSync(temp, name)
}
link(install, path.join(root, 'current'))
link(path.join(install, 'Caboose.app'), app)
const esc = value => String(value).replace(/[<>&"']/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c]))
const encode = value => typeof value === 'number' ? `<integer>${value}</integer>` : typeof value === 'boolean' ? `<${value}/>` : Array.isArray(value) ? `<array>${value.map(encode).join('')}</array>` : typeof value === 'object' ? `<dict>${Object.entries(value).map(([k,v])=>`<key>${esc(k)}</key>${encode(v)}`).join('')}</dict>` : `<string>${esc(value)}</string>`
const current = path.join(root, 'current')
for (const data of [
  { Label: 'com.caboose.host', ProgramArguments: [path.join(current,'bin/caboose-host')], RunAtLoad: true, KeepAlive: true,
    EnvironmentVariables: { CABOOSE_IMAGE_ROOT: path.join(root,'disks'), CABOOSE_BIND: settings.bind, CABOOSE_PORT: String(settings.port), CABOOSE_MEMORY_MB: String(settings.memoryMb), CABOOSE_VCPUS: String(settings.vcpus), CABOOSE_MAX_RUNNING: '1', PATH: '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' },
    StandardOutPath: path.join(root,'logs/host.log'), StandardErrorPath: path.join(root,'logs/host-error.log'), ExitTimeOut: 150 },
  { Label: 'com.caboose.menu', ProgramArguments: [path.join(current,'Caboose.app/Contents/MacOS/CabooseMenu')], RunAtLoad: true,
    StandardOutPath: path.join(root,'logs/menu.log'), StandardErrorPath: path.join(root,'logs/menu-error.log') },
]) {
  const xml = encode(data)
  fs.writeFileSync(path.join(agents, data.Label + '.plist'), `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0">${xml}</plist>\n`, { mode: 0o600 })
}
JS
plutil -lint "$agents/com.caboose.host.plist" "$agents/com.caboose.menu.plist"
if [[ $start == 0 ]]; then
  if [[ -n $stage_home ]]; then echo "Staged under $stage_home; no login services changed."
  else echo "Installed. Start with: launchctl bootstrap $label '$agents/com.caboose.host.plist'"; fi
  exit 0
fi
launchctl bootstrap "$label" "$agents/com.caboose.host.plist"
if [[ $from_app == 0 ]]; then launchctl bootstrap "$label" "$agents/com.caboose.menu.plist"; fi
# The already running app owns onboarding; do not open a second browser flow.
[[ $from_app == 0 ]] || exit 0
"$node" - "$root" <<'JS'
const fs = require('fs'), path = require('path')
const root = process.argv[2], settings = JSON.parse(fs.readFileSync(path.join(root,'install.json'),'utf8'))
const base = `http://127.0.0.1:${settings.port}`
;(async () => {
  for (let i=0;i<60;i++) {
    try { if ((await fetch(base+'/v1/setup', { signal: AbortSignal.timeout(1500) })).ok) {
      const codePath = path.join(root,'disks/setup-code')
      const target = fs.existsSync(codePath) ? `${base}/setup?code=${encodeURIComponent(fs.readFileSync(codePath,'utf8').trim())}` : base
      console.log(`Open Caboose: ${target}\nSettings: ${root}/install.json\nComputer files: ${root}/disks`)
      require('child_process').spawnSync('/usr/bin/open', [target])
      return
    } } catch {}
    await new Promise(resolve=>setTimeout(resolve,1000))
  }
  throw new Error(`Host did not become ready. Check ${root}/logs/host-error.log`)
})().catch(error=>{ console.error(error.message); process.exitCode=1 })
JS
