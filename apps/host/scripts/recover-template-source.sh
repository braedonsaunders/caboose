#!/usr/bin/env bash
# Explicit recovery for a source builder interrupted after its private TAP was created.
set -euo pipefail
exec python3 - "$0" "$@" <<'PYLOCK'
import fcntl, os, sys
script, *args = sys.argv[1:]
if not args:
    raise SystemExit('usage: recover-template-source.sh IMAGE_ROOT SOURCE_ID')
root = os.path.realpath(args[0])
path = os.path.join(root, '.host.lock')
try:
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
except FileExistsError:
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
else:
    owner = os.stat(root)
    os.fchown(fd, owner.st_uid, owner.st_gid)
    os.fsync(fd)
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(directory)
    finally: os.close(directory)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Caboose image root is locked by a host or VM')
os.set_inheritable(fd, True)
with open(script, encoding='utf8') as source:
    body = source.read().split('\n# RECOVERY_BODY\n', 1)[1]
os.execv('/bin/bash', ['/bin/bash', '-c', body, script, *args])
PYLOCK
# RECOVERY_BODY
root=${1:?usage: recover-template-source.sh IMAGE_ROOT SOURCE_ID}
id=${2:?usage: recover-template-source.sh IMAGE_ROOT SOURCE_ID}
[[ $(id -u) = 0 ]] || { echo 'Run as root so every VMM and TAP is visible.' >&2; exit 1; }
[[ $root = /* && $id =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid image root or source ID' >&2; exit 2; }
source_dir="$root/templates/$id"
[[ -d $source_dir && ! -L $source_dir ]] || { echo 'Invalid source directory.' >&2; exit 1; }
receipt="$source_dir/.build.json"
[[ -f $receipt && ! -L $receipt ]] || { echo 'No source build receipt; inspect the directory manually.' >&2; exit 1; }
command -v node >/dev/null || { echo 'node is required to inspect the receipt.' >&2; exit 1; }
fields=()
while IFS= read -r line; do fields+=("$line"); done < <(node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(v.version!==1||typeof v.tap!=="string"||typeof v.runtime!=="string")process.exit(1);console.log(v.tap);console.log(v.runtime)' "$receipt")
[[ ${#fields[@]} = 2 ]] || { echo 'Invalid build receipt.' >&2; exit 1; }
tap=${fields[0]}
runtime=${fields[1]}
owner_receipt="$source_dir/.tap-owner.json"
[[ -f $owner_receipt && ! -L $owner_receipt ]] || { echo 'TAP ownership was not committed; inspect it manually.' >&2; exit 1; }
ownership=()
while IFS= read -r line; do ownership+=("$line"); done < <(node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(v.version!==1||typeof v.tap!=="string"||typeof v.alias!=="string"||!Number.isSafeInteger(v.ifindex)||v.ifindex<1)process.exit(1);console.log(v.tap);console.log(v.alias);console.log(v.ifindex)' "$owner_receipt")
[[ ${#ownership[@]} = 3 && ${ownership[0]} = "$tap" && ${ownership[1]} =~ ^caboose-template-[0-9a-f-]{36}$ ]] || { echo 'Invalid TAP ownership marker.' >&2; exit 1; }
expected_alias=${ownership[1]}
expected_index=${ownership[2]}
[[ $tap =~ ^dsk[0-9]{9}$ && $runtime = "$root"/runtime/tpl-* && $runtime != *'..'* ]] || { echo 'Invalid build receipt paths.' >&2; exit 1; }
if [[ -e $runtime && ( ! -d $runtime || -L $runtime ) ]]; then echo 'Invalid runtime directory.' >&2; exit 1; fi
api="$runtime/desk-source.api.sock"
# Do not infer ownership from a PID file. Refuse if any process still has the
# private API path in its argument vector. Inspect all readable Linux processes.
for cmdline in /proc/[0-9]*/cmdline; do
  [[ -e $cmdline ]] || continue
  [[ -r $cmdline ]] || { echo "Cannot inspect $cmdline; run as root." >&2; exit 1; }
  if tr '\0' '\n' < "$cmdline" | grep -Fxq -- "$api"; then
    echo 'A process still references the source VMM API socket; stop it and retry.' >&2
    exit 1
  fi
done
command -v ss >/dev/null || { echo 'ss is required to verify the socket.' >&2; exit 1; }
if ss -xlH | grep -Fq -- "$api"; then echo 'The source VMM API socket is still listening.' >&2; exit 1; fi
if ip link show dev "$tap" >/dev/null 2>&1; then
  index=$(cat "/sys/class/net/$tap/ifindex")
  for fdinfo in /proc/[0-9]*/fdinfo/*; do
    [[ -r $fdinfo ]] || continue
    if grep -qE "^iff:[[:space:]]*$tap([[:space:]]|$)" "$fdinfo" 2>/dev/null; then
      echo 'A process still has the source TAP open; inspect it before recovery.' >&2
      exit 1
    fi
  done
  [[ $index = "$expected_index" && $(cat "/sys/class/net/$tap/ifalias") = "$expected_alias" ]] || { echo 'TAP ownership marker does not match; inspect it manually.' >&2; exit 1; }
  owner=$(ip tuntap show dev "$tap")
  [[ $owner = *"user $(stat -c %u "$source_dir")"* ]] || { echo 'TAP owner does not match the source directory; inspect it manually.' >&2; exit 1; }
  ip link del dev "$tap"
fi
comment="caboose-template-$tap"
for binary in iptables ip6tables; do
  for pair in 'INPUT -i' 'OUTPUT -o' 'FORWARD -i' 'FORWARD -o'; do
    read -r chain direction <<< "$pair"
    while "$binary" -w -C "$chain" "$direction" "$tap" -m comment --comment "$comment" -j DROP 2>/dev/null; do
      "$binary" -w -D "$chain" "$direction" "$tap" -m comment --comment "$comment" -j DROP
    done
  done
done
if [[ -d $runtime ]]; then
  rm -f -- "$runtime/desk-source.api.sock" "$runtime/desk-source.vsock"
  rmdir -- "$runtime" || { echo 'Runtime directory contains unexpected files; inspect it manually.' >&2; exit 1; }
fi
if [[ -e "$source_dir/.ready" ]]; then
  rm -f -- "$owner_receipt" "$receipt"
  sync -d "$source_dir"
  echo 'Recovered the completed template source; it remains registered.'
else
  if [[ -e "$source_dir/source.snapshot/memory-ranges" ]] && [[ $(stat -c %h "$source_dir/source.snapshot/memory-ranges") -ne 1 ]]; then
    echo 'Template source has descendant memory pins; retain it for manual recovery.' >&2
    exit 1
  fi
  rm -f -- "$owner_receipt" "$receipt"
  sync -d "$source_dir"
  echo "No live source VMM or descendant pin was found. Move the incomplete directory aside before retrying: $source_dir"
fi
