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

Capacity reads issue no guest commands, acquire no leases and never wake a computer.
Host-wide samples are request-driven and cached for ten seconds; per-computer storage
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

## Per-computer measurements

The existing Usage dashboard includes each authorized computer's measured resources.
Computer overview includes the same measurements and a **Measure storage** action.
`GET /v1/computers/:id/usage` reads cached measurements. The operator can read any
computer; a tenant administrator can read only computers currently assigned to their
tenants. Missing and unauthorized computers return 404; phone tokens return 403.
`POST /v1/computers/:id/usage/storage` uses the same authorization and explicitly
requests storage measurement. Both responses are `no-store` and neither wakes a guest.

Container telemetry uses the local Docker Engine socket selected by `DOCKER_CONTEXT`, then `DOCKER_HOST`,
then the current Docker context (the same precedence as the runtime CLI). Remote TCP/SSH Docker endpoints are unsupported.
Each sample reads container inspection metadata and one-shot Engine stats; no guest
process runs. Memory is the cgroup's current charge, including kernel and file-cache
charges. Inactive file cache is reported separately as potentially reclaimable, not
subtracted to invent resident/private RAM. The runtime memory limit and configured
next-boot limit are separate. AppKit desk 0.11 does not expose per-VM resource counters;
VM RAM and CPU measurements are unavailable. VM storage remains available.

CPU seconds come from Engine cumulative CPU nanoseconds. CPU activity divides an
adjacent sample's CPU-second delta by elapsed seconds and the runtime vCPU limit;
100% means all allocated vCPUs are busy. Short quota bursts can exceed 100%. A first
sample, failed probe, changed container/start identity or CPU limit, decreasing
counter, backward clock, or gap exceeding 150 seconds establishes a new baseline.
No CPU time is inferred across that boundary. Frozen containers are measured without
unfreezing; unavailable counters for stopped containers are gaps, not invented zeros.

The host samples once per minute, sequentially with no overlap. Each Engine request
has a four-second absolute deadline and a 2 MiB response cap. Context discovery has
four seconds. A sweep starts no more probes after 45 seconds (the final probe can
add up to 12 seconds), rotates its starting position for fairness, and records missing
samples for the rest. Typical per-computer overhead is two local HTTP requests per
minute and zero guest commands. Runtime cost has not been benchmarked on a live host.

`usage-history.json` under the image root persists hourly CPU-second and coverage
aggregates using a mode-0600 temporary file and atomic rename once per sweep. At most
256 computers and 721 hourly buckets per computer are retained. Over-limit computers
report unavailable; deleted computers are pruned. A restart retains aggregates but
never bridges the old CPU baseline. Missing/corrupt history begins new coverage.
The rolling window excludes buckets starting before 30 days ago, conservatively
losing at most the boundary hour; intervals crossing hours are proportionally split.
Collecting-since and measured coverage accompany the total: the result is measured
CPU time within the last 30 days, not a claim of complete monthly usage. Memory and
CPU activity become unavailable after 150 seconds without a sample. Persistence
failures are logged; in-memory measurements remain available until restart.

Container storage is cached for fifteen minutes, including failures, and only one
storage refresh runs at a time. Docker inspection with `size=true` supplies writable
layer and shared-image **logical** sizes; these are not allocated physical costs and
exclude mounted volumes. The dedicated `/home/caboose` home is measured only when
its directory is locally accessible. A named volume must match the configured home
name, mount type `volume`, and exact destination `/home/caboose`. An absolute
`CABOOSE_CONTAINER_HOME` path (with the computer ID suffix for other computers)
must exactly match an inspected mount's source, type `bind`, and destination
`/home/caboose`. Root, relative paths, traversal components and noncanonical slash
spellings are rejected; no other inspected mount is selected as a fallback. A separate Python 3 worker
counts logical file sizes and allocated file blocks with inode deduplication, opens each directory with `O_DIRECTORY | O_NOFOLLOW` and uses retained directory
descriptors for child lookups, without following symlinks. Changed directory identities,
mount boundaries and unsupported entries reject the scan. Python 3 and descriptor-relative
filesystem support are required; unavailable support yields unavailable storage. It has a 100,000-entry/depth-32
budget and is killed after two seconds, including during slow filesystem operations.
An incomplete scan yields unavailable, never a partial total. File blocks can include
shared reflink extents; unique physical cost remains unavailable. Other mounts and
shared depot storage are excluded. The Docker size request times out after four
seconds, but cancellation cannot guarantee Docker stops its internal size calculation.
No recursive container scan runs on a timer or ordinary dashboard refresh.

Focused additional checks:

```sh
pnpm --filter caboose-host exec vitest run src/computer-usage.test.ts src/capacity.test.ts src/tenancy.test.ts --maxWorkers=1
pnpm --filter caboose-web exec vitest run src/computer-usage.test.tsx src/capacity.test.ts --maxWorkers=1
```
