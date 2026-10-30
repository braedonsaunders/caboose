# Portable computer archive storage

This component stores cold-boot Linux microVM computer archives through AppKit
Storage 3.1's streaming S3 interface, including MinIO. It does not mount an object
as a live writable disk, resume memory, or establish automatic HA. Existing local
storage, phone backups and the memory-only snapshot cold tier are unchanged.

## API and controller contract

`PortableComputerStore` accepts the existing `SnapshotObjectStore` interface
(implemented by AppKit Storage) and an operator-owned 32-byte encryption key.
`capture(authority, journalPath, signal?)` returns a `PortableCheckpointRef`.
The trusted authority implements `withCapture(work)` and calls work with
`{directory, metadata}` only while holding exclusive controller authority over a
coherent immutable disk and corresponding metadata. The hold lasts until work
settles. Never use a raw active disk or a caller-provided stopped boolean. The
host's parked Files clone is a coherent source under lifecycle exclusion; container
pause is insufficient. This component itself has no public directory-upload route.

Metadata includes computerId, runtime (`linux-microvm`), architecture (`x64` or
`arm64`), exact runtimeVersion, imageFormat (`monolithic` or `split`), and createdAt.
The flat private source directory contains:

- `disk.raw`: the entire independent writable disk, including zero regions.
- `vmlinux`, `initrd`: exact boot assets used by this computer.
- `system.erofs`: required only for split images.
- `keyring-secret`: the existing 64-hex-character managed keyring password.
- `computer.json`: `{version:1, record:{id,slot,...}, settings:{...}}`. Record
  contains the registry assignment (tenant/person IDs and creation time); settings
  contains the effective computer configuration including resources.
- Existing per-computer `caboose.json`, `agent-profiles.json`, `mcp-library.json`,
  `agent-tool-receipts.json`, `agent-routines.json`, `push-devices.json`, and
  `activities.json` are included when present. The controller must copy each
  existing file under the same state-write exclusion as its record/settings.

- Up to 50 finished command receipts, `command-<32-lowercase-hex-id>.json`,
  retain command IDs, results, output and status. The host stages these from its
  private `commands/` directory while holding command quiescence. Active commands,
  invalid records, mismatched IDs, oversized receipts and unsupported directory
  entries refuse capture. Receipt JSON is bounded to 16 MiB including escaping;
  fields retain the Run Command request/result limits. Restore validates each receipt
  again and installs it into `commands/<id>.json` before activation. Restored finished
  commands are never relaunched. Existing archives without receipts remain readable.

No other files, directories or symlinks are accepted. A split-image adapter must
resolve its saved system-image binding rather than the current default image.
Template layouts must supply the complete independent disk after initialization.
The source adapter determines runtime availability; library format support alone
does not establish that a runtime's capture/activation integration exists.

`inspect(ref, compatibility, signal?)` authenticates and validates the manifest,
and rejects differing runtime, architecture or exact runtimeVersion. It does not
read all payloads. `restore(ref, compatibility, destination, signal?)` validates
all payloads and metadata into a new mode-0700 directory, with mode-0600 files and
sparse zero ranges. It refuses an existing destination. Callers use a private
staging path and must await success before activation. It never changes a live
disk, registry, network slot, ownership lease, or running controller. The recovery
coordinator owns fencing, target slot reassignment and journaled activation.

## Durability and integrity

Files use the existing snapshot archive codec: streaming gzip then AES-256-GCM,
random nonces, per-file authenticated identity, ciphertext SHA-256, plaintext
SHA-256 and exact plaintext length. The full disk needs no base image on restore.
The version-1 manifest is itself AES-256-GCM encrypted with its immutable random
object key as authenticated data. A ref includes version, UUID, manifest object
key and SHA-256 key fingerprint. Payloads are uploaded before the manifest; only
a published authenticated manifest is a checkpoint. Publication reads it back.
S3 PUT/multipart completion supplies the object durability boundary; this assumes
an appropriately configured durable object server, not a disposable MinIO disk.

