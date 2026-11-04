#!/bin/sh
# Adds the whole GPU stack to open release ID (README.md, "The GPU stack"):
#
#   sh guest/release/fill-gpu-stack.sh ID REPO DRIVER_DIR LAYERS_DIR WARMUP_DIR GBM
#
# The arguments after ID are stage-gpu-stack.sh's. Every staged file is added at its path
# with its mode, replacing the release's copy, so a release made --from another carries the
# new driver, layers, manifests, broker, GBM backend, warm-up and override together.
set -eu
[ $# -eq 6 ] || { sed -n '4,8p' "$0" >&2; exit 2; }
id=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM
sh "$here/stage-gpu-stack.sh" "$@" "$stage/root"
"${CABOOSE_RELEASE:-caboose-release}" add-tree "$id" "$stage/root"
