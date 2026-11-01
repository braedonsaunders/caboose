#!/bin/sh
# Measures Apple's on-device language model on a connected iPhone with the AI probe app
# (apps/ios/AIProbe, its own bundle id, so it never replaces Caboose). The phone must be
# unlocked, with Developer Mode on; launching brings the probe to the foreground, which
# sends Caboose to the background.
#
#   scripts/check-on-device-ai.sh <device id> [probe,probe…] > results.jsonl
#
# Probes: info tokens throughput prefill context session guided tools vision reasoning
# concurrency pcc (all of them by default). Each result is one JSON line on standard output.
set -eu
device=${1:?usage: check-on-device-ai.sh <device id from xcrun devicectl list devices> [probes]}
probes=${2:-}
here=$(cd "$(dirname "$0")/../AIProbe" && pwd)
derived=${TMPDIR:-/tmp}/caboose-ai-probe
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
(cd "$here" && xcodegen generate -q)
xcodebuild -quiet -project "$here/CabooseAIProbe.xcodeproj" -scheme CabooseAIProbe -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" -allowProvisioningUpdates build >&2
xcrun devicectl device install app --device "$device" "$derived/Build/Products/Debug-iphoneos/CabooseAIProbe.app" >&2
set -- --terminate-existing --console com.braedonsaunders.caboose.ai-probe
[ -n "$probes" ] && set -- "$@" --probes "$probes"
# The console ends when the app exits; the probe keeps running after "finished", so stop there.
xcrun devicectl device process launch --device "$device" "$@" 2>&1 | while IFS= read -r line; do
  case $line in
    "PROBE "*) printf '%s\n' "${line#PROBE }"; case $line in *'"probe":"finished"'*) exit 0;; esac;;
  esac
done
