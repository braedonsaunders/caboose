# Optional cluster ownership and cold recovery

Ordinary installs use local disks and embedded identity storage. None of this module
initializes unless `CABOOSE_CLUSTER=on`. The same host binary implements both paths.

Cluster mode supports Linux monolithic Cloud Hypervisor microVMs on Azure VMs. It
requires external PostgreSQL (`CABOOSE_DATABASE_URL`), shared `CABOOSE_AUTH_SECRET`,
`CABOOSE_PUBLIC_URL`, `CABOOSE_CLUSTER_HOST_ID` (permanent unique identity),
`CABOOSE_CLUSTER_AZURE_RESOURCE` (full VM resource ID), and the portable storage
configuration in [portable-storage](../portable-storage/README.md). Containers,
macOS, split images, memory templates and VM depots are refused. Phone backups and
local memory object tiering are not enabled in cluster mode. Image/kernel/initrd
and VMM must already be installed; their compatibility is checked before recovery.

Each VM's managed identity needs read/instanceView and deallocate permission on
cluster host VMs. The configured resource is checked against Azure IMDS on startup.
No provider is selected implicitly and no provider-less takeover is available.
Use dedicated cluster VMs: fencing stops the entire source VM, including every
computer it serves. An external stable HTTPS ingress and shared auth origin are
operator infrastructure; this module does not provision Azure or an ingress.

The existing shared computer registry is canonical, including the one `owner`
computer with slot zero; this is not one owner computer per cluster host. Start
against one initialized registry; do not independently import personal installations
into the same database. Phone token hashes are stored transactionally in PostgreSQL;
existing local hashes are imported only when the shared token store is first created.
Tenant/person assignments are read from current shared identity state, never restored
from an archive. Account sessions require the shared auth secret.

## Control and routing

Operator-authenticated POST endpoints (owner token or operator account) are:

- `/v1/computers/:id/cluster/claim`: explicitly enroll and claim an unowned computer
  with no checkpoint. This starts its renewal loop and makes ordinary wake available.
  Creating a registry computer does not implicitly claim it on every host.
- `/v1/computers/:id/cluster/checkpoint`: disconnect clients, drain routine/tool work,
  park, hold lifecycle exclusion, and publish an encrypted disk/keyring/host-state
  archive. Admission excludes only this computer; unrelated requests and location
  discovery remain concurrent. Its active HTTP/WebSocket transports are cancelled,
  and their handlers must settle within five seconds before capture starts. If they
  do not, capture is refused and admission stays closed until they settle. New work
  during maintenance receives 409 (upgrades close). The computer stays parked and
  wakes normally on the next request. Checkpoints are explicit operator operations.
- `/v1/computers/:id/cluster/recover`: require an expired owner, revoke its host,
  deallocate and independently verify Azure `PowerState/deallocated`, claim a new
  generation, verify and restore the archive, then cold boot headlessly. A previously
  failed restore with safely released ownership can be retried without another fence.

A 15-second scan attempts the same recovery for expired compatible computers with
published checkpoints. PostgreSQL uses its clock and row locks for claims and leases;
all generation values are decimal strings to preserve bigint precision. Renewals
cannot revive expired ownership. An expired lease alone never permits takeover.
Any ambiguous provider response leaves the source revoked and recovery unavailable.
A failed restore never activates its partial directory. The last verified checkpoint
remains the recovery source.

`GET /v1/location` returns the authenticated phone's computer, generation, endpoint
and availability. Operators/tenant administrators can use
`GET /v1/computers/:id/location` within their authorization. A stale local computer
API responds 409; a revoked host refuses API service. There are no bearer-token
redirects. Clients/ingress must use the authorized location to reconnect; automatic
phone URL relocation is not implemented here. Existing sockets are revalidated and
closed on lease failure or token/account revocation.

## Fencing and durability

Every host identity has an immutable Azure resource binding. Before a provider fence,
the coordinator permanently revokes the source. No startup or renewal can rejoin that
identity, including a source VM restarted by external automation. The unique resource
binding prevents selecting a new host ID to bypass revocation. A durable
`.cluster-enrolled` marker prevents starting that image root in ordinary local mode.
Re-enrollment of a fenced resource is not automated: provision a replacement cluster
VM with a new resource identity. A host process restart does not adopt old execution
leases: recovery uses another eligible host and provider fencing.

