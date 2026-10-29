#!/usr/bin/env bash
# Installs Caboose natively on a Linux machine: the caboose-host bundle from a GitHub Release
# (or a local one), a reflink-capable disk root, a systemd service, and then a pairing link
# for the iPhone. Re-running it upgrades in place and keeps the computer and its settings.
#
#   curl -fsSL https://raw.githubusercontent.com/braedonsaunders/caboose/main/deploy/linux/install.sh | sudo bash
#   curl -fsSL …/install.sh | sudo bash -s -- --version v0.2.0 --runtime container
#
# See deploy/linux/README.md for every option.
set -euo pipefail

REPO=braedonsaunders/caboose
version=latest
bundle=
runtime=microvm
bind=0.0.0.0
port=7310
state=/var/lib/caboose
disk_size=400G
domain=
email=
public_url=
dry_run=0
force=0
start=1

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --version <tag>      Release to install (default: the latest release)
  --bundle <path>      Install this caboose-host-linux-<arch>.tar.zst instead of downloading
  --runtime <kind>     microvm (default; needs /dev/kvm) or container (needs Docker)
  --bind <address>     Address the host listens on (default 0.0.0.0, so phones on the LAN reach it)
  --port <port>        Port (default 7310)
  --state-dir <path>   Where the computer and the host's state live (default /var/lib/caboose)
  --disk-size <size>   Maximum size of the computer's disk image when one is needed (default 400G)
  --domain <name>      Set up a server with HTTPS for this domain instead (deploy/server)
  --email <address>    With --domain: the ACME account email
  --force              Install even when this machine cannot run a computer yet
  --no-start           Install without starting the service
  --dry-run            Print what would happen and change nothing
  -h, --help           This help
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --version) version=${2:?--version needs a tag}; shift 2 ;;
    --bundle) bundle=${2:?--bundle needs a path}; shift 2 ;;
    --runtime) runtime=${2:?--runtime needs microvm or container}; shift 2 ;;
    --bind) bind=${2:?--bind needs an address}; shift 2 ;;
    --port) port=${2:?--port needs a number}; shift 2 ;;
    --state-dir) state=${2:?--state-dir needs a path}; shift 2 ;;
    --disk-size) disk_size=${2:?--disk-size needs a size}; shift 2 ;;
    --domain) domain=${2:?--domain needs a name}; shift 2 ;;
    --email) email=${2:?--email needs an address}; shift 2 ;;
    --force) force=1; shift ;;
    --no-start) start=0; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run() {
  if [[ $dry_run == 1 ]]; then printf '  would run: %s\n' "$*"; else "$@"; fi
}
# A package manager's progress is noise here; its errors still reach the terminal.
quietly() {
  if [[ $dry_run == 1 ]]; then run "$@"; else "$@" >/dev/null; fi
}

if [[ -n $domain ]]; then
  # A server: Caddy with automatic HTTPS in front of the release image (deploy/server).
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)
  server_args=(--domain "$domain" --version "$version")
  [[ -z $email ]] || server_args+=(--email "$email")
  [[ $dry_run == 0 ]] || server_args+=(--dry-run)
  if [[ -n $here && -f $here/../server/install.sh ]]; then exec bash "$here/../server/install.sh" "${server_args[@]}"; fi
  ref=main
  [[ $version == latest ]] || ref=$version
  exec bash <(curl -fsSL "https://raw.githubusercontent.com/$REPO/$ref/deploy/server/install.sh") "${server_args[@]}"
fi

# The service keeps its settings across upgrades. Use the same settings for prerequisites,
# mounts and health checks; command-line defaults must not silently select another computer.
images=$state/disks
env_file=/etc/caboose/host.env
if [[ -f $env_file ]]; then
  while IFS='=' read -r key value; do
    case $value in \"*\") value=${value:1:${#value}-2} ;; \'*\') value=${value:1:${#value}-2} ;; esac
    case $key in
      CABOOSE_RUNTIME) runtime=$value ;;
      CABOOSE_BIND) bind=$value ;;
      CABOOSE_PORT) port=$value ;;
      CABOOSE_IMAGE_ROOT) images=$value; state=$(dirname "$images") ;;
      CABOOSE_PUBLIC_URL) public_url=$value ;;
    esac
  done <"$env_file"