A unique exclusive-created local journal records each intended object key before
PUT, syncing both file and parent directory. Failed uploads retain their receipt.
`discardInterrupted(journalPath)` retries deletion only for `uploading` receipts;
call it only after the owning uploader has stopped, under operation exclusion.
A `publishing` receipt may have committed despite a lost response: inspect its ref
and reconcile it with the coordinator before any deletion. `committed` receipts
remain durable references. Never run cleanup concurrently with capture. Process
crashes can leave orphaned objects; loss of the receipt requires operator bucket
inventory reconciliation. Configure S3 lifecycle abortion of incomplete multipart
uploads. No automatic retained-checkpoint deletion policy is installed.

A failed restore removes its new staging directory. Process termination can leave
a partial private directory; it is never activated or accepted as complete. Start
a retry at a new destination and remove abandoned staging only after its worker
has stopped. Interrupted transfers restart rather than resume byte ranges.

## Key and identity ownership

`openPortableStorage(env, runtime, platform)` is explicitly opt-in with
`CABOOSE_PORTABLE_STORAGE=on`. It requires Linux microVM runtime, an absolute
`CABOOSE_PORTABLE_KEY_FILE` (host-owned private regular file, no symlink, containing
32 bytes as lowercase hex), and `CABOOSE_PORTABLE_ENDPOINT`, `BUCKET`,
`ACCESS_KEY_ID`, `SECRET_ACCESS_KEY` (each prefixed `CABOOSE_PORTABLE_`). Optional
`CABOOSE_PORTABLE_REGION` defaults to `us-east-1`. HTTPS is recommended beyond an
isolated loopback acceptance server. The result supplies `archives` and `close()`;
close destroys its AppKit S3 client. Missing/invalid enabled configuration fails.

The operator provisions and separately backs up the encryption key on approved
recovery hosts. There is no generated fallback or implicit key rotation; losing
the key loses the archives. Credentials never enter manifests. Disk contents,
keyring password, profile configuration and tool receipts are all encrypted.
The host identity database, auth-secret, owner-token, phone-token database,
Tailscale identity, cloud credentials, and cluster leases are not copied.
Those belong to the deployment's identity/ownership recovery policy. Portable
archives do not independently preserve phone authentication or tenant accounts.

## Audit of existing storage

Legacy VM disks are `overlays/<id>.raw`; template disks are
`overlays/<id>.template/disk.raw` (`vm-paths.ts`). Split-image bindings and resource
records sit alongside overlays. Non-owner computer state lives under
`computers/<id>`; owner state uses the image root (`computers.ts`, `index.ts`).
The existing snapshot tier archives only parked memory, leaving disk local.
Phone backups capture a coherent parked Files clone, describe base-relative
chunks and require the original base/boot assets on restore (`backup.ts`).
Container persistent state includes both `/home/caboose` volume/bind and Docker's
writable layer; archiving home alone loses installed software. Container archives
are rejected here; there is no container export/import implementation.

## Run and verify

No separate build is required. From the repository root:

```
pnpm --dir apps/host typecheck
pnpm --dir apps/host exec vitest run src/portable-storage --maxWorkers=1
```

For a dedicated disposable S3/MinIO bucket, set `S3_ENDPOINT`, `S3_BUCKET`,
`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` and run:

```
CABOOSE_PORTABLE_ACCEPTANCE=disposable-bucket pnpm --dir apps/host exec tsx scripts/check-portable-storage.mts
```

The acceptance writes a 12 MiB incompressible disk fixture through actual S3
multipart upload, deletes the source, restores via an independent store instance,
checks architecture rejection and corrupts an object to check restore cleanup.
It removes only its generated object keys and scratch directory. It does not boot
a VM; actual controller capture and fenced boot need separate host acceptance.
