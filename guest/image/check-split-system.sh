#!/bin/sh
# Run as root inside the split microVM; prepare, cold-restart, then verify.
set -eu
mode=${1:-}
case "$mode" in prepare|verify) ;; *) echo 'Usage: check-split-system.sh prepare|verify' >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo 'Run as root in a split microVM' >&2; exit 1; }
[ -e /etc/caboose-split-system ] || { echo 'This is not a split computer' >&2; exit 1; }
[ "$(findmnt -n -o FSTYPE --target /usr)" = overlay ] || { echo '/usr is not an overlay' >&2; exit 1; }
[ "$(findmnt -n -o FSTYPE --target /opt)" = overlay ] || { echo '/opt is not an overlay' >&2; exit 1; }
[ "$(findmnt -n -o FSTYPE --target /.caboose-system)" = erofs ] || { echo 'System lower is not EROFS' >&2; exit 1; }
marker=/usr/local/share/caboose/.split-system-check
case "$mode" in
  prepare)
    (set -C; printf 'Caboose split image persistence check\n' > "$marker")
    sync
    echo 'Marker written; cold-restart this computer, then run verify.'
    ;;
  verify)
    [ "$(cat "$marker")" = 'Caboose split image persistence check' ] || { echo 'Marker did not survive' >&2; exit 1; }
    [ ! -e /.caboose-system/usr/local/share/caboose/.split-system-check ] || { echo 'Marker was written to lower image' >&2; exit 1; }
    rm "$marker"
    echo 'Writable system overlay survived the restart.'
    ;;
esac
