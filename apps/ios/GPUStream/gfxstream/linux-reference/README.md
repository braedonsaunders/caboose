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
