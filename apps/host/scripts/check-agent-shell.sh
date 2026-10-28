#!/usr/bin/env bash
# Runs the host's agent and file guest scripts (batched poll, replies, approvals, restore,
# attachments, Downloads) for real in a Debian 13 container with stand-in claude/codex CLIs.
# Needs Docker; no KVM, guest image or model accounts. Run from anywhere.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=caboose-agent-shell-$$
docker build -q -t caboose-agent-shell "$here/agent-shell" >/dev/null
docker run -d --init --name "$name" caboose-agent-shell >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
cd "$here/.."
CABOOSE_SHELL_CONTAINER=$name ./node_modules/.bin/tsx scripts/agent-shell/check.mts
