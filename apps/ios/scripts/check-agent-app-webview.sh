#!/bin/sh
# Run the native handoff check against a local fake host on an iOS simulator.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
: "${SIMULATOR_ID:?Set SIMULATOR_ID to an available iOS simulator UDID}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/caboose-wk-check.XXXXXX")
server_pid=
booted_by_check=0
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; fi
  if [ "$booted_by_check" = 1 ]; then xcrun simctl shutdown "$SIMULATOR_ID" 2>/dev/null || :; fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/package"
cp "$root/CabooseKit/Package.swift" "$tmp/package/"
cp -R "$root/CabooseKit/Sources" "$tmp/package/"
mkdir -p "$tmp/package/Tests/CabooseKitTests/Fixtures"
cp "$root/CabooseKit/Tests/CabooseKitTests/AgentAppWebViewTests.swift" "$tmp/package/Tests/CabooseKitTests/"
python3 "$root/CabooseKit/Tests/AgentAppHandoffCheck/server.py" &
server_pid=$!
python3 - "$server_pid" <<'PY'
import os, sys, time, urllib.request
for _ in range(50):
    try:
        os.kill(int(sys.argv[1]), 0)
        with urllib.request.urlopen("http://127.0.0.1:18765/test/state", timeout=1) as response:
            if b'"revision": -1' in response.read(): break
    except (OSError, ValueError): pass
    time.sleep(0.1)
else: raise SystemExit("The local fake host did not start on port 18765")
PY
if xcrun simctl list devices booted | grep -q "$SIMULATOR_ID"; then :; else
  xcrun simctl boot "$SIMULATOR_ID"
  booted_by_check=1
fi
cd "$tmp/package"
xcodebuild test -scheme CabooseKit -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$tmp/build" -jobs "${JOBS:-1}" -parallel-testing-enabled NO \
  -only-testing:CabooseKitTests/AgentAppWebViewTests CODE_SIGNING_ALLOWED=NO
