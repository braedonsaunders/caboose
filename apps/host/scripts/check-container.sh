#!/usr/bin/env bash
# Run from the repository root against the running Compose service on Linux.
set -euo pipefail
compose=(docker compose -f deploy/compose.yaml)
id=$("${compose[@]}" ps -q caboose-host)
[[ -n $id ]] || { echo 'caboose-host is not running' >&2; exit 1; }
pid=$(docker inspect -f '{{.State.Pid}}' "$id")
[[ $pid != 0 && $(readlink /proc/1/ns/net) != "$(readlink "/proc/$pid/ns/net")" ]] || { echo 'Network namespace is not isolated' >&2; exit 1; }
"${compose[@]}" exec -T caboose-host bash -ec '
  test -r /dev/kvm && test -w /dev/kvm
  CABOOSE_NO_FSTAB=1 setup-disks "$CABOOSE_IMAGE_ROOT" "$CABOOSE_DISK_SIZE"
  node --input-type=module -e '\''import {ensureNetwork} from "./apps/host/dist/network.js"; await ensureNetwork()'\''
  ip link show caboose0 >/dev/null
  iptables -t nat -C POSTROUTING -s 192.0.2.2/32 ! -o caboose0 -j MASQUERADE
  node -e '\''fetch("http://127.0.0.1:7310/v1/health",{headers:{authorization:"Bearer "+process.env.CABOOSE_OWNER_TOKEN}}).then(async r=>{const h=await r.json();if(!r.ok||!h.kvm)process.exit(1);console.log("Authenticated health: KVM available")}).catch(e=>{console.error(e);process.exit(1)})'\''
'
echo 'Container network namespace, TAP, NAT, KVM and reflinks verified.'
