#!/usr/bin/env bash
# Sets up a Caboose server on a domain: Docker (when missing), the release's caboose-host
# behind Caddy with automatic HTTPS, private settings, and a pairing link for the first
# phone. Re-running it upgrades the images and keeps every computer.
#
#   curl -fsSL https://raw.githubusercontent.com/braedonsaunders/caboose/main/deploy/server/install.sh | sudo bash -s -- --domain caboose.example.com
#   sudo deploy/linux/install.sh --domain caboose.example.com      (the same thing)
set -euo pipefail

REPO=braedonsaunders/caboose
domain=
email=
version=latest
dir=/opt/caboose-server
state=/data/caboose
dry_run=0
force=0

usage() {
  cat <<'EOF'
Usage: install.sh --domain <name> [options]

  --domain <name>      The server's domain; its DNS must point at this machine (required)
  --email <address>    Email for the Let's Encrypt account (expiry notices)
  --version <tag>      Release to run (default: latest)
  --dir <path>         Where the compose project lives (default /opt/caboose-server)
  --state-dir <path>   Where computers and the host's state live (default /data/caboose)
  --force              Continue when /dev/kvm is missing or the DNS check fails
  --dry-run            Print what would happen and change nothing
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) domain=${2:?--domain needs a name}; shift 2 ;;
    --email) email=${2:?--email needs an address}; shift 2 ;;
    --version) version=${2:?--version needs a tag}; shift 2 ;;
    --dir) dir=${2:?--dir needs a path}; shift 2 ;;
    --state-dir) state=${2:?--state-dir needs a path}; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run() { if [[ $dry_run == 1 ]]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }
check() { if [[ $force == 1 ]]; then warn "$1"; else die "$1 (--force continues anyway)"; fi; }

