#!/bin/sh
# build.sh — Compile Caboose Guest Scene Graph Interceptor & WSI Promotion Layer
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

make all
