# Guest file service

`caboose-files.py` is a private Python 3 service for the Caboose host, running as
`caboose` on port 14700. It reads `/run/caboose/xpra-token` for every request; the host
writes that file before starting the service. It opens path components through directory
file descriptors without following links. Its `/changes` endpoint uses Linux inotify and a
bounded, per-process journal. See `../../docs/architecture.md` § Files for the protocol.

Both image builders and the host's automatic existing-guest upgrade install it through
`guest/components`. Never publish port 14700 to the network: it is a private host-to-guest
transport. Old containers without a port mapping must be recreated for Files; preserve the
home volume and back up the writable layer first.

From the repository root, run the Linux service check with Docker:

```sh
docker run --rm -v "$PWD/guest/files:/checks:ro" python:3.13-slim python3 /checks/check-service.py
```

The host's `scripts/check-fs.mjs` additionally checks an actual paired computer through the
public API. See `../../apps/host/README.md` for its environment and effects.
