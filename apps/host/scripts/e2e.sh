#!/usr/bin/env bash
set -euo pipefail
: "${CABOOSE_OWNER_TOKEN:?Set CABOOSE_OWNER_TOKEN}"
command -v xpra >/dev/null || { echo 'Install the Xpra client to run this check' >&2; exit 1; }
cd "$(dirname "$0")/.."
exec node scripts/e2e.mjs
