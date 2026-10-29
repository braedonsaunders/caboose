# caboose-disk

The host's disk helper for microVM computers on Linux: it shares identical blocks between
computer disks (shared storage), describes a disk image for phone backups, and deallocates
ranges of zeros. The host runs it; see Shared storage and Phone backups in
[`docs/architecture.md`](../../../docs/architecture.md).

It changes how a file is stored, never what it reads as. Blocks are shared only through
`FIDEDUPERANGE`, which compares the bytes under the kernel's locks first, and `punch`
deallocates only ranges it has read as zeros.

## Commands

```sh
caboose-disk dedupe-serve --state <dir>
caboose-disk manifest --image <path> [--base <path> --cache <dir>] [--chunk-bytes <n>]
caboose-disk base-hash --base <path> --cache <dir> [--chunk-bytes <n>]
caboose-disk punch <path>     # `offset length` lines on stdin; each range must read as zeros
caboose-disk discard <path>   # the same, whatever the ranges hold (a restore's staging disk)
```

`dedupe-serve` keeps the index in memory and its records in `<dir>`, one file per disk with a
checksum. It reads JSON lines on stdin and answers each with one line on stdout:

| Request | Reply |
| --- | --- |
| `{ "op": "run", "id", "key", "files": [disk, ...clones], "sources": [{ "key", "path", "immutable"? }], "live"?: [key] }` | `{ "id", "ok": true, "report": { hashedBytes, sharedBytes, punchedBytes, skippedSources } }`, or `{ "id", "ok": false, "error": "busy" \| "missing" \| "cancelled" \| "unsupported" \| "io" \| "invalid", "message"?, "report"? }` |
| `{ "op": "cancel", "id" }` | The run with that id stops between kernel calls and answers `cancelled`. |
| `{ "op": "forget", "id", "key" }` | `{ "id", "ok": true }`: the key's record is dropped. |

Keys are `computer:<id>` or `base:<name>`. A run opens the disk read-write under an exclusive
open file description lock (`busy` if a VMM, a migration or anything else holds one), its
clones read-write without a lock, and each source read-only under a shared lock; a source that
cannot be locked is skipped. An immutable source (a base image) is indexed on first use; a
computer's disk is indexed when it is itself a run's disk. `live`, when sent, forgets every
other key. Closing stdin lets queued requests finish, then exits.

`manifest` prints `{ "version": 1, "diskBytes", "chunkBytes", "baseSha256", "chunks" }` where
each element of `chunks` is a data chunk's SHA-256 or a run, `{ "zero": n }` or `{ "base": n }`.
A chunk mapped to the base's own blocks counts as base without being read. Chunk maps of base
images are cached in `--cache` by device, inode, size and modification time.

## Build and test

```sh
cargo test                 # the passes against an in-memory volume, records and manifests
cargo clippy --all-targets -- -D warnings
cargo build --release
sudo scripts/check-reflink.sh target/release/caboose-disk xfs   # Linux, root: a real loop-mounted XFS (or btrfs)
```

The unit tests run anywhere; the kernel calls are Linux-only, and on other systems the commands
exit with an error. `scripts/check-reflink.sh` makes a 2 GiB XFS or Btrfs image, writes two
disks cloned from a base with the same data at different offsets, and checks that a pass frees
the space without changing a byte, that zeros are deallocated, that the index survives a
restart of the helper, that a disk another process has locked is refused, that a manifest names
only what differs from the base, and that `punch` refuses data. CI runs it on XFS.

The host image builds it in a Rust stage (`apps/host/Dockerfile`); Linux bundles build a static
musl binary (`apps/host/scripts/bundle.sh`) and point `CABOOSE_DISK_HELPER` at it.
