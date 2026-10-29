#!/usr/bin/env bash
# Disposable end-to-end test. Source must be a golden image, never an overlay.
set -euo pipefail
[[ $# == 2 && $(id -u) == 0 ]] || { echo 'Usage: sudo check-migration.sh GOLDEN_IMAGE_ROOT TEST_PARENT' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd -P)
source=$(realpath "$1")
parent=$(realpath "$2")
for f in base.raw vmlinux initrd; do [[ -f $source/$f ]] || { echo "Missing golden $f" >&2; exit 1; }; done
stage=$(mktemp -d "$parent/.caboose-migration-check.XXXXXXXX")
image="$stage/image"
marker=${stage##*.}
[[ $marker =~ ^[A-Za-z0-9]+$ ]]
sentinel="/tmp/caboose-appliance-escape-$marker"
[[ ! -e $sentinel ]]
success=0
cleanup() {
  status=$?
  if [[ $success == 1 ]]; then rm -rf -- "${stage:?}"; else echo "Retained failed fixture: $stage (sentinel: $sentinel)" >&2; fi
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$image/overlays" "$stage/cache"
cp --reflink=always --sparse=auto "$source/base.raw" "$image/overlays/owner.raw"
cp --reflink=always "$source/vmlinux" "$image/vmlinux"
cp --reflink=always "$source/initrd" "$image/initrd"
python3 - "$image/overlays/owner.raw" <<'PY'
import os,sys
os.setxattr(sys.argv[1], b'user.caboose-disk-test', b'preserved')
PY
export LIBGUESTFS_BACKEND=direct LIBGUESTFS_CACHEDIR="$stage/cache" TMPDIR="$stage"
printf '#!/bin/sh\nprintf "custom install survived\\n"\n' > "$stage/probe"
printf 'personal data survived\n' > "$stage/data"
cat > "$stage/hostile-hook" <<HOOK
#!/bin/sh
case "\${1:-}" in prereqs) exit 0;; esac
printf escaped > /proc/1/root$sentinel
printf tampered > /home/caboose/migration-data
exit 0
HOOK
cat > "$stage/boot-check.py" <<'PY'
import os,stat,subprocess
p='/usr/local/bin/migration-probe'; h='/home/caboose/migration-data'
assert subprocess.check_output([p])==b'custom install survived\n'
assert stat.S_IMODE(os.stat(p).st_mode)==0o751
assert os.getxattr(p,b'user.caboose-test')==b'preserved'
assert open(h).read()=='personal data survived\n'
s=os.stat(h)
assert (s.st_uid,s.st_gid,stat.S_IMODE(s.st_mode))==(1000,1000,0o640)
assert os.getxattr(h,b'user.caboose-test')==b'preserved'
open('/home/caboose/migration-boot-passed','w').write('boot passed\n')
os.sync()
PY
cat > "$stage/boot-check.service" <<'UNIT'
[Unit]
Description=Disposable migration fixture check
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /etc/migration-fixture-check.py
ExecStartPost=/usr/bin/systemctl --no-block poweroff
[Install]
WantedBy=multi-user.target
UNIT
guestfish --rw --format=raw -a "$image/overlays/owner.raw" \
  set-network false : run : mount /dev/sda3 / : mkdir-p /usr/local/bin : \
  upload "$stage/probe" /usr/local/bin/migration-probe : chmod 0751 /usr/local/bin/migration-probe : \
  mkdir-p /home/caboose : upload "$stage/data" /home/caboose/migration-data : \
  chown 1000 1000 /home/caboose/migration-data : chmod 0640 /home/caboose/migration-data : \
  setxattr user.caboose-test preserved 9 /home/caboose/migration-data : \
  setxattr user.caboose-test preserved 9 /usr/local/bin/migration-probe : \
  mkdir-p /etc/initramfs-tools/hooks : upload "$stage/hostile-hook" /etc/initramfs-tools/hooks/caboose-hostile-test : \
  chmod 0755 /etc/initramfs-tools/hooks/caboose-hostile-test : \
  upload "$stage/boot-check.py" /etc/migration-fixture-check.py : \
  upload "$stage/boot-check.service" /etc/systemd/system/migration-fixture-check.service : \
  mkdir-p /etc/systemd/system/multi-user.target.wants : \
  ln-s ../migration-fixture-check.service /etc/systemd/system/multi-user.target.wants/migration-fixture-check.service : sync : shutdown
mkfs=${CABOOSE_TEST_MKFS:-/usr/bin/mkfs.erofs}
fsck=${CABOOSE_TEST_FSCK:-/usr/bin/fsck.erofs}
vmm=${CABOOSE_VMM_PATH:-/usr/local/bin/cloud-hypervisor}
cli=(python3 "$here/migrate-disk.py" --image-root "$image" --computer owner --vmm "$vmm" --mkfs "$mkfs" --fsck "$fsck")
"${cli[@]}" inspect
"${cli[@]}" migrate
[[ ! -e $sentinel ]]
python3 - "$image/overlays/owner.raw" <<'PY'
import os,sys
assert os.getxattr(sys.argv[1], b'user.caboose-disk-test') == b'preserved'
PY
image_dir=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["directory"])' "$image/overlays/owner.system-image.json")
timeout --kill-after=10 180 "$vmm" --kernel "$image_dir/vmlinux" --initramfs "$image_dir/initrd" \
  --cmdline 'root=/dev/vda3 rw console=ttyS0' --disk "path=$image/overlays/owner.raw,image_type=raw" \
  --disk "path=$image_dir/system.erofs,readonly=on,image_type=raw" --cpus boot=2 --memory size=1G \
  --serial "file=$stage/console.log" --console off >"$stage/vmm.log" 2>&1
boot=$(guestfish --ro --format=raw -a "$image/overlays/owner.raw" set-network false : run : mount /dev/sda3 / : cat /home/caboose/migration-boot-passed : shutdown)
[[ $boot == 'boot passed' ]]
if "${cli[@]}" rollback; then echo 'Rollback succeeded without acknowledgement' >&2; exit 1; fi
"${cli[@]}" rollback --discard-migrated-writes
home=$(guestfish --ro --format=raw -a "$image/overlays/owner.raw" set-network false : run : mount /dev/sda3 / : cat /home/caboose/migration-data : shutdown)
[[ $home == 'personal data survived' ]]
retired=$(guestfish --ro --format=raw -a "$image/overlays/.owner.migration-retired.raw" set-network false : run : mount /dev/sda3 / : cat /home/caboose/migration-boot-passed : shutdown)
[[ $retired == 'boot passed' ]]
"${cli[@]}" migrate
[[ -e $image/overlays/owner.system-image.json && ! -e $sentinel ]]
recovery="$stage/recovery"
mkdir -p "$recovery/overlays"
cp --reflink=always --sparse=auto "$image/overlays/.owner.migration-original.raw" "$recovery/overlays/owner.raw"
cp --reflink=always --sparse=auto "$image/overlays/owner.raw" "$recovery/overlays/.owner.migration-staged.raw"
set +e
PYTHONPATH="$here/../src" python3 - "$recovery" <<'PY'
import os,sys
from migration_transaction import Transaction
def crash(phase):
    if phase == 'publish-binding': os._exit(73)
Transaction(sys.argv[1], 'owner').publish(b'{"version":1}', crash)
PY
crash_status=$?
set -e
[[ $crash_status == 73 && -e $recovery/overlays/owner.migration.json ]]
python3 "$here/migrate-disk.py" --image-root "$recovery" --computer owner --vmm "$vmm" recover
[[ ! -e $recovery/overlays/owner.migration.json && ! -e $recovery/overlays/owner.system-image.json ]]
home=$(guestfish --ro --format=raw -a "$recovery/overlays/owner.raw" set-network false : run : mount /dev/sda3 / : cat /home/caboose/migration-data : shutdown)
[[ $home == 'personal data survived' ]]
echo 'Disposable appliance migration, hook containment, boot, rollback, repeat and crash recovery passed'
success=1
