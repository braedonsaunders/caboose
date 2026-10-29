#!/bin/sh
# Run as root inside a Linux microVM with the host depot enabled.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root in the microVM' >&2; exit 1; }
depot=/var/lib/caboose/depot
[ "$(findmnt -n -o FSTYPE --target "$depot")" = virtiofs ] || { echo 'Depot is not mounted as virtio-fs' >&2; exit 1; }
case ",$(findmnt -n -o OPTIONS --target "$depot")," in *,ro,*) ;; *) echo 'Depot mount is not read-only' >&2; exit 1 ;; esac
[ -f "$depot/repo/config" ] || { echo 'Flatpak depot has no repository' >&2; exit 1; }
if file=$(mktemp "$depot/.caboose-check.XXXXXXXX" 2>/dev/null); then
  rm -f "$file"
  echo 'Depot accepted a write' >&2; exit 1
fi
echo 'Shared runtime depot is mounted read-only'
