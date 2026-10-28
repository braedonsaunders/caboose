# Caboose Display Protocol golden vectors

Exact wire bytes for every v0 message ([docs/display.md](../../../docs/display.md)),
produced by `guest/display/protocol`. Every client implementation replays them: decode
each `.bin`, compare against the `.json`, re-encode, and compare bytes. The Rust codec's
tests do this in `guest/display`; CabooseKit's `DisplayVectorTests` do it on iOS
(`swift test` in `apps/ios/CabooseKit`).

Each vector is a pair:

- `<name>.bin`: the exact bytes on the wire: one or more messages, each
  `type: u8, length: u32 LE, payload`.
- `<name>.json`:

  ```json
  {
    "name": "touch-two-fingers",
    "description": "…",
    "messages": [
      { "direction": "client", "type": "touch", "type_id": 144, "fields": { … } }
    ],
    "hex": "<the whole .bin>"
  }
  ```

  `fields` is typed JSON for the payload's CBOR map: a CBOR byte string is
  `{"$bytes": "<hex>"}`, a float is `{"$float": 1.5}`; integers, text, booleans, arrays
  and maps are plain JSON. Keys appear in canonical order.

Three shapes of entry:

- **Canonical** (`fields` only). Decoding the bytes gives `fields`, and encoding `fields`
  gives exactly the bytes.
- **Liberal** (`fields`, `payload_hex`, `canonical_payload_hex`). The payload is valid but
  not canonical (other integer widths, key order, float16, unknown keys). It must decode
  to `fields`; re-encoding gives `canonical_payload_hex`.
- **Unknown** (`"type": null`, `payload_hex`). A type id v0 does not define; the decoder
  skips it by length and the next message still decodes.

The frame and audio vectors carry real media (`media/`): a 64x64 H.264 and a 64x64 HEVC
keyframe that a hardware decoder must accept, a 16x16 PNG for the icon, cursor and tile
vectors, and one 20 ms stereo Opus packet.

Regenerate after changing the protocol, then commit both:

```sh
guest/display/scripts/dev.sh cargo run -p caboose-display-protocol --example write-vectors
guest/display/scripts/dev.sh cargo test -p caboose-display-protocol
```

`media/generate.sh` regenerates the media (run it in the dev container:
`guest/display/scripts/dev.sh vectors/media/generate.sh`). Their bytes depend on the
x264, x265 and libopus versions, so only run it when the media need to change, and re-run
`write-vectors` afterwards.
