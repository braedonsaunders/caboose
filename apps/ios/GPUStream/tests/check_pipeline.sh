#!/bin/bash
# Match GitHub's explicit `shell: bash` flags and prove tee cannot hide a failed producer.
set -euo pipefail
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if bash --noprofile --norc -eo pipefail -c '(exit 7) | tee "$1"' bash "$log"; then
  echo 'FAIL: tee hid the failing producer' >&2
  exit 1
else
  status=$?
  [[ $status == 7 ]] || { echo "FAIL: expected producer status 7, got $status" >&2; exit 1; }
fi
echo 'Failing producer piped to tee preserves exit 7: PASS'
