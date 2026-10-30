#!/bin/sh
# Run on the Linux worker only, after parent scheduling. No probe execution.
set -eu
if [ "$#" -ne 2 ]; then
    echo 'usage: compile-only.sh ABSOLUTE_SOURCE_FILE NEW_OUTPUT_DIRECTORY' >&2
    exit 2
fi
case "$1:$2" in /*:/*) ;; *) echo 'absolute paths required' >&2; exit 2;; esac
[ -f "$1" ] && [ -d "$2" ] && [ ! -e "$2/memory_probe" ]
# Output must be writable by this explicit uid/gid; no root DAC override needed.
docker run --rm --name "caboose-memory-compile-$$" \
  --user 1000:1000 --network none --cpus 1 --memory 512m --memory-swap 512m \
  --pids-limit 64 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$1,dst=/src/memory_probe.cpp,readonly" \
  --mount "type=bind,src=$2,dst=/out" --workdir /out \
  --entrypoint /usr/bin/timeout \
  sha256:b94dd0452b1d2164d52115722c333cbb51f903e736fa7e7e782d21c52cf40442 \
  55s c++ -std=c++17 -O1 -Wall -Wextra /src/memory_probe.cpp -lvulkan -o /out/memory_probe
