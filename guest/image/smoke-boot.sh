#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
DISKS=${DISKS:-$DIR/out}
[[ $EUID == 0 ]] || { echo 'Run as root (TAP and KVM access required)' >&2; exit 1; }
for cmd in node npm xpra ip cloud-hypervisor; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }; done
for file in base.raw vmlinux initrd; do [[ -f "$DISKS/$file" ]] || { echo "Missing $DISKS/$file" >&2; exit 1; }; done
[[ ! -e /sys/class/net/cbsmoke ]] || { echo 'cbsmoke TAP already exists' >&2; exit 1; }
cd "$DIR"
npm ci --ignore-scripts
work=$(mktemp -d)
cleanup() { ip link del cbsmoke 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
ip tuntap add dev cbsmoke mode tap
ip addr add 192.0.2.1/30 dev cbsmoke
ip link set cbsmoke up
node "$DIR/smoke-boot.mjs" "$(realpath "$DISKS")" "$work"