Renewal errors or bounded coordinator timeouts close local sockets and invoke the
AppKit shutdown primitive without booting or deleting disks. An event-loop stall or
failed local shutdown is not proof that execution stopped: only Azure verification
allows another host to run. PostgreSQL and Azure control-plane partitions therefore
sacrifice availability. Operators must not run an alternate unguarded VMM on cluster
disks or erase the enrollment marker.

The archive is a cold, crash-consistent disk checkpoint taken after VM park. RAM,
processes and in-flight external side effects are not recovered. Work since the last
published checkpoint is lost (RPO equals checkpoint age). Agent external actions may
need reconciliation after cold recovery. Host-state writers drain before capture;
the shared identity database remains the authorization authority. Recovery installs
into a private generation directory and never overwrites the previous disk. Partial
restores and upload receipts require operator review; no automatic retention policy
or object deletion is provided.

## Validation

With an installed PostgreSQL16 and existing dependencies:

```sh
python3 apps/host/scripts/check-cluster-postgres.py
```

`CABOOSE_TEST_PG_BIN` selects the installed PostgreSQL bin directory. The script
creates a private Unix-socket-only database, runs one bounded test worker, stops it,
and verifies listener removal. It does not install PostgreSQL or use a live database.
Set `CABOOSE_TEST_MINIO_BINARY` to an existing MinIO binary to include a private
loopback S3 server and the actual capture/restore/activation test. Both children are
stopped on completion. The test uses synthetic disk bytes and a synthetic lifecycle
and provider receipt: it is not evidence of a real VM boot or Azure fencing.

The PostgreSQL test races two independent Node processes against one computer and
checks lease expiry, permanent revocation, stale generations, provider failures,
compatibility and receipt binding. The combined S3 test deletes the source, restores
the encrypted disk/keyring/settings, checks shared phone identity/revocation, corrupts
an object and verifies that the failed restore cannot activate.

For actual two-host validation, use only disposable dedicated Azure VMs and a
separate database/bucket. Configure both hosts as above; create/claim a disposable
computer on A, write a marker in its disk, and POST checkpoint. Use the acceptance
script below with operator tokens in private files. It exercises a deliberately
stopped host and recovery, which deallocates A. No such cloud action is part of the
local automated gate.

```sh
python3 apps/host/scripts/check-cluster-two-host.py --disposable-azure-hosts \
  --source-url https://a.example.invalid --target-url https://b.example.invalid \
  --source-token-file /private/a-token --target-token-file /private/b-token \
  --source-ssh disposable-a --computer owner --marker-path acceptance-marker.txt
```

The script stops `caboose-host` on A over its configured SSH alias and checks the
marker through B after the generation advances. Service unit names must match the
installation. Inspect the stored resource/generation-bound fence receipt and Azure
state as part of the test record. This script is supplied but has not been run
against Azure or a real microVM in the local validation environment.

### Command receipts at checkpoint

The runtime checks active operations before checkpoint shutdown. Running or starting
commands refuse checkpoint without pausing their completion polling. After request
admission drains, `ComputerCommands.quiesceForCheckpoint(timeoutMs = 5000)` freezes
new command work and awaits the current poll/collection and `CommandStore.drain()`.
It returns an idempotent release function, held until shutdown/capture finishes and
called in `finally`. On timeout, capture fails and the command subsystem stays frozen
until the actual drain settles. This API does not replace per-computer request
admission or lifecycle exclusion.

`CommandStore.persistenceStatus` exposes pending write count and the retained error.
A failed write or delete remains visible to drain even if a caller logged its error;
a subsequent successful write/delete of that receipt clears its fault. Directory
entries are synced with command writes/deletes. An unreadable local record also
blocks checkpoint rather than being omitted from durable recovery.

Capture stages completed command receipts as validated flat archive files. Recovery
reinstalls the original IDs/results under `commands/`, syncs that directory, the
modified disk `overlays/` directory and the staging directory, then publishes the
new generation. Receipt persistence or validation failure refuses capture/activation.
The disk still holds command output files; RAM and active command execution are not
preserved by cold recovery.
