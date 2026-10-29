#!/usr/bin/env bash
# caboose-disk against a real reflink filesystem (a loop-mounted XFS or Btrfs image):
#
#  - Sharing frees the space of data two disks hold at different offsets, and of a disk's
#    blocks that equal its base, without changing a byte of either disk.
#  - Long runs of zeros are deallocated.
#  - A disk another process holds an image lock on (as Cloud Hypervisor and QEMU do) is refused.
#  - A manifest names only the chunks that differ from the base; `punch` refuses data.
#
#   sudo apps/host/disk/scripts/check-reflink.sh <caboose-disk> [xfs|btrfs]
#
# Needs root (mount), mkfs.xfs or mkfs.btrfs, python3 and coreutils.
set -euo pipefail

helper=$(realpath "${1:?usage: check-reflink.sh <caboose-disk> [xfs|btrfs]}")
fs=${2:-xfs}
work=$(mktemp -d)
mnt=$work/mnt
mkdir "$mnt"
locker=
cleanup() {
  [[ -z $locker ]] || kill "$locker" 2>/dev/null || true
  umount "$mnt" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
MiB=$((1024 * 1024))

truncate -s 2G "$work/fs.img"
case $fs in
  xfs) mkfs.xfs -q -m reflink=1 "$work/fs.img" ;;
  btrfs) mkfs.btrfs -q "$work/fs.img" ;;
  *) fail "unknown filesystem $fs" ;;
esac
mount -o loop "$work/fs.img" "$mnt"

# A 64 MiB base; two computers cloned from it. Both write the same 32 MiB of new data, at
# offsets 4 KiB apart in alignment; b also writes a block equal to one of the base's (at a
# different offset), its own 8 MiB, and 4 MiB of allocated zeros.
head -c $((64 * MiB)) /dev/urandom >"$mnt/base.raw"
cp --reflink=always "$mnt/base.raw" "$mnt/a.raw"
cp --reflink=always "$mnt/base.raw" "$mnt/b.raw"
truncate -s $((256 * MiB)) "$mnt/a.raw" "$mnt/b.raw"
head -c $((32 * MiB)) /dev/urandom >"$work/shared.bin"
dd if="$work/shared.bin" of="$mnt/a.raw" bs=4096 seek=$((64 * 256)) conv=notrunc status=none
dd if="$work/shared.bin" of="$mnt/b.raw" bs=4096 seek=$((100 * 256 + 3)) conv=notrunc status=none
dd if="$mnt/base.raw" of="$mnt/b.raw" bs=4096 skip=$((8 * 256)) count=$((8 * 256)) seek=$((150 * 256)) conv=notrunc status=none
head -c $((8 * MiB)) /dev/urandom | dd of="$mnt/b.raw" bs=4096 seek=$((170 * 256)) conv=notrunc status=none
dd if=/dev/zero of="$mnt/b.raw" bs=4096 count=$((4 * 256)) seek=$((200 * 256)) conv=notrunc status=none
sync
sum_a=$(sha256sum <"$mnt/a.raw")
sum_b=$(sha256sum <"$mnt/b.raw")
used() { sync; df --output=used -B1 "$mnt" | tail -1 | tr -d ' '; }
before=$(used)

