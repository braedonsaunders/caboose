# Offline whole-host recovery

`offline-recovery.py` captures protected directories, verifies their SHA-256 manifest,
and restores verified files into a **new staging directory**. It requires Python 3 and
GNU `cp` on Linux. It neither starts nor stops services, mounts guest filesystems,
extracts archives, nor installs a restored server over an existing one. Run as the host
operator with private, trusted source and destination directories. The bundle contains
secrets and tenant data in plaintext; use encrypted independent storage and operator-only
access. Do not serve it from the console or give it to tenants. Hashes detect corruption,
not malicious replacement of both data and manifest.

## Capture

1. Record the host version, runtime, CPU architecture, service/container configuration,
   numeric host UID/GID, image paths and external dependencies in the protected config
   directory. Include environment files, TLS material, auth/owner/keyring secrets,
   snapshot encryption keys and storage credentials. Preserve file contents privately;
   do not paste them into commands or logs. External secret-manager values require their
   own protected recovery mechanism. The tool cannot discover omitted external secrets.
2. Stop admission and stop the host and **all** its VMs/containers, including retained
   VMMs and template sources. Verify with the service manager and runtime. Do not copy
   running disks. The tool acquires the Linux host's `.host.lock` exclusively and refuses
   a running host/VMM that holds it; the explicit acknowledgement also covers services
   outside that lock. Keep all services stopped for the entire copy and verification.
3. Include the complete image root and state root. Embedded identity data lives in the
   image root: preserve the complete database directory, not selected database files.
   Include every external split-image directory as another `--root label=/absolute/path`.
   The tool checks saved `.system-image.json` bindings against supplied roots. Also include
   external template sources and any other retained runtime dependencies. Retain the
   original absolute layout: persisted bindings and memory snapshots can name absolute
   paths. No path rewriting is performed.
4. For external PostgreSQL, keep Caboose stopped and take a database dump into the private
   config root using PostgreSQL's `pg_dump --format=custom --file=identity.dump` with a
   protected service definition/`.pgpass`, not a password in argv. Use a PostgreSQL client
   compatible with the server. Preserve roles and grants separately using the database
   operator's protected procedure. Run `pg_restore --list identity.dump` and perform the
   isolated restore drill below. A file copy of the image root does **not** back up an
   external database. The script does not connect to production PostgreSQL.
5. Run, substituting actual private paths and a deliberate logical-byte ceiling:

   ```sh
   python3 apps/host/scripts/offline-recovery.py capture /backup/server-2026-10-29 \
     --root images=/srv/caboose/images --root state=/srv/caboose/state \
     --root config=/srv/caboose/protected-config --confirm-stopped \
     --max-bytes 1099511627776
   python3 apps/host/scripts/offline-recovery.py verify /backup/server-2026-10-29 \
     --max-bytes 1099511627776
   ```

   The destination must not exist. Files are copied sparsely without reflinks, checked
   against the stopped source, and kept private. A failure leaves an incomplete directory
   for operator inspection; it is not a valid backup until verification succeeds. The
   byte ceiling bounds logical bytes, not physical free space. Ensure independent storage
   has sufficient capacity before starting. Symlinks and special files are refused; stop
   services and resolve their presence rather than bypassing the check.

Cold-tier remote objects need independent retention/versioning and a restore drill with
matching keys and configuration. Copying a local pointer cannot protect the remote object.
For containers, separately preserve Docker home volumes and the pinned container image
using the runtime's stopped-volume backup procedure; this tool does not export Docker.

## Restore and drill

1. Verify the bundle on independent storage. Keep the original host fenced. Use an
   isolated destination host of the same architecture and compatible runtime/version;
   never run two servers with restored identity/tokens against the same production data.
2. Restore to an absent staging directory:

   ```sh
   python3 apps/host/scripts/offline-recovery.py restore /backup/server-2026-10-29 \
     --destination /srv/caboose-recovery-stage --confirm-restore \
     --max-bytes 1099511627776
   ```

   Every listed file is hash-verified before and after copying. The tool refuses an
   existing destination, traversal, symlinks and a bundle above the explicit byte limit.
3. With services stopped, install the staged `images`, `state`, `config` and dependency
   directories at their recorded original paths on the replacement host. Set ownership
   to the recorded host UID/GID, retain private secret permissions and restore any
   required executable permissions from the trusted deployment. Retain the previous
   stopped installation separately; do not overwrite it during the drill.
4. For external PostgreSQL, create an isolated empty database and restore with
   `pg_restore --exit-on-error --single-transaction --dbname=RECOVERY_DATABASE identity.dump`
   using protected connection configuration. Restore required roles/grants deliberately;
   do not use a production target or `--clean` against a live database. Point the isolated
   host at that database. For embedded identity, use the complete restored directory.
5. Start the isolated host. Check operator login, tenant membership and computer ownership,
   pairing revocation, image bindings, keyring preparation, and a disposable computer's
   wake/park/restart. Verify representative files against known fixture hashes. Exercise
   cold-tier retrieval if configured. Keep outbound production integrations fenced during
   the drill. Record the bundle identity, verification result, software versions and drill
   results privately. Only after a successful drill does the operator arrange a deliberate
   cutover, keeping the original server fenced.

## Checks

`python3 apps/host/scripts/tests/test-offline-recovery.py` tests corruption, byte limits,
traversal, duplicate records, symlinks and live-lock refusal. On Linux it also executes a
real small directory capture/restore round trip using GNU sparse copy. This is not a VM,
external PostgreSQL, cold-tier or device-backup acceptance test.
