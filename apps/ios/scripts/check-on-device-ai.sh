#!/bin/sh
# Measures Apple's on-device language model on a connected iPhone with the AI probe app
# (apps/ios/AIProbe, its own bundle id, so it never replaces Caboose). The phone must be
# unlocked, with Developer Mode on; launching brings the probe to the foreground, which
# sends Caboose to the background.
#
#   scripts/check-on-device-ai.sh <device id> [probe,probe…|none] [mlx-model,…] > results.jsonl
#
# Probes: info tokens throughput prefill context session guided tools vision reasoning
# concurrency pcc (all of them by default). MLX models (downloaded from Hugging Face on the
# phone): qwen3-0.6b qwen3-1.7b qwen3-4b qwen3.5-2b llama3.2-1b llama3.2-3b gemma3-1b
# gemma4-e2b gemma4-e4b smollm3-3b lfm2-1.2b. Each result is one JSON line on standard output.
# Building needs Xcode's Metal toolchain (xcodebuild -downloadComponent MetalToolchain).
set -eu
device=${1:?usage: check-on-device-ai.sh <device id from xcrun devicectl list devices> [probes]}
probes=${2:-}
mlx=${3:-}
here=$(cd "$(dirname "$0")/../AIProbe" && pwd)
derived=${TMPDIR:-/tmp}/caboose-ai-probe
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
(cd "$here" && xcodegen generate -q)
xcodebuild -quiet -project "$here/CabooseAIProbe.xcodeproj" -scheme CabooseAIProbe -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation build >&2
xcrun devicectl device install app --device "$device" "$derived/Build/Products/Debug-iphoneos/CabooseAIProbe.app" >&2
set -- --terminate-existing --console com.braedonsaunders.caboose.ai-probe
[ -n "$probes" ] && set -- "$@" --probes "$probes"
[ -n "$mlx" ] && set -- "$@" --mlx "$mlx"
# The console ends when the app exits; the probe keeps running after "finished", so stop there.
xcrun devicectl device process launch --device "$device" "$@" 2>&1 | while IFS= read -r line; do
  case $line in
    "PROBE "*) printf '%s\n' "${line#PROBE }"; case $line in *'"probe":"finished"'*) exit 0;; esac;;
  esac
done
