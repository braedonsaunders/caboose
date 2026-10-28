#!/usr/bin/env bash
# Removes a native Caboose install (deploy/linux/install.sh): the service, the host and its
# command. The computer, its disk and the host's settings stay unless --purge is given, so
# installing again brings everything back as it was.
#
#   sudo deploy/linux/uninstall.sh [--purge] [--yes]
set -euo pipefail

purge=0
yes=0
for arg in "$@"; do
  case $arg in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    -h | --help) echo 'Usage: uninstall.sh [--purge] [--yes]   --purge also deletes the computer and settings'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ $(id -u) == 0 ]] || { echo 'Run it as root (sudo).' >&2; exit 1; }

images=
if [[ -f /etc/caboose/host.env ]]; then
  images=$(sed -n 's/^CABOOSE_IMAGE_ROOT=//p' /etc/caboose/host.env | tail -n 1)
fi

if systemctl list-unit-files caboose-host.service >/dev/null 2>&1; then
  # Stopping parks the computer with its memory, so nothing open is lost.
  systemctl disable --now caboose-host.service 2>/dev/null || true
fi
rm -f /etc/systemd/system/caboose-host.service
systemctl daemon-reload
rm -f /usr/local/bin/caboose-host
rm -rf /opt/caboose
echo 'Removed the caboose-host service and program.'

if [[ $purge == 0 ]]; then
  echo "Kept the computer and settings${images:+ in $images} and /etc/caboose. --purge deletes them."
  exit 0
fi
if [[ $yes == 0 ]]; then
  if [[ ! -t 0 ]] && [[ ! -r /dev/tty ]]; then echo 'Refusing to delete the computer without --yes.' >&2; exit 1; fi
  printf 'Delete the computer%s, everything in it, and the settings? Type "delete" to confirm: ' "${images:+ in $images}"
  read -r answer </dev/tty
  [[ $answer == delete ]] || { echo 'Kept them.'; exit 0; }
fi
if [[ -n $images ]]; then
  if mountpoint -q "$images"; then umount "$images"; fi
  # The XFS image setup-disks made when the filesystem could not reflink, and its fstab line.
  if [[ -f ${images%/}.xfs.img ]]; then
    sed -i "\\|^${images%/}.xfs.img ${images%/} xfs |d" /etc/fstab
    rm -f "${images%/}.xfs.img"
  fi
  rm -rf "$images"
fi
if command -v docker >/dev/null; then
  # The container runtime's computers (caboose-owner, caboose-<id>), homes and networks.
  docker ps -aq --filter 'name=^caboose-' | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume ls -q --filter 'name=^caboose-home' | xargs -r docker volume rm >/dev/null 2>&1 || true
  docker network ls -q --filter 'name=^caboose' | xargs -r docker network rm >/dev/null 2>&1 || true
fi
rm -rf /etc/caboose
echo 'Deleted the computer and settings.'
