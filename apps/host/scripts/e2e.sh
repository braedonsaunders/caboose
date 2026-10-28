#!/usr/bin/env bash
set -euo pipefail
: "${CABOOSE_OWNER_TOKEN:?Set CABOOSE_OWNER_TOKEN}"
cd "$(dirname "$0")/.."
exec node scripts/e2e.mjs
