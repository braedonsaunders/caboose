#!/usr/bin/env bash
# Watch shows the agent working: starts an agent chat through the host's API as the phone
# does, opens it on the phone with its Watch link (caboose://task/<id>/watch, the agent's
# seat window full screen), captures the phone's screen once a second, and requires every
# frame to be a real picture (neither black nor noise) and the frames to move
# (watch_pixels.py). Run on a Mac with Xcode, the phone paired and unlocked, and the phone
# held by this check (no other test may use it meanwhile).
#
#   CABOOSE_HOST_URL=http://host:7310 CABOOSE_HOST_TOKEN=… DEVICE=<udid|name> \
#     guest/computer-use/check/watch.sh [AGENT] [FRAMES]
#
# AGENT is an installed, signed-in agent (default codex-acp); FRAMES the screenshots taken
# (default 12). The frames, the scores and the task's summary stay in $OUT (default a new
# directory under /tmp, printed at the end; remove it when done).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${CABOOSE_HOST_URL:?set CABOOSE_HOST_URL}" "${CABOOSE_HOST_TOKEN:?set CABOOSE_HOST_TOKEN}" "${DEVICE:?set DEVICE}"
agent=${1:-codex-acp}; frames=${2:-12}
out=${OUT:-$(mktemp -d /tmp/caboose-watch.XXXXXX)}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
api() { curl -fsS -H "Authorization: Bearer $CABOOSE_HOST_TOKEN" -H 'Content-Type: application/json' "$@"; }
prompt='On your own display, open Mousepad and type the numbers from 1 to 40, one per line, typing each line as its own step so the window keeps changing. Do not save. Say done when finished.'
body=$(python3 -c 'import json, sys; print(json.dumps({"prompt": sys.argv[1], "agent": sys.argv[2], "approvals": "auto"}))' "$prompt" "$agent")
task=$(api -X POST "$CABOOSE_HOST_URL/v1/agent/tasks" -d "$body" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
echo "task $task"
status() { api "$CABOOSE_HOST_URL/v1/agent/tasks" | python3 -c 'import json, sys; d = json.load(sys.stdin); d = d if isinstance(d, list) else d.get("tasks", []); print(next((t["status"] for t in d if t["id"] == sys.argv[1]), "gone"))' "$task"; }
# The agent opens its window first; the link then presents it as soon as it is there.
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --payload-url "caboose://task/$task/watch" com.braedonsaunders.caboose >/dev/null
sleep 20
shots=()
for i in $(seq -w 1 "$frames"); do
  xcrun devicectl device capture screenshot --device "$DEVICE" --destination "$out/frame-$i.png" --quiet >/dev/null
  shots+=("$out/frame-$i.png")
  sleep 1
done
echo "task status: $(status)"
# The phone's own bars (status bar and home indicator) stay out of the score.
size=$(python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print(*struct.unpack(">II", d[16:24]))' "${shots[0]}")
read -r width height <<<"$size"
region="0,$((height / 12)),$width,$((height * 10 / 12))"
set +e
python3 "$here/watch_pixels.py" --moving --region "$region" "${shots[@]}" | tee "$out/scores.jsonl"
result=${PIPESTATUS[0]}
set -e
api -X POST "$CABOOSE_HOST_URL/v1/agent/tasks/$task/cancel" -d '{}' >/dev/null 2>&1 || true
echo "frames and scores: $out"
exit "$result"
