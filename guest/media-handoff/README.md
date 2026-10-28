# Caboose media handoff (guest)

When a video plays in the computer's Chromium, the Caboose app can offer **Play on
iPhone / Apple TV**: it plays the video natively, pauses the Linux copy, and resumes it at
the phone's position afterwards. This directory is the guest half: a Chromium extension and
its native messaging host. The host half is `apps/host/src/media.ts`; the contract is in
`docs/architecture.md` § Media handoff.

```
content.js (every http(s) frame) ──▶ service-worker.js ──native messaging──▶ caboose-media-host.mjs
        ▲   pause / play at position          │                                  │ writes ~/.cache/caboose/media.json
        └─────────────────────────────────────┘◀──────── commands ────────────────┘ reads  ~/.cache/caboose/media-command.json
```

- **`content.js` + `media-kind.js`** watch every `<video>` in the frame (capture listeners
  for `play`, `playing`, `pause`, `seeked`, `ended`, `emptied`) and report each one that
  has played, with a heartbeat every 5 s while it plays. A video is offered when it is
  - **HLS**: `currentSrc` is http(s) and its path ends in `.m3u8`; `kind: "hls"`;
  - **a file**: any other http(s) `currentSrc`; `kind: "video"`;
  - **a page-built stream**: `currentSrc` is a `blob:` MediaSource; `kind: "page"`, no
    `src` (the phone opens the page).

  The rule is the same for every site. `data:` and MediaStream sources (calls, cameras)
  are not offered, and nor are muted looping videos (page decoration).
  Videos inside closed or open shadow roots are not seen, since media events do not leave
  a shadow tree. A new source or page in the same element (the next video in a playlist) is new media
  with a new id.
- **`service-worker.js`** keeps every reported video (in `chrome.storage.session`, so a
  restarted worker remembers them), offers the most recently started *playing* video (or,
  when none plays, the most recently started one), and relays commands to the owning
  tab and frame. The media `id` is `<tabId>.<frameId>.<document nonce>-<n>`, matching
  `/^[A-Za-z0-9._-]{1,64}$/`: stable for one tab, frame, element and source.
- **`caboose-media-host.mjs`** (Node, no packages) speaks Chromium's native messaging
  framing (32-bit little-endian length, then UTF-8 JSON). It atomically replaces
  `$HOME/.cache/caboose/media.json` with the offered video:

  ```json
  { "id": "1944008823.0.0gqc72sh-1", "page": "https://videos.example.com/watch/42",
    "title": "A talk", "kind": "page",
    "position": 9.8, "duration": 19.02, "paused": false, "updatedAt": 1793161915640 }
  ```

  `src` is present for `hls` and `video`, absent for `page`;
  `duration` is seconds or `null` (live, or not yet known); `updatedAt` is when `position`
  was sampled, in ms since the epoch on the guest clock. The file is removed when nothing
  is offered, when a new host starts, and when the browser closes. `media-host.pid` names
  the live host, so caboose-host ignores a file left by a browser that is gone.
  It forwards each new command in `$HOME/.cache/caboose/media-command.json`,
  `{ "seq": 1793161920000, "id": "…", "action": "pause" | "play", "position"?: 42.5 }`,
  where `seq` must exceed the last one seen (a command already in the file when the host
  starts is not replayed). It watches the directory with inotify and also re-reads the
  file every second.
- **`install.sh`** (root, image build, after Chromium and Node) copies the extension and
  host to `/opt/caboose/media-handoff`, registers the host in
  `/etc/chromium/native-messaging-hosts/com.caboose.media.json` for this extension only,
  and links the extension into `/usr/share/chromium/extensions/`, which Debian's
  `/usr/bin/chromium` loads for every profile through `/etc/chromium.d/extensions`.
  `guest/container/Dockerfile` and `guest/image/apps.sh` run it.

## Extension ID

`manifest.json` carries a fixed public `key`, so the extension ID is always
**`cklinclacpchpdgickgonlhnldfmkhbh`** (SHA-256 of the key, first 32 hex digits written
`a`–`p`). The private key was discarded: the extension is only ever loaded unpacked, and
nothing needs to sign it. `selftest.mjs` recomputes the ID and checks the installer uses it.

## Why not a `--load-extension` file of our own

Debian 13's Chromium (156) still honours `--load-extension` (the Chromium 137 removal
applies to Google Chrome builds; no `--disable-features` is needed). But Chromium keeps only
the **last** `--load-extension` switch, and Debian's `/etc/chromium.d/extensions` always
adds one (for `/usr/share/chromium/extensions/*`) after any earlier file. A separate
`/etc/chromium.d/caboose-media` was verified to be silently overridden, so the installer
joins Debian's list instead.

## Test

- `node selftest.mjs` (Node only): the extension ID, URL classification, native messaging
  framing (split and coalesced frames), state validation, state file lifecycle, and the
  command relay (ordering, duplicates, invalid commands, no replay at start).
- `check.sh` (a real guest, as root): starts a headless Chromium as `caboose` through
  `/usr/bin/chromium` with a throwaway HOME and profile, plays a local test video, and
  checks the state file, pause, play-at-position, and clearing on browser exit:

  ```sh
  docker exec -u root caboose-owner bash -s < guest/media-handoff/check.sh
  ```

  Add `CABOOSE_CHECK_CHROMIUM_ARGS=--no-sandbox` only where the container has no
  namespace sandbox. It passed against Debian 13's Chromium 156 in a plain
  `debian:trixie-slim` container.
