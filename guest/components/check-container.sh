#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
pnpm --filter caboose-host exec tsx ../../guest/components/check-container.mts
