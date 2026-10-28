#!/usr/bin/env bash
# Scripted check of the native Linux install, in a Debian 13 container running systemd:
# a dry run, an install from a local bundle, an upgrade in place, an uninstall that keeps
# the computer, a reinstall that finds it again, and a purge. The container has no
# /dev/kvm, so it installs with --force and checks the service and API, not a wake; run
# deploy/linux/install.sh on a real KVM machine for that (deploy/linux/README.md).
#
#   deploy/linux/check.sh [caboose-host-linux-<arch>.tar.zst]
#
# Needs Docker that can run privileged containers. Without a bundle it builds one.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
case $(docker info -f '{{.Architecture}}') in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) echo "Unsupported Docker architecture" >&2; exit 1 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-linux-check.XXXXXX")
name=caboose-linux-check-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

if [[ $# -gt 0 ]]; then
  cp "$1" "$work/caboose-host-linux-$arch.tar.zst"
else
  bash "$repo/apps/host/scripts/bundle.sh" linux "$arch" "$work" >/dev/null
fi
asset=caboose-host-linux-$arch.tar.zst

docker build -q -t caboose-linux-check - >/dev/null <<'EOF'
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus ca-certificates curl && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
EOF
docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock -v "$repo/deploy:/src/deploy:ro" -v "$work:/bundle:ro" caboose-linux-check >/dev/null
inside() { docker exec "$name" "$@"; }
for _ in $(seq 1 60); do
  state=$(inside systemctl is-system-running 2>/dev/null || true)
  [[ $state == running || $state == degraded ]] && break
  sleep 1
done

pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
health() {
  # shellcheck disable=SC2016 # expanded inside the container
  inside bash -c 'curl -s -o /dev/null -w "%{http_code}" -H "authorization: Bearer $(cat /var/lib/caboose/disks/owner-token)" http://127.0.0.1:7310/v1/health'
}

out=$(inside bash /src/deploy/linux/install.sh --dry-run --bundle "/bundle/$asset" --force 2>&1)
grep -q 'would write /etc/systemd/system/caboose-host.service' <<<"$out" || fail "the dry run does not describe the service"
inside test ! -e /opt/caboose || fail 'the dry run changed the machine'
pass 'dry run changes nothing'

out=$(inside bash /src/deploy/linux/install.sh --bundle "/bundle/$asset" --force 2>&1) || { echo "$out" >&2; fail 'install'; }
inside systemctl is-active -q caboose-host.service || fail 'the service is not active'
[[ $(health) == 200 ]] || fail 'the API does not answer with the owner token'
[[ $(inside stat -c %a /etc/caboose/host.env) == 600 ]] || fail 'host.env is not private'
[[ $(inside stat -c %a /var/lib/caboose/disks/owner-token) == 600 ]] || fail 'the owner token is not private'
[[ $(inside findmnt -no FSTYPE --target /var/lib/caboose/disks) == xfs ]] || fail 'the disk root is not reflink-capable XFS'
if ! grep -q 'caboose://connect?host=http://.*&code=' <<<"$out"; then echo "$out" >&2; fail 'no pairing link was printed'; fi
pass 'install: service active, API up, private settings and token, XFS disk root, pairing link printed'
token=$(inside cat /var/lib/caboose/disks/owner-token)

inside bash -c 'echo CABOOSE_IDLE_MS=900000 >> /etc/caboose/host.env'
inside bash /src/deploy/linux/install.sh --bundle "/bundle/$asset" --force >/dev/null 2>&1 || fail 'reinstall'
[[ $(health) == 200 ]] || fail 'the API is down after the upgrade'
inside grep -q '^CABOOSE_IDLE_MS=900000$' /etc/caboose/host.env || fail 'the upgrade lost a setting'
[[ $(inside grep -c '^CABOOSE_PORT=' /etc/caboose/host.env) == 1 ]] || fail 'the upgrade duplicated a setting'
pass 'upgrade in place keeps settings'

inside bash /src/deploy/linux/uninstall.sh >/dev/null || fail 'uninstall'
inside test ! -e /etc/systemd/system/caboose-host.service || fail 'the service remains'
inside test ! -e /opt/caboose || fail 'the program remains'
inside bash -c 'umount /var/lib/caboose/disks 2>/dev/null; mount /var/lib/caboose/disks' || true
[[ $(inside cat /var/lib/caboose/disks/owner-token) == "$token" ]] || fail 'uninstall lost the computer'
pass 'uninstall keeps the computer'

inside bash /src/deploy/linux/install.sh --bundle "/bundle/$asset" --force >/dev/null 2>&1 || fail 'install after uninstall'
[[ $(inside cat /var/lib/caboose/disks/owner-token) == "$token" ]] || fail 'the reinstall did not find the computer'
[[ $(health) == 200 ]] || fail 'the API is down after the reinstall'
pass 'reinstall finds the same computer'

inside bash /src/deploy/linux/uninstall.sh --purge --yes >/dev/null || fail 'purge'
inside test ! -e /var/lib/caboose/disks || fail 'the purge kept the disks'
inside test ! -e /etc/caboose || fail 'the purge kept the settings'
inside bash -c '! grep -q caboose /etc/fstab' || fail 'the purge kept the fstab entry'
pass 'purge deletes everything'
