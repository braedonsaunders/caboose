#!/usr/bin/env bash
# Run every task N times, native then pixels each round, and summarise.
#
#   EXEC='ssh HOST docker exec -i -u caboose CONTAINER bash -s' \
#   MCP="ssh HOST \"docker exec -i -u caboose CONTAINER bash -c 'set -a; . /run/caboose/agent-display.env; set +a; CABOOSE_AGENT_PROFILE=/tmp/caboose-bench CABOOSE_DESKTOP_TRACE=/tmp/caboose-bench-trace.jsonl exec node /opt/caboose/desktop-mcp.mjs'\"" \
#   bench/repeat.sh OUT-DIR [N] [MODEL] [run.py options…]
#
# OUT-DIR gets native-I.jsonl and pixels-I.jsonl per round, run.log, and summary.md
# (summarize.py over all of them). N defaults to 3, MODEL to claude-sonnet-5-5.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: repeat.sh OUT-DIR [N] [MODEL] [run.py options…]}; n=${2:-3}; model=${3:-claude-sonnet-5-5}
shift $(( $# < 3 ? $# : 3 ))
: "${EXEC:?set EXEC to the command that runs a shell script inside the computer}"
: "${MCP:?set MCP to the command that starts desktop MCP inside the computer}"
mkdir -p "$out"
for i in $(seq 1 "$n"); do
  python3 "$here/run.py" --exec "$EXEC" --mcp "$MCP" --trace /tmp/caboose-bench-trace.jsonl --mode native --model "$model" \
    --output "$out/native-$i.jsonl" "$@" >> "$out/run.log" 2>&1
  python3 "$here/run.py" --exec "$EXEC" --mcp "$MCP" --trace /tmp/caboose-bench-trace.jsonl --mode pixels --model "$model" --output "$out/pixels-$i.jsonl" "$@" >> "$out/run.log" 2>&1
done
python3 "$here/summarize.py" "$out"/native-*.jsonl "$out"/pixels-*.jsonl > "$out/summary.md"
cat "$out/summary.md"
