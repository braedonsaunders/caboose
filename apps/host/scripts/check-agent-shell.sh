#!/usr/bin/env bash
# Runs the host's agent and file guest scripts (start, batched poll, replies, approvals,
# cancel, restore, sign-in, attachments, Downloads) for real in a Debian 13 container, with
# caboose-agentd driving a stand-in ACP agent. Needs Docker and network for the image build
# (Debian packages and the pinned ACP SDK); no KVM, guest image or model accounts. Run from anywhere.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
name=caboose-agent-shell-$$
docker build -q -t caboose-agent-shell -f "$here/agent-shell/Dockerfile" "$here/../../../guest" >/dev/null
docker run -d --init --name "$name" caboose-agent-shell >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
cd "$here/.."
CABOOSE_SHELL_CONTAINER=$name ./node_modules/.bin/tsx scripts/agent-shell/check.mts
