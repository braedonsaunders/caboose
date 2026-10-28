#!/usr/bin/env bash
# Checks the Caboose WSL distribution without Windows: builds the rootfs, imports it into
# Docker, boots it with systemd as PID 1, and requires that
#   - caboose-host.service is active,
#   - /v1/health answers 401 without a token and 200 with the owner token it generated,
#   - caboose-wsl-ready reports it healthy, with the token's path,
#   - caboose-keepalive blocks rather than exits,
#   - caboose-upgrade reinstalls the same rootfs in place and keeps the owner token.
#
#   deploy/windows/distro/check.sh <caboose-host-linux-amd64.tar.zst>
#   deploy/windows/distro/check.sh --rootfs <caboose-wsl-amd64.tar.gz>   # skip the build
#
# Needs Docker that runs linux/amd64 containers with systemd: an amd64 Linux host, or Docker
# Desktop with amd64 emulation (slow, but it works). The container is privileged with the
# host's cgroup namespace, as systemd needs; it is removed afterwards. Docker inside it is not
# exercised: the computer's container needs WSL's /dev/dxg and is covered by
# apps/windows/check.ps1 on a real Windows machine.

# Single-quoted commands below are expanded by the distribution's shell, not this one.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-wsl-check.XXXXXX")
image=caboose-wsl-check:$$
name=caboose-wsl-check-$$
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [[ ${1:-} == --rootfs ]]; then
  rootfs=${2:?usage: check.sh --rootfs <caboose-wsl-amd64.tar.gz>}
else
  bundle=${1:?usage: check.sh <caboose-host-linux-amd64.tar.zst> | --rootfs <caboose-wsl-amd64.tar.gz>}
  "$here/build.sh" "$bundle" "$work/out"
  rootfs=$work/out/caboose-wsl-amd64.tar.gz
fi
rootfs=$(cd "$(dirname "$rootfs")" && pwd -P)/$(basename "$rootfs")

fail() { echo "FAIL: $*" >&2; docker exec "$name" journalctl -u caboose-host --no-pager -n 50 >&2 2>/dev/null || true; exit 1; }
pass() { echo "ok: $*"; }
in_distro() { docker exec "$name" "$@"; }

echo "Importing $rootfs"
docker import --platform linux/amd64 "$rootfs" "$image" >/dev/null

echo "Booting it with systemd"
docker run -d --name "$name" --platform linux/amd64 --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -e container=docker \
  -v "$rootfs:/mnt/rootfs.tar.gz:ro" "$image" /sbin/init >/dev/null

state=
for _ in $(seq 1 180); do
  state=$(in_distro systemctl is-system-running 2>/dev/null || true)
  case $state in running | degraded) break ;; esac
  sleep 1
done
case $state in running | degraded) pass "systemd is up ($state)" ;; *) fail "systemd did not finish booting ($state)" ;; esac

for _ in $(seq 1 120); do
  in_distro test -s /var/lib/caboose/owner-token && break
  sleep 1
done
[[ $(in_distro systemctl is-active caboose-host.service) == active ]] || fail "caboose-host.service is not active"
pass "caboose-host.service is active"

health() { in_distro sh -c "curl -s -o /dev/null -w '%{http_code}' $1 http://127.0.0.1:7310/v1/health"; }
code=
for _ in $(seq 1 60); do
  code=$(health '' || true)
  [[ $code == 401 ]] && break
  sleep 1
done
[[ $code == 401 ]] || fail "/v1/health without a token answered $code, not 401"
pass "/v1/health without a token: 401"

code=$(health '-H "Authorization: Bearer $(cat /var/lib/caboose/owner-token)"')
[[ $code == 200 ]] || fail "/v1/health with the owner token answered $code, not 200"
pass "/v1/health with the owner token: 200"

ready=$(in_distro /usr/local/bin/caboose-wsl-ready)
echo "$ready"
[[ $ready == *'"healthy":true'* ]] || fail "caboose-wsl-ready does not report healthy"
[[ $ready == *'"tokenPath":"/var/lib/caboose/owner-token"'* ]] || fail "caboose-wsl-ready has the wrong tokenPath"
[[ $ready == *'"url":"http://127.0.0.1:7310"'* ]] || fail "caboose-wsl-ready has the wrong url"
pass "caboose-wsl-ready reports the host healthy"

in_distro sh -c 'timeout 5 /usr/local/bin/caboose-keepalive >/dev/null; test $? = 124' || fail "caboose-keepalive exited instead of blocking"
pass "caboose-keepalive blocks"

token=$(in_distro cat /var/lib/caboose/owner-token)
in_distro sh -c 'd=$(mktemp -d) && tar -xzf /mnt/rootfs.tar.gz -C "$d" usr/lib/caboose/caboose-upgrade && "$d/usr/lib/caboose/caboose-upgrade" /mnt/rootfs.tar.gz' ||
  fail "caboose-upgrade failed"
[[ $(in_distro cat /var/lib/caboose/owner-token) == "$token" ]] || fail "the upgrade changed the owner token"
for _ in $(seq 1 60); do
  [[ $(in_distro /usr/local/bin/caboose-wsl-ready) == *'"healthy":true'* ]] && break
  sleep 1
done
[[ $(in_distro /usr/local/bin/caboose-wsl-ready) == *'"healthy":true'* ]] || fail "caboose-host is not healthy after the upgrade"
pass "caboose-upgrade reinstalled in place and kept the owner token"

echo "All checks passed."
