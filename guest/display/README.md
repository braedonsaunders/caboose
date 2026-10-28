# Caboose Display

Caboose's own display server: a headless Wayland compositor that streams every window as
its own encoded video, for the phone and TV to show as native surfaces. The design and the
wire contract are [docs/display.md](../../docs/display.md).

This directory is a Cargo workspace:

| Path | What |
| --- | --- |
| `protocol/` | `caboose-display-protocol`: Caboose Display Protocol v0. Framing, the canonical CBOR codec, every message, and the golden vector set |
| `vectors/` | Golden vectors every client replays (see [vectors/README.md](vectors/README.md)) |
| `Dockerfile` | The build and test environment: Debian 13 (the guest's release), the Rust toolchain, the libraries the compositor links, and the apps the checks run |
| `scripts/dev.sh` | Runs a command in that environment with this directory mounted |

## Build and test

Everything builds in the dev container, so the host needs only Docker:

```sh
docker build -t caboose-display-dev guest/display
guest/display/scripts/dev.sh cargo test
guest/display/scripts/dev.sh cargo clippy --all-targets -- -D warnings
```

`dev.sh` runs as the calling user, keeps the cargo registry in
`~/.cache/caboose-display`, and caps the container at 6 CPUs and 6 GiB
(`CABOOSE_DISPLAY_CPUS`, `CABOOSE_DISPLAY_MEMORY`).

The protocol crate has no dependencies. Its tests check the CBOR encoder against the
canonical rules, the stream decoder against split and malformed input, and the committed
vectors against the encoder, so a protocol change that is not reflected in `vectors/`
fails `cargo test`.
