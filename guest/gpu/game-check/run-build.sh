#!/bin/sh
# Run on the coordinated Linux build host. Never invoke on a Mac.
set -eu
[ "$(uname -s)" = Linux ] || { echo 'Linux build host required' >&2; exit 2; }
task=$(realpath "${1:?private task directory required}")
[ -d "$task/deps" ] && [ -f "$task/build.sh" ]
name=caboose-game-build-$$
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT HUP INT TERM
docker run --rm --name "$name" --network none --cpus 2 --memory 3g \
  --pids-limit 256 --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp:rw,size=256m \
  --mount "type=bind,src=$task,dst=/task" --entrypoint timeout \
  sha256:b94dd0452b1d2164d52115722c333cbb51f903e736fa7e7e782d21c52cf40442 \
  300 sh /task/build.sh