base_source="{\"key\":\"base:test\",\"path\":\"$mnt/base.raw\",\"immutable\":true}"
{
  echo "{\"op\":\"run\",\"id\":1,\"key\":\"computer:a\",\"files\":[\"$mnt/a.raw\"],\"sources\":[$base_source]}"
  echo "{\"op\":\"run\",\"id\":2,\"key\":\"computer:b\",\"files\":[\"$mnt/b.raw\"],\"sources\":[$base_source,{\"key\":\"computer:a\",\"path\":\"$mnt/a.raw\"}]}"
} | "$helper" dedupe-serve --state "$work/state" >"$work/replies.jsonl"
python3 - "$work/replies.jsonl" "$MiB" <<'EOF' || fail "unexpected dedupe replies: $(cat "$work/replies.jsonl")"
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1])]
mib = int(sys.argv[2])
assert lines[0] == {"ready": True, "indexed": 0}, lines[0]
a, b = lines[1], lines[2]
assert a["ok"] and a["report"]["sharedBytes"] == 0, a
assert b["ok"], b
# The 32 MiB shared with a, and the 8 MiB equal to the base (minus at most one run at each edge).
assert b["report"]["sharedBytes"] >= 39 * mib, b
assert b["report"]["punchedBytes"] >= 4 * mib, b
EOF
after=$(used)
freed=$(( (before - after) / MiB ))
(( freed >= 40 )) || fail "sharing freed only ${freed} MiB"
[[ $(sha256sum <"$mnt/a.raw") == "$sum_a" && $(sha256sum <"$mnt/b.raw") == "$sum_b" ]] || fail 'a disk changed'
echo "OK: sharing freed ${freed} MiB on $fs without changing either disk"

# A second pass over an unchanged disk reads only what it owns, and still changes nothing.
echo "{\"op\":\"run\",\"id\":3,\"key\":\"computer:b\",\"files\":[\"$mnt/b.raw\"],\"sources\":[$base_source,{\"key\":\"computer:a\",\"path\":\"$mnt/a.raw\"}]}" \
  | "$helper" dedupe-serve --state "$work/state" | tail -1 >"$work/again.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["ok"] and r["report"]["sharedBytes"] == 0, r' "$work/again.json" || fail "second pass: $(cat "$work/again.json")"
echo 'OK: the index survives a restart of the helper'

# An image lock held elsewhere (an open file description lock, as VMMs take) refuses the disk.
python3 - "$mnt/b.raw" <<'EOF' &
import fcntl, os, struct, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.fcntl(fd, fcntl.F_OFD_SETLK, struct.pack('hhqqi', fcntl.F_WRLCK, 0, 0, 0, 0))
print('locked', flush=True)
time.sleep(60)
EOF
locker=$!
sleep 1
echo "{\"op\":\"run\",\"id\":4,\"key\":\"computer:b\",\"files\":[\"$mnt/b.raw\"],\"sources\":[]}" \
  | "$helper" dedupe-serve --state "$work/state" | tail -1 >"$work/busy.json"
grep -q '"error":"busy"' "$work/busy.json" || fail "a locked disk was not refused: $(cat "$work/busy.json")"
kill "$locker"; locker=
echo 'OK: a disk locked by another process is refused'

# The manifest: base chunks, then a's 32 data chunks, then zeros.
"$helper" manifest --image "$mnt/a.raw" --base "$mnt/base.raw" --cache "$work/cache" >"$work/manifest.json"
python3 - "$work/manifest.json" "$mnt/base.raw" <<'EOF' || fail "unexpected manifest: $(head -c 400 "$work/manifest.json")"
import hashlib, json, sys
m = json.load(open(sys.argv[1]))
assert m["diskBytes"] == 256 << 20 and m["chunkBytes"] == 1 << 20
assert m["baseSha256"] == hashlib.sha256(open(sys.argv[2], 'rb').read()).hexdigest()
c = m["chunks"]
assert c[0] == {"base": 64}, c[0]
assert all(isinstance(x, str) for x in c[1:33]) and len(set(c[1:33])) == 32
assert c[33:] == [{"zero": 256 - 96}], c[33:]
EOF
echo 'OK: the manifest names only the chunks that differ from the base'

if echo "0 4096" | "$helper" punch "$mnt/a.raw" 2>/dev/null; then fail 'punch deallocated data'; fi
echo "$((200 * MiB)) $((4 * MiB))" | "$helper" punch "$mnt/b.raw"
[[ $(sha256sum <"$mnt/b.raw") == "$sum_b" ]] || fail 'punching zeros changed the disk'
echo 'OK: punch refuses data and deallocates zeros'
