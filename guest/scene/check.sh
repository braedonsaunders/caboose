#!/bin/sh
# check.sh — Build and run the Caboose Guest Scene Graph Interceptor test suite
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

make check