fi
[[ $state == /* && $state != *[$'\n\r\t ']* && $images == /* && $images != *[$'\n\r\t ']* ]] || die "state paths must be absolute and contain no whitespace"
[[ $bind =~ ^[a-zA-Z0-9.:_-]+$ ]] || die "--bind must be an IP address or hostname"

[[ $runtime == microvm || $runtime == container ]] || die "--runtime must be microvm or container"
[[ $port =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || die "--port must be a port number"
[[ $(uname -s) == Linux ]] || die "this installer is for Linux; see docs for Windows and macOS"
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "Caboose runs on amd64 and arm64, not $(uname -m)" ;;
esac
if [[ $dry_run == 0 && $(id -u) != 0 ]]; then
  die "run it as root, for example: curl -fsSL …/install.sh | sudo bash"
fi
command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die "Caboose installs as a systemd service, and this machine is not running systemd"

# Can this machine run a computer?
if [[ $runtime == microvm ]]; then
  if [[ ! -e /dev/kvm ]]; then
    msg="/dev/kvm is missing, so this machine cannot run the computer as a microVM. Turn on hardware virtualization (Intel VT-x or AMD-V, often called SVM) in the firmware settings; in a virtual machine, enable nested virtualization. Or use --runtime container with Docker."
    if [[ $force == 1 ]]; then warn "$msg"; else die "$msg (--force installs anyway)"; fi
  fi
else
  command -v docker >/dev/null || die "--runtime container needs Docker: https://docs.docker.com/engine/install/"
fi

# Packages the host uses at runtime: ip and iptables for the computer's fenced network,
# xfsprogs for a reflink disk image, zstd to unpack the bundle, and qrencode for the pairing QR.
need=()
for tool in curl tar zstd ip iptables findmnt; do command -v "$tool" >/dev/null || need+=("$tool"); done
[[ $runtime == container ]] || command -v mkfs.xfs >/dev/null || need+=(mkfs.xfs)
if [[ ${#need[@]} -gt 0 ]]; then
  say "Installing ${need[*]}"
  if command -v apt-get >/dev/null; then
    quietly apt-get update -qq
    quietly env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates tar zstd iproute2 iptables xfsprogs util-linux
  elif command -v dnf >/dev/null; then
    quietly dnf install -y -q curl tar zstd iproute iptables xfsprogs util-linux
  elif command -v pacman >/dev/null; then
    quietly pacman -Sy --noconfirm --needed curl tar zstd iproute2 iptables xfsprogs util-linux
  elif command -v zypper >/dev/null; then
    quietly zypper --non-interactive install curl tar zstd iproute2 iptables xfsprogs util-linux
  else
    die "install these first: ${need[*]}"
  fi
fi
if ! command -v qrencode >/dev/null; then
  # Optional: without it the pairing link is printed as text.
  if command -v apt-get >/dev/null; then run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null; then run dnf install -y -q qrencode >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null; then run pacman -S --noconfirm --needed qrencode >/dev/null 2>&1 || true
  fi
fi

sha256() { sha256sum "$1" | cut -d' ' -f1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The bundle: given, or downloaded and checked against the release's SHA256SUMS.
asset=caboose-host-linux-$arch.tar.zst
if [[ -n $bundle ]]; then
  [[ -f $bundle ]] || die "no bundle at $bundle"
  say "Using $bundle"
else
  if [[ $version == latest ]]; then base="https://github.com/$REPO/releases/latest/download"; else base="https://github.com/$REPO/releases/download/$version"; fi
  say "Downloading $asset ($version)"
  if [[ $dry_run == 1 ]]; then
    printf '  would download: %s/%s and %s/SHA256SUMS\n' "$base" "$asset" "$base"
  else
    curl -fsSL --retry 3 -o "$work/$asset" "$base/$asset" ||
      die "could not download $base/$asset. Check the release has a $arch bundle (https://github.com/$REPO/releases), or build one from a checkout and pass --bundle (deploy/linux/README.md)"
    curl -fsSL --retry 3 -o "$work/SHA256SUMS" "$base/SHA256SUMS" || die "could not download $base/SHA256SUMS"
    expected=$(awk -v name="$asset" '$2 == name { print $1 }' "$work/SHA256SUMS")
    [[ -n $expected ]] || die "SHA256SUMS does not list $asset"
    [[ $(sha256 "$work/$asset") == "$expected" ]] || die "$asset does not match the release's SHA-256"
    bundle=$work/$asset
  fi
fi

installed_version=dev
if [[ $dry_run == 0 ]]; then
  zstd -dc "$bundle" | tar -xf - -C "$work"
  [[ -x $work/caboose-host/bin/caboose-host ]] || die "$bundle is not a caboose-host bundle"
  installed_version=$(cat "$work/caboose-host/VERSION")
  [[ $installed_version =~ ^[A-Za-z0-9._+-]+$ ]] || die "the bundle has an invalid VERSION"
fi

say "Installing caboose-host $installed_version to /opt/caboose"
run mkdir -p /opt/caboose
if [[ $dry_run == 0 ]]; then
  rm -rf "/opt/caboose/$installed_version.new"
  mv "$work/caboose-host" "/opt/caboose/$installed_version.new"
  rm -rf "/opt/caboose/$installed_version"
  mv "/opt/caboose/$installed_version.new" "/opt/caboose/$installed_version"
  ln -sfn "/opt/caboose/$installed_version" /opt/caboose/current.new
  mv -T /opt/caboose/current.new /opt/caboose/current
  ln -sfn /opt/caboose/current/bin/caboose-host /usr/local/bin/caboose-host
  # Keep the previous release for a rollback, and nothing older.
  find /opt/caboose -mindepth 1 -maxdepth 1 -type d ! -name "$installed_version" -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | tail -n +2 | cut -d' ' -f2- | xargs -r rm -rf
fi

# The disk root: reflink-capable for the microVM's copy-on-write disk (an XFS image file
# when the filesystem is not), a plain directory for the container runtime.
run mkdir -p "$state"
run chmod 0700 "$state"
if [[ $runtime == microvm ]]; then
  say "Preparing the computer's disk root at $images"
  run env SUDO_USER=root /opt/caboose/current/bin/caboose-setup-disks "$images" "$disk_size"
else
  run mkdir -p "$images"
fi

# Settings: written once, then only missing keys are added, so edits survive upgrades.
run mkdir -p /etc/caboose
run chmod 0755 /etc/caboose
set_default() {
  local name=$1 value=$2
  if [[ $dry_run == 1 ]]; then printf '  would set %s=%s in %s (unless already set)\n' "$name" "$value" "$env_file"; return; fi
  grep -q "^$name=" "$env_file" 2>/dev/null || printf '%s=%s\n' "$name" "$value" >>"$env_file"
}
if [[ $dry_run == 0 && ! -f $env_file ]]; then
  install -m 0600 /dev/null "$env_file"
  echo "# caboose-host settings (apps/host/README.md, Configuration). Restart the service after a change." >>"$env_file"
fi
set_default CABOOSE_RUNTIME "$runtime"
set_default CABOOSE_BIND "$bind"
set_default CABOOSE_PORT "$port"
set_default CABOOSE_IMAGE_ROOT "$images"

unit=/etc/systemd/system/caboose-host.service
say "Installing the caboose-host service"
if [[ $dry_run == 1 ]]; then
  printf '  would write %s\n' "$unit"
else
  cat >"$unit" <<EOF
[Unit]
Description=Caboose host
Documentation=https://github.com/$REPO/blob/main/deploy/linux/README.md
After=network-online.target$([[ $runtime == container ]] && printf ' docker.service')
Wants=network-online.target
$([[ $runtime == container ]] && printf 'Requires=docker.service')
RequiresMountsFor=$images

[Service]
Type=simple
EnvironmentFile=$env_file
ExecStart=/opt/caboose/current/bin/caboose-host
Restart=on-failure
RestartSec=5
# Parking writes the computer's memory to disk before the host exits.
TimeoutStopSec=150
KillMode=mixed
# Root for /dev/kvm, the TAP device and the fence's iptables rules; the rest is fenced off.
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
fi
run systemctl daemon-reload
run systemctl enable caboose-host.service

if [[ $start == 0 ]]; then
  say "Installed. Start it with: systemctl start caboose-host"
  exit 0
fi
say "Starting Caboose"
run systemctl restart caboose-host.service
[[ $dry_run == 0 ]] || exit 0

token_file=$images/owner-token
case $bind in
  0.0.0.0) health_host=127.0.0.1 ;;
  ::) health_host='[::1]' ;;
  *:*) health_host="[$bind]" ;;
  *) health_host=$bind ;;
esac
url=http://$health_host:$port
healthy=0
for _ in $(seq 1 60); do
  if [[ -s $token_file ]] && [[ $(curl -s -o /dev/null -w '%{http_code}' -H "authorization: Bearer $(cat "$token_file")" "$url/v1/health") == 200 ]]; then
    healthy=1
    break
  fi
  sleep 1
done
if [[ $healthy == 0 ]]; then
  journalctl -u caboose-host.service -n 30 --no-pager >&2 || true
  die "caboose-host did not come up; see journalctl -u caboose-host"
fi
token=$(cat "$token_file")

# Where a phone can reach it: every address on this machine when it listens on all of them.
addresses=()
if [[ $bind == 0.0.0.0 || $bind == :: ]]; then
  # IPv4 on real interfaces: not Docker's or Caboose's own bridges, VM taps or veths.
  while read -r _ iface _ cidr _; do
    case $iface in lo | docker* | br-* | caboose* | veth* | tap* | virbr* | tailscale*) continue ;; esac
    addresses+=("http://${cidr%/*}:$port")
  done < <(ip -o -4 addr show scope global 2>/dev/null)
elif [[ $bind != 127.* && $bind != localhost && $bind != ::1 ]]; then
  addresses+=("$url")
fi

# A configured public URL is where phones reach the host from anywhere; it leads the link.
[[ -z $public_url ]] || addresses=("$public_url" "${addresses[@]}")

# In WSL, NAT networking (its default) puts Linux on a virtual network that only Windows
# reaches; mirrored networking gives Linux the PC's own addresses.
wsl_mode=
if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  wsl_mode=$(wslinfo --networking-mode 2>/dev/null || true)
  [[ -n $wsl_mode ]] || wsl_mode=unknown
fi

echo
say "Caboose $installed_version is running."
if [[ ${#addresses[@]} -gt 0 ]]; then
  echo "  Console:      ${addresses[0]}  (also $url on this machine)"
else
  echo "  Console:      $url (this machine only: --bind is $bind)"
fi
if [[ -s $images/setup-code ]]; then
  # Open it from any browser that reaches the console: the server may have no screen.
  echo "  Set up:       ${addresses[0]:-$url}/setup?code=$(cat "$images/setup-code")"
fi
echo "  Owner token:  sudo cat $token_file"
echo "  Settings:     $env_file (then: systemctl restart caboose-host)"

if [[ ${#addresses[@]} -gt 0 ]]; then
  pairing=$(curl -fsS -X POST -H "authorization: Bearer $token" "$url/v1/computers/owner/pairing" 2>/dev/null || true)
  code=$(printf '%s' "$pairing" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')
  if [[ -n $code ]]; then
    link="caboose://connect?host=${addresses[0]}"
    for extra in "${addresses[@]:1}"; do link+="&alt=$extra"; done
    link+="&code=$code"
    echo
    say "Pair your iPhone: scan this with the Camera within 10 minutes, or open the link on the phone."
    if command -v qrencode >/dev/null; then qrencode -t ansiutf8 "$link"; fi
    echo "  $link"
    echo "  A new code later: Computers › your computer › Phones › Sign in a phone, in the console."
  fi
fi
if [[ -n $wsl_mode && $wsl_mode != mirrored ]]; then
  echo
  if [[ $wsl_mode == nat ]]; then
    warn "WSL is using NAT networking: this distribution's own addresses are reachable only from this Windows PC."
  else
    warn "could not tell WSL's networking mode (wslinfo is missing; WSL may be older than 2.0)."
  fi
  echo "  Phones reach Caboose through a forwarder on Windows, such as netsh portproxy, which delays touch"
  echo "  and scrolling, or through a configured CABOOSE_PUBLIC_URL. On Windows 11 22H2 or later with"
  echo "  WSL 2.0 or later, mirrored networking connects phones directly. In an administrator PowerShell:"
  echo "    irm https://raw.githubusercontent.com/$REPO/main/deploy/windows/setup-wsl.ps1 -OutFile setup-wsl.ps1"
  echo "    powershell -ExecutionPolicy Bypass -File setup-wsl.ps1 -Port $port -Restart"
  echo "  See deploy/windows/README.md."
fi
echo
if [[ $runtime == microvm ]] && ! grep -q '^CABOOSE_BASE_IMAGE=.' "$env_file" /opt/caboose/current/defaults.env; then
  warn "this release names no computer image to fetch; build one with guest/image/build.sh into $images"
else
  echo "The computer's image downloads in the background on first start; the console shows its progress."
fi
echo "Traffic is plain HTTP on your network. To reach Caboose away from home, use Tailscale or a domain with HTTPS (deploy/server)."
