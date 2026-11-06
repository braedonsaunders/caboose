#!/bin/sh
# Starts a Flatpak application many times at once while one instance of it keeps running (as
# Steam does while its games start) and other sandboxes mount, in a running computer, and fails
# if any start exits non-zero ("Extension ... has invalid merge-dirs" is the failure this
# package fixes). Run as root in the computer:
#
#   check-merge-dirs.sh [APP] [PARALLEL] [EACH]
#
# APP (default com.valvesoftware.Steam) must be installed and use the GL extension; it runs only
# `true` in its sandbox. PARALLEL (default 6) loops start EACH (default 15) times.
set -u
app=${1:-com.valvesoftware.Steam}; parallel=${2:-6}; each=${3:-15}
work=$(mktemp -d /tmp/caboose-merge-dirs.XXXXXX); chmod 0777 "$work"
as() { runuser -u caboose -- env XDG_RUNTIME_DIR=/run/user/$(id -u caboose) "$@"; }
# The held instance sleeps for a duration no other process uses, so it alone is ended.
hold=3600.$$
as flatpak run --command=sleep "$app" "$hold" >/dev/null 2>&1 &
trap 'pkill -u caboose -x -f "sleep $hold"; rm -rf "$work"' EXIT
sleep 3
for _ in 1 2; do
  ( while [ ! -e "$work/done" ]; do as bwrap --dev-bind / / --tmpfs /tmp true; done ) &
done
n=0; pids=
while [ $n -lt "$parallel" ]; do
  n=$((n + 1))
  ( i=0; while [ $i -lt "$each" ]; do i=$((i + 1))
      as flatpak run --command=true "$app" > "$work/out.$n.$i" 2>&1; echo $? > "$work/rc.$n.$i"
    done ) &
  pids="$pids $!"
done
wait $pids
touch "$work/done"; pkill -u caboose -x -f "sleep $hold"; wait
runs=$(ls "$work"/rc.* | wc -l); failed=$(grep -L '^0$' "$work"/rc.* | wc -l)
echo "starts: $runs; failed: $failed"
[ "$failed" -eq 0 ] || { cat "$work"/out.* | sort | uniq -c | sort -rn | head -5; exit 1; }
