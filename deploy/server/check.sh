#!/usr/bin/env bash
# Scripted check of the server deployment.
#
#   deploy/server/check.sh          shellcheck, compose and Caddy validation, an installer dry run
#   deploy/server/check.sh --e2e    also runs the stack with a locally built host image behind
#                                   Caddy on https://localhost (Caddy's own CA) and checks the
#                                   console, the API's token, a WebSocket upgrade through the
#                                   proxy, and that only Caddy publishes ports
#
# Needs Docker. The end-to-end run has no /dev/kvm, so it does not wake a computer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
e2e=0
[[ ${1:-} == --e2e ]] && e2e=1
work=$(mktemp -d "${TMPDIR:-/tmp}/caboose-server-check.XXXXXX")
project=caboose-server-check-$$
cleanup() {
  if [[ $e2e == 1 ]]; then
    docker compose -p "$project" --project-directory "$work/project" -f "$work/project/compose.yaml" down -v >/dev/null 2>&1 || true
    docker run --rm -v "$work:/work" debian:trixie-slim sh -c 'umount /work/state/disks 2>/dev/null; rm -rf /work/state' >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
pass() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

shellcheck "$here"/*.sh
pass 'shellcheck'

CABOOSE_DOMAIN=caboose.example.com docker compose -f "$here/compose.yaml" config -q || fail 'compose config'
missing=$(unset CABOOSE_DOMAIN; docker compose -f "$here/compose.yaml" config -q 2>&1 || true)
grep -q 'Set CABOOSE_DOMAIN' <<<"$missing" || fail 'compose config does not insist on CABOOSE_DOMAIN'
published=$(CABOOSE_DOMAIN=caboose.example.com docker compose -f "$here/compose.yaml" config --format json | node -e "
  const c = JSON.parse(require('fs').readFileSync(0, 'utf8'))
  console.log(Object.entries(c.services).filter(([, s]) => (s.ports ?? []).length).map(([n]) => n).join(','))")
[[ $published == caddy ]] || fail "services other than Caddy publish ports: $published"
pass 'compose is valid and only Caddy publishes ports'

mkdir -p "$work/options"
validate() {
  docker run --rm -e CABOOSE_DOMAIN=caboose.example.com -v "$here/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$work/options:/etc/caddy/options:ro" caddy:2.11 \
    caddy adapt --config /etc/caddy/Caddyfile --validate 2>/dev/null
}
validate | grep -q 'caboose.example.com' || fail 'the Caddyfile does not validate without options'
printf '{\n\temail admin@example.com\n}\n' >"$work/options/email.caddy"
validate | grep -q '"email":"admin@example.com"' || fail 'the ACME email option is not applied'
pass 'the Caddyfile validates, with and without an ACME email'

out=$(docker run --rm -v "$here:/server:ro" debian:trixie-slim bash /server/install.sh --domain caboose.example.com --email admin@example.com --force --dry-run 2>&1) || { echo "$out" >&2; fail 'dry run'; }
grep -q 'would write /opt/caboose-server/compose.yaml' <<<"$out" || { echo "$out" >&2; fail 'the dry run does not describe the project'; }
grep -q 'would set CABOOSE_DOMAIN=caboose.example.com' <<<"$out" || fail 'the dry run does not set the domain'
if docker run --rm -v "$here:/server:ro" debian:trixie-slim bash /server/install.sh --domain 'not a domain' --dry-run >/dev/null 2>&1; then fail 'an invalid domain was accepted'; fi
pass 'installer dry run, and refusal of an invalid domain'

[[ $e2e == 1 ]] || exit 0

docker build -q -t caboose-host:check -f "$repo/apps/host/Dockerfile" "$repo" >/dev/null || fail 'building the host image'
mkdir -p "$work/project/caddy-options" "$work/state"
cp "$here/compose.yaml" "$here/Caddyfile" "$work/project/"
cat >"$work/project/.env" <<EOF
CABOOSE_DOMAIN=localhost
CABOOSE_HOST_IMAGE=caboose-host:check
CABOOSE_STATE_DIR=$work/state
CABOOSE_HTTP_PORT=18080
CABOOSE_HTTPS_PORT=18443
EOF
compose() { docker compose -p "$project" --project-directory "$work/project" -f "$work/project/compose.yaml" "$@"; }
compose up -d >/dev/null 2>&1 || { compose logs >&2; fail 'compose up'; }

for _ in $(seq 1 90); do
  [[ $(curl -sk -o /dev/null -w '%{http_code}' https://localhost:18443/) == 200 ]] && break
  sleep 2
done
[[ $(curl -sk -o /dev/null -w '%{http_code}' https://localhost:18443/) == 200 ]] || { compose logs --tail 30 >&2; fail 'the console is not served over HTTPS'; }
pass 'the console is served over HTTPS through Caddy'
token=$(compose exec -T caboose-host cat /data/caboose/disks/owner-token)
[[ $(curl -sk -o /dev/null -w '%{http_code}' https://localhost:18443/v1/health) == 401 ]] || fail 'the API answers without a token'
[[ $(curl -sk -o /dev/null -w '%{http_code}' -H "authorization: Bearer $token" https://localhost:18443/v1/health) == 200 ]] || fail 'the API refuses the owner token'
reach=$(curl -sk -H "authorization: Bearer $token" https://localhost:18443/v1/host/reach)
grep -q '"url":"https://localhost","kind":"public"' <<<"$reach" || fail "the host does not name its public URL: $reach"
pass 'the API needs the owner token and names https://localhost as its public address'
# Without /dev/kvm no computer runs, and the host answers an upgrade with 409 by contract;
# Caddy never answers 409 itself (an unreachable upstream is 502), so a 409 it relays proves
# the upgrade crossed Caddy and reached the host. A running computer gives 101.
upgrade=$(curl -sk --http1.1 -D - --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "authorization: Bearer $token" https://localhost:18443/v1/control || true)
status=$(head -n 1 <<<"$upgrade" | awk '{ print $2 }')
if [[ $status == 101 ]]; then pass 'a WebSocket upgrade passes through Caddy (101)'
elif [[ $status == 409 ]] && grep -qi '^via: .*caddy' <<<"$upgrade"; then pass 'a WebSocket upgrade reaches the host through Caddy (409 from the host: no computer is running)'
else echo "$upgrade" >&2; fail "a WebSocket upgrade through Caddy answered ${status:-nothing}"; fi
[[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:7310/ || true) == 000 ]] || fail 'the host is reachable without Caddy'
pass 'the host itself publishes no port'
