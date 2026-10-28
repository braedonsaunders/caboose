#!/usr/bin/env bash
# Run from the repository root against the running Compose service on Linux.
set -euo pipefail
compose=(docker compose -f deploy/compose.yaml)
id=$("${compose[@]}" ps -q caboose-host)
[[ -n $id ]] || { echo 'caboose-host is not running' >&2; exit 1; }
container_net=$("${compose[@]}" exec -T caboose-host readlink /proc/self/ns/net)
[[ -n $container_net && $(readlink /proc/self/ns/net) != "$container_net" ]] || { echo 'Network namespace is not isolated' >&2; exit 1; }
"${compose[@]}" exec -T caboose-host bash -ec '
  test -r /dev/kvm && test -w /dev/kvm
  CABOOSE_NO_FSTAB=1 setup-disks "$CABOOSE_IMAGE_ROOT" "$CABOOSE_DISK_SIZE"
  node --input-type=module -e '\''import {ensureNetwork} from "./apps/host/dist/network.js"; await ensureNetwork()'\''
  ip link show caboose0 >/dev/null
  iptables -t nat -C POSTROUTING -s 192.0.2.2/32 ! -o caboose0 -j MASQUERADE
  node -e '\''fetch("http://127.0.0.1:7310/v1/health",{headers:{authorization:"Bearer "+process.env.CABOOSE_OWNER_TOKEN}}).then(async r=>{const h=await r.json();if(!r.ok||!h.kvm)process.exit(1);console.log("Authenticated health: KVM available")}).catch(e=>{console.error(e);process.exit(1)})'\''
'
"${compose[@]}" exec -T caboose-host node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
const origin = 'http://127.0.0.1:7310';
const page = await fetch(origin);
assert.equal(page.status, 200, 'Web console must be bundled');
assert.match(page.headers.get('content-type') ?? '', /text\/html/);
const html = await page.text();
const assets = [...html.matchAll(/(?:src|href)="(\/assets\/[^"?#]+)[^"]*"/g)].map(match => match[1]);
assert(assets.some(path => path.endsWith('.js')), 'Console must load a compiled script');
for (const path of assets) {
  const asset = await fetch(new URL(path, origin));
  assert.equal(asset.status, 200, `Missing console asset: ${path}`);
  assert(!asset.headers.get('content-type')?.includes('text/html'), `Asset returned SPA fallback: ${path}`);
  await asset.arrayBuffer();
}
const route = await fetch(`${origin}/settings`);
assert.equal(route.status, 200, 'Console routes need SPA fallback');
assert.equal(await route.text(), html);
const api = await fetch(`${origin}/v1/computer`);
assert.equal(api.status, 401, 'Public console must not bypass API authentication');
await api.text();
console.log('Bundled console, assets, SPA fallback and API authentication verified.');
NODE
echo 'Container network namespace, TAP, NAT, KVM, reflinks and web console verified.'
