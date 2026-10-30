# Linux real-backend lifecycle reference

This fixture builds the pinned upstream desktop backend and the Caboose adapter
against the real Linux Vulkan loader. It initializes the offscreen framebuffer,
registers two process identities, checks duplicate registration, passes the real
client flags and EOF over a socket pair, then stops and finishes both processes.
It sends no Vulkan command and does not prove guest interoperability, compute,
readback, coherent memory, security against hostile streams, or phone operation.

Use a disposable private directory and the source archive for gfxstream commit
`f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be`; its compressed SHA-256 is
`93f2481ccf3af97a3bf501d6d8f407c064f401a4807e12510372bab5c03828c4`.
From the repository root, with `WORK` set to that private directory and
`ARCHIVE` to the verified archive:

```sh
mkdir -p "$WORK"
echo "93f2481ccf3af97a3bf501d6d8f407c064f401a4807e12510372bab5c03828c4  $ARCHIVE" | sha256sum -c -
tar -xzf "$ARCHIVE" -C "$WORK"
mv "$WORK/gfxstream-f0ce013371a68e85b5a1a1b0cf14ac9ad729f4be" "$WORK/upstream"
cp -R apps/ios/GPUStream/gfxstream "$WORK/gfxstream"
git -C "$WORK/upstream" apply --check --unidiff-zero "$WORK/gfxstream/0001-inject-vulkan-loader.patch"
git -C "$WORK/upstream" apply --unidiff-zero "$WORK/gfxstream/0001-inject-vulkan-loader.patch"
docker build -t caboose-decoder-reference "$WORK/gfxstream/linux-reference"
docker run --rm --network none --cpus 2 --memory 3g -v "$WORK:/work" caboose-decoder-reference \
  cmake -S /work/gfxstream/linux-reference -B /work/build -G Ninja \
  -DCABOOSE_GFXSTREAM_SOURCE=/work/upstream -DCMAKE_BUILD_TYPE=Release -DDEPENDENCY_RESOLUTION=SYSTEM
docker run --rm --network none --cpus 2 --memory 3g -v "$WORK:/work" caboose-decoder-reference \
  timeout 600 cmake --build /work/build --target caboose_gfxstream_lifecycle --parallel 2
docker run --rm --network none --cpus 2 --memory 3g -v "$WORK:/work" caboose-decoder-reference \
  timeout 30 /work/build/caboose_gfxstream_lifecycle /usr/lib/x86_64-linux-gnu/libvulkan.so.1
```

## Private phone diagnostic broker

`phone_broker.py` bridges one authenticated phone TLS connection and one local
same-UID Unix connection without interpreting or manufacturing Vulkan results.
It is a finite diagnostic, not a production relay. The phone pins the DER leaf
certificate SHA-256. TLS 1.3 is required; the 64-byte authentication record is
`CBGTLS01`, a nonzero 16-byte session ID, big-endian uint64 generation and a random
32-byte token. The broker compares the complete record in constant time and
returns zero only on acceptance. The raw `CBGLREF1` stream follows unchanged.

The command requires an explicit private/VPN bind address, private certificate
key and token files, and an owned mode-0700 socket directory. It creates the
mode-0600 Unix socket only after authentication, refuses existing socket paths,
accepts one same-UID local process, and removes its socket on exit. Total duration
is at most 90 seconds; cumulative transferred bytes are capped at 128 MiB, with
at most 64 KiB queued in either direction. Each direction drains independently: guest input EOF
sends TLS close-notify while decoder replies continue to flow back, and phone
output EOF half-closes the guest read side after queued replies drain. It
does not implement production stream resumption or multiple guest threads.

`python3 phone_broker.py --help` lists the explicit paths and identity arguments.
Token values are read from a private binary file and are never command arguments
or log fields. Session IDs and certificate pins are identifiers, not credentials.
The caller owns certificate/token creation and deletion and an outer process
deadline. No endpoint is started by importing the module.

The socket-pair and real loopback TLS tests run with:

```sh
python3 -m unittest discover -s apps/ios/GPUStream/gfxstream/linux-reference \
  -p 'test_phone_broker*.py' -v
```

The TLS tests create a temporary certificate with `openssl`, or copy an explicitly
supplied ephemeral fixture certificate from `CABOOSE_TEST_CERT_DIR`. Run them in
a disposable Linux network namespace without published ports. They check correct
and rejected authentication, fragmented duplex traffic, deadlines, byte budgets,
private paths and owned-process/socket cleanup. They do not invoke Vulkan or an
iPhone and do not establish the native decoder's safety for hostile input.

The container's Mesa software ICD can supply Vulkan without a GPU. The loader
remains open for the process lifetime. Upstream desktop GL dependencies remain
linked. This lifecycle fixture is not a production endpoint.

## Private receiver diagnostic

The `caboose_gfxstream_receiver` target is a single-connection test fixture. It
accepts a loader path and an existing directory owned by its effective UID with
mode 0700. It creates `decoder.sock` there, checks the peer UID, and associates
that connection with one preauthorized process ID. It waits at most 20 seconds
for a connection and uses five-second socket I/O timeouts. Run it under an outer
30-second timeout and remove the private directory after it exits. Do not expose
the socket to untrusted clients: decoder packet fields are not fully validated.

On little-endian hosts, a client sends 48 bytes before the native Mesa stream:
ASCII `CBGLREF1`, little-endian u32 version 1, little-endian u32 feature mask,
and the 32-byte source tuple SHA-256
`20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0`.
The mask bits 0–3 represent sequence numbers, direct memory, VirtioGpuNext and
ExternalBlob. This fixture verifies all four disabled on the initialized
framebuffer and accepts only mask zero. It echoes the exact hello on a match;
a mismatch closes before consuming client flags. The fingerprint identifies the
pinned source tuple, not full marshaling compatibility. This diagnostic handshake
is separate from the shipping display protocol.

Build the receiver with the same container and limits as above by replacing the
build target with `caboose_gfxstream_receiver`. Check the handshake and EOF with:

```sh
docker run --rm --network none --cpus 2 --memory 3g -v "$WORK:/work" \
  -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json caboose-decoder-reference \
  python3 /work/gfxstream/linux-reference/test_receiver.py \
  /work/build/caboose_gfxstream_receiver /usr/lib/x86_64-linux-gnu/libvulkan.so.1
```

`phone_session.py prepare --directory PRIVATE_TRIAL --bind TAILSCALE_IPV4`
creates ephemeral certificate/token files and a private phone launch-environment
JSON without starting a listener. `run --directory PRIVATE_TRIAL --guest-runner
/path/to/phone_guest_oracle.py` starts the finite broker and launches the guest
CPU/encoder oracle only after phone authentication. The 90-second deadline includes
waiting for the explicit phone Start action. Credential files are kept outside the
transport directory mounted into the guest container. On exit the runner reaps
its children, checks the exact trial-labeled container, and deletes credentials;
root independently stops the diagnostic app and verifies device cleanup. The
host verdict remains provisional until the phone executor identity and teardown
are independently recorded. The orchestration tests mock process boundaries and
do not establish physical-device transport behavior.
