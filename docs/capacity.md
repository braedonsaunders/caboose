# Capacity and usage

`GET /v1/host/capacity` is available to the operator account and owner token.
`GET /v1/tenants/:id/capacity` is available to administrators of that tenant and the
operator. An unauthorized tenant returns 404, an unauthenticated request 401,
and a phone token 403. Authorization precedes quota lookup and storage sampling.
Tenant responses contain only that tenant's totals and no host measurements or
aggregate runtime queue count. Responses use `Cache-Control: no-store`.

The browser-safe contract is `packages/capacity/types.ts`. The host implementation
is `apps/host/src/capacity.ts`; the console uses AppKit dashboard and UI primitives
in `apps/web/src/pages/Capacity.tsx`. AppKit analytics queries are not needed for
these instantaneous, domain-owned measurements.

## Reading values

- `allocated` sums all selected computers' configured memory and vCPUs. Memory is
  converted from settings MiB into bytes. `running` sums active resource settings
  only for computers in the running state. Unknown active resources make that
  total null. These are allocations, not measured resident RAM or CPU usage.
  Frozen and transitioning computers can still hold resources and have separate
  counts. A parked VM can retain resource settings without consuming guest RAM.
- Counts preserve every lifecycle state. The host's queued count comes from the
  AppKit desk queue. Queue membership is not exposed per computer, so tenant
  queue counts are unavailable. Container queue counts are unavailable too.
- Measurements use `{ value: number | null, reason?: string }`. Zero is a measured
  zero; null carries an unavailable reason. Unlimited quotas are null. Quota
  headroom can be negative; it is not reserved host capacity. Disk quota usage
  matches the existing policy: canonical disk and parked snapshot allocated file
  blocks, excluding backups. The dashboard does not change quotas or enforcement.
- Linux available memory uses `/proc/meminfo` `MemAvailable`, converted from KiB.
  OS free memory is separate and excludes reclaimable caches. Available memory
  is unavailable on other OSes. These OS-visible counters do not measure cgroup
  limits, and may describe more than the host service's container.
- CPU busy percentage is the non-idle fraction of the delta between two OS CPU
  counter samples across all reported CPUs. The first sample and invalid/reset
  counters are unavailable. The sample interval is included. Assigned virtual
  CPUs are never represented as this percentage. One-minute load average is a
  scheduler load count, not utilization; Windows does not supply it.
- Image filesystem availability is `statfs.bavail * bsize`, the available blocks
  for the service, not total blocks minus Caboose's file sizes. Other workloads
  on the same filesystem contribute to its use.
- Storage separates file logical sizes from `stat.blocks * 512`. Sparse holes
  count only toward logical size. File block totals can count reflink extents
  multiple times and are never called unique physical usage. Unique physical
  usage is explicitly unavailable. Scans deduplicate hard-linked inodes within
  each category. Disks cover the canonical overlay, snapshots the canonical
  local parked snapshot, and backups the local backup tree including staging.
  Remote cold archives, phone backups, shared template/retained restore sources,
  golden images and other host files are outside these category totals.
  Container volumes are unmeasured, not zero.

Warnings identify quota exhaustion, computer errors, queued starts, low available
memory/disk, memory overcommit and high measured CPU busy time. They recommend
inspection, parking idle computers or reviewing capacity; they perform no actions.

## Sampling and checks

Reads issue no guest commands, acquire no leases and never wake a computer.
Host samples are request-driven and cached for ten seconds; per-computer storage
samples for sixty seconds, including failures. Concurrent reads share cached
promises. Each request's new storage scans share a 4,096-entry, two-second budget
and a maximum depth of 32. Directory enumeration streams; symlinks and unsupported
entries are rejected. A scan failure yields unavailable rather than a partial
number. The time budget is checked between filesystem operations; a stalled
kernel filesystem call cannot be cancelled by this budget.

The console polls every thirty seconds while visible and does not overlap timed
requests. It discards late responses after scope changes and clears old data on
errors. Samples are observations rather than an atomic filesystem snapshot.

Focused checks:

```sh
pnpm --filter caboose-host exec vitest run src/capacity.test.ts src/tenancy.test.ts
pnpm --filter caboose-web exec vitest run src/capacity.test.ts
```

Tests cover authorization before scans, tenant isolation, missing active resources,
quota units, CPU counter semantics, sparse sizes, symlinks, bounded scans, caching,
and HTTP access without wake. No real host or VM is required for these checks.