[[ -n $domain ]] || { usage >&2; exit 2; }
[[ $domain =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "$domain is not a domain name"
[[ -z $email || $email =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "$email is not an email address"
[[ $version =~ ^[A-Za-z0-9._+-]+$ ]] || die "--version must be a release tag"
[[ $dir == /* && $dir != *[$'\n\r\t ']* ]] || die "--dir must be absolute without whitespace"
# An upgrade must never silently point an existing stack at a different computer directory.
if [[ -f $dir/.env ]]; then
  while IFS='=' read -r key value; do
    case $value in \"*\") value=${value:1:${#value}-2} ;; \'*\') value=${value:1:${#value}-2} ;; esac
    [[ $key != CABOOSE_STATE_DIR ]] || state=$value
  done <"$dir/.env"
fi
[[ $state == /* && $state != *[$'\n\r\t $&|']* ]] || die "--state-dir must be an absolute path without whitespace or shell metacharacters"
[[ $(uname -s) == Linux ]] || die "a Caboose server runs on Linux"
case $(uname -m) in x86_64 | amd64 | aarch64 | arm64) ;; *) die "Caboose runs on amd64 and arm64, not $(uname -m)" ;; esac
[[ $dry_run == 1 || $(id -u) == 0 ]] || die "run it as root, for example with sudo"

[[ -e /dev/kvm ]] || check "/dev/kvm is missing, so this server cannot run computers. Use a bare-metal server or a VM type with nested virtualization."

# The certificate needs the domain to reach this machine on ports 80 and 443.
if command -v getent >/dev/null; then
  resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
  public=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ -z $resolved ]]; then
    check "$domain does not resolve yet; add an A record for this server${public:+ ($public)}"
  elif [[ -n $public && $resolved != "$public" ]]; then
    check "$domain points at $resolved, but this server's public address is $public"
  fi
fi
if command -v ss >/dev/null; then
  for port in 80 443; do
    holder=$(ss -Hltnp "sport = :$port" 2>/dev/null | grep -v docker-proxy | head -n 1 || true)
    [[ -z $holder ]] || check "port $port is already in use: $holder"
  done
fi

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker Engine (https://get.docker.com)"
  if [[ $dry_run == 1 ]]; then echo '  would run: curl -fsSL https://get.docker.com | sh'; else curl -fsSL https://get.docker.com | sh; fi
  run systemctl enable --now docker
fi

say "Writing the compose project to $dir"
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)
ref=main
[[ $version == latest ]] || ref=$version
fetch() {
  local name=$1
  if [[ $dry_run == 1 ]]; then printf '  would write %s/%s\n' "$dir" "$name"; return; fi
  if [[ -n $here && -f $here/$name ]]; then cp "$here/$name" "$dir/$name"
  else curl -fsSL --retry 3 -o "$dir/$name" "https://raw.githubusercontent.com/$REPO/$ref/deploy/server/$name"
  fi
}
run mkdir -p "$dir/caddy-options" "$state"
fetch compose.yaml
fetch Caddyfile
if [[ -n $email ]]; then
  if [[ $dry_run == 1 ]]; then echo "  would write $dir/caddy-options/email.caddy"
  else printf '{\n\temail %s\n}\n' "$email" >"$dir/caddy-options/email.caddy"
  fi
fi

# .env: written once with mode 0600; later runs change only the domain and version.
env_file=$dir/.env
set_value() {
  local name=$1 value=$2
  if [[ $dry_run == 1 ]]; then printf '  would set %s=%s in %s\n' "$name" "$value" "$env_file"; return; fi
  if grep -q "^$name=" "$env_file"; then sed -i "s|^$name=.*|$name=$value|" "$env_file"; else printf '%s=%s\n' "$name" "$value" >>"$env_file"; fi
}
if [[ $dry_run == 0 && ! -f $env_file ]]; then
  install -m 0600 /dev/null "$env_file"
  echo '# Caboose server settings (deploy/server/README.md). Apply with: docker compose up -d' >>"$env_file"
fi
set_value CABOOSE_DOMAIN "$domain"
set_value CABOOSE_VERSION "$version"
set_value CABOOSE_STATE_DIR "$state"

compose() { docker compose --project-directory "$dir" -f "$dir/compose.yaml" "$@"; }
say "Starting Caboose"
if [[ $dry_run == 1 ]]; then
  echo "  would run: docker compose -f $dir/compose.yaml pull && up -d"
  exit 0
fi
compose pull --quiet
compose up -d --remove-orphans

# Calls the host's API from inside its container, where node reads the owner token itself,
# so the token never appears on a command line.
host_api() {
  local method=$1 path=$2 print=$3
  compose exec -T caboose-host node -e "
    const fs = require('fs')
    const token = process.env.CABOOSE_OWNER_TOKEN || fs.readFileSync(process.env.CABOOSE_IMAGE_ROOT + '/owner-token', 'utf8').trim()
    fetch('http://127.0.0.1:7310$path', { method: '$method', headers: { authorization: 'Bearer ' + token } })
      .then(async r => { if (!r.ok) process.exit(1); const body = await r.json(); $print })
      .catch(() => process.exit(1))"
}
say "Waiting for the host"
up=0
for _ in $(seq 1 90); do
  if host_api GET /v1/health '' >/dev/null 2>&1; then up=1; break; fi
  sleep 2
done
[[ $up == 1 ]] || { compose logs --tail 40 caboose-host >&2; die "caboose-host did not come up; see: docker compose -f $dir/compose.yaml logs"; }

if ! curl -fsS --max-time 20 -o /dev/null "https://$domain/" 2>/dev/null; then
  warn "https://$domain/ does not answer yet. Caddy keeps trying to get the certificate; check DNS and that ports 80 and 443 reach this server (docker compose -f $dir/compose.yaml logs caddy)."
fi

echo
say "Caboose is running at https://$domain"
setup_code=$(compose exec -T caboose-host node -e '
  const fs = require("fs"), path = require("path").join(process.env.CABOOSE_IMAGE_ROOT, "setup-code")
  if (fs.existsSync(path)) process.stdout.write(fs.readFileSync(path, "utf8").trim())' 2>/dev/null || true)
if [[ -n $setup_code ]]; then echo "  Set up:       https://$domain/setup?code=$setup_code"; fi
echo "  Owner token:  docker compose -f $dir/compose.yaml exec caboose-host cat /data/caboose/disks/owner-token"
echo "  Settings:     $env_file (then: docker compose -f $dir/compose.yaml up -d)"
code=$(host_api POST /v1/computers/owner/pairing 'console.log(body.code ?? "")' 2>/dev/null || true)
if [[ -n $code ]]; then
  link="caboose://connect?host=https://$domain&code=$code"
  echo
  say "Pair your iPhone: scan this with the Camera within 10 minutes, or open the link on the phone."
  if command -v qrencode >/dev/null; then qrencode -t ansiutf8 "$link"; fi
  echo "  $link"
fi
echo
echo "The computer's image downloads in the background on first start; the console shows its progress."
