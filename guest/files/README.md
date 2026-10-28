# Guest file service

`caboose-files.py` is a private Python 3 service for the Caboose host, running as
`caboose` on port 14700. It reads `/run/caboose/xpra-token` for every request; the host
writes that file before starting the service. It opens path components through directory
file descriptors without following links. Its `/changes` endpoint uses Linux inotify and a
bounded, per-process journal. See `../../docs/architecture.md` § Files for the protocol.

Both guest image builders install it. To upgrade an existing VM guest from a trusted root
shell, copy this directory into the guest and run:

```sh
install -D -m 0755 caboose-files.py /opt/caboose/files/caboose-files.py
install -m 0644 caboose-files.service /etc/systemd/system/caboose-files.service
systemctl daemon-reload
```

The host starts the unit on the next wake. For the container runtime, rebuild its image and
recreate the container with the existing home volume instead of installing into a running
container. Never publish port 14700 to the network: it is a private host-to-guest transport.

From the repository root, run the Linux service check with Docker:

```sh
docker run --rm -v "$PWD/guest/files:/checks:ro" python:3.13-slim python3 /checks/check-service.py
```

The host's `scripts/check-fs.mjs` additionally checks an actual paired computer through the
public API. See `../../apps/host/README.md` for its environment and effects.
