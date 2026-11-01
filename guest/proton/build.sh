#!/bin/bash
# Builds Caboose's replacements for modules of a GE-Proton release, with this directory's
# patches, in a throwaway Debian 13 container. Usage: build.sh WORKDIR [GE-TAG]
# The modules land in WORKDIR/out/{x86_64,i386}-unix; README.md says how to install them.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mkdir -p "$1" && cd "$1" && pwd)
docker run --rm --cpus 4 -e GE_TAG="${2:-GE-Proton11-11}" -v "$work":/work -v "$here":/src:ro debian:trixie \
  nice -n 19 bash /src/build-inside.sh
