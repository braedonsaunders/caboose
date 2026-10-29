#!/usr/bin/env bash
# Exercise real Debian packages, signatures and APT using only disposable state.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
for tool in python3 dpkg-deb apt-get apt-cache gpg gpgv gpgconf; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
work=$(mktemp -d)
cleanup() {
  if [[ -d "$work/gnupg" ]]; then
    gpgconf --homedir "$work/gnupg" --kill gpg-agent
  fi
  rm -rf "$work"
}
trap cleanup EXIT
# APT's sandbox user needs to traverse this test tree.
chmod 755 "$work"
mkdir -p "$work/package/DEBIAN" "$work/package/usr/share/caboose-repository-check"
cat > "$work/package/DEBIAN/control" <<'CONTROL'
Package: caboose-repository-check
Version: 1.0
Architecture: all
Maintainer: Caboose Checks <checks@example.com>
Description: Disposable repository acceptance fixture
 This package is downloaded and inspected, never installed.
CONTROL
printf 'repository acceptance\n' > "$work/package/usr/share/caboose-repository-check/marker"
dpkg-deb --build --root-owner-group "$work/package" "$work/fixture.deb"
mkdir -m 700 "$work/gnupg"
export GNUPGHOME="$work/gnupg"
# This throwaway key exists only inside this check; it establishes no product trust.
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
  'Caboose Repository Check <checks@example.com>' ed25519 sign 0
fingerprint=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
test -n "$fingerprint"
gpg --batch --export "$fingerprint" > "$work/keyring.gpg"
python3 "$here/repository.py" "$work/fixture.deb" --output "$work/repository" \
  --timestamp 1700000000 --signing-key "$fingerprint"
distribution="$work/repository/dists/trixie"
gpgv --keyring "$work/keyring.gpg" "$distribution/InRelease"
gpgv --keyring "$work/keyring.gpg" "$distribution/Release.gpg" "$distribution/Release"

mkdir -p "$work/apt/lists/partial" "$work/apt/cache/archives/partial" "$work/download"
touch "$work/apt/status"
printf 'deb [signed-by=%s] file:%s trixie main\n' "$work/keyring.gpg" "$work/repository" > "$work/sources.list"
options=(
  -o "Dir::Etc::sourcelist=$work/sources.list"
  -o "Dir::Etc::sourceparts=-"
  -o "Dir::State=$work/apt"
  -o "Dir::State::status=$work/apt/status"
  -o "Dir::Cache=$work/apt/cache"
  -o "Dir::Etc::main=-"
  -o "Dir::Etc::parts=-"
  -o "APT::Get::List-Cleanup=0"
  -o "Acquire::Languages=none"
  -o "APT::Update::Error-Mode=any"
)
# Prevent inherited host configuration/hooks from entering this isolated APT run.
cat > "$work/apt.conf" <<'CONFIG'
Dir::Etc::parts "-";
Dir::Etc::main "-";
CONFIG
export APT_CONFIG="$work/apt.conf"
apt-get "${options[@]}" update
apt-cache "${options[@]}" policy caboose-repository-check | tee "$work/policy"
grep -F 'Candidate: 1.0' "$work/policy"
(
  cd "$work/download"
  apt-get "${options[@]}" download caboose-repository-check=1.0
)
cmp "$work/fixture.deb" "$work/download/caboose-repository-check_1.0_all.deb"

# A modified signed index must be rejected, even when an older valid list exists.
python3 - "$distribution/InRelease" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = path.read_bytes()
assert b'Origin: Caboose\n' in data
path.write_bytes(data.replace(b'Origin: Caboose\n', b'Origin: Tampered\n', 1))
PY
if apt-get "${options[@]}" update > "$work/tampered.log" 2>&1; then
  cat "$work/tampered.log" >&2
  echo 'APT accepted a modified signed index' >&2
  exit 1
fi
grep -E 'BADSIG|invalid signature|signatures were invalid' "$work/tampered.log"
echo 'Real package, GPG verification, APT download and tamper rejection passed.'
