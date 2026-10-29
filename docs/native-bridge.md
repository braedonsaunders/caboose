# Native bridge

Linux desktop applications ask their desktop for a few services through freedesktop
standards: choosing files, the colour scheme, media controls, location. Caboose answers
those standards from the phone, so unmodified applications get iOS document pickers,
follow the phone's appearance, appear in Now Playing, and see the phone's location.

Nothing here is per application. An application that uses the standard gets the iOS
behaviour; one that does not keeps its own.

| Linux standard | Answered with | Component |
| --- | --- | --- |
| `org.freedesktop.impl.portal.FileChooser` | The iOS document picker; a native save and folder sheet | `caboose-portal` |
| `org.freedesktop.impl.portal.Settings` (`org.freedesktop.appearance`), GSettings `org.gnome.desktop.interface` | The phone's appearance, contrast, Reduce Motion and text size | `caboose-portal`, `caboose-bridge` |
| MPRIS (`org.mpris.MediaPlayer2.*`) | `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` | `caboose-bridge` |
| GeoClue (static source) | Core Location, opt-in | the host, as root |

This document is the contract between `guest/bridge`, the host (`apps/host/src/bridge.ts`,
`apps/host/src/now-playing.ts`) and the app (`apps/ios/Caboose/Bridge`, CabooseKit's
`Bridge`). Change it in the same pull request as any code that changes it.

## Guest

`guest/bridge` is a guest component (`guest/components/manifest.json`); its installer adds
`xdg-desktop-portal`, `xdg-desktop-portal-gtk` and `geoclue-2.0`. It installs:

- `/usr/local/bin/caboose-bridge`, the command the host runs as `caboose`, and the
  `caboose-bridge.service` user daemon on the owner's session bus (MPRIS and appearance).
- `/usr/libexec/caboose-portal`, the portal backend `org.freedesktop.impl.portal.desktop.caboose`,
  with `caboose.portal` and its D-Bus activation file.
- `portals.conf` choosing `caboose` for FileChooser and Settings and `gtk` for the rest.
- The environment that makes toolkits use the portal: `GTK_USE_PORTAL=1`, Qt's
  `xdgdesktopportal` platform theme, and Firefox's portal file picker preference.

State lives in `/home/caboose/.cache/caboose/bridge/` (mode 0700, owned by `caboose`). It is
the owner seat's only. The agent seat has its own session bus: there the portal backend
serves the computer's own dialogs and the default appearance, and never reaches the phone.

### Phone presence

`caboose-bridge drain` (below) touches `bridge/present`. The phone is **present** while that
file's modification time is less than 3 seconds old by the guest's clock. The host drains
every second exactly while a phone's foreground control socket is connected, so presence
follows the phone being in the foreground and connected.

### File chooser

`caboose-portal` implements `OpenFile` and `SaveFile`.

1. If the phone is not present, the call goes to `xdg-desktop-portal-gtk` with the same
   arguments, and its result is returned: the computer's own dialog.
2. Otherwise it writes a request to `bridge/requests/<id>.json` and waits.
3. A request not claimed within 3 seconds is withdrawn and goes to the computer's dialog.
4. Once claimed, it waits for the answer without a time limit. If the phone stops being
   present for 10 seconds while a claimed request is open, the request is cancelled and
   goes to the computer's dialog, which is waiting on the desktop when the owner returns.
5. `Request.Close` from the application withdraws the request (`bridge/cancels/<id>`) and
   answers with response 2.

A request:

```ts
{
  id: string,              // 32 lowercase hex digits
  type: "file.open" | "file.save",
  app: string,             // the caller's application id, or ""; at most 200 characters
  title: string,           // the dialog title the application asked for; at most 200
  acceptLabel: string,     // at most 64; "" for the default
  multiple: boolean,       // file.open only; false for file.save
  directory: boolean,      // file.open only: choose a folder
  filters: [{ name: string, patterns: string[], mimeTypes: string[] }], // at most 32, each list at most 32
  currentFilter: number | null, // an index into filters
  currentName: string,     // file.save: the suggested file name (no separators), else ""
  currentFolder: string,   // absolute path under /home/caboose, or ""
  created: number          // Unix seconds, guest clock
}
```

Patterns are the portal's glob patterns (`*.odt`); a pattern of the form `*.ext` is
treated as an extension, other patterns only as a hint.

The answer, written by `caboose-bridge respond` to `bridge/responses/<id>.json`:

```ts
{ id, response: "ok", paths: string[], filter: number | null }   // absolute paths under /home/caboose
{ id, response: "cancel" }                                         // the owner cancelled: portal response 1
{ id, response: "computer" }                                       // show the computer's own dialog instead
```

For `file.open` every path must exist, be a regular file (a directory when `directory`),
and there is exactly one unless `multiple`. For `file.save` there is exactly one path, its
parent directory must exist, and the application writes it after the portal returns. A
path that fails these checks answers response 2. The portal returns `file://` URIs.

### Appearance

`caboose-bridge appearance JSON` writes `bridge/appearance.json`:

```ts
{
  colorScheme: "light" | "dark",
  accent: string,          // "#RRGGBB"
  contrast: "normal" | "high",
  reducedMotion: boolean,
  textScale: number        // 0.75 to 2, the phone's text size relative to its default
}
```

The daemon applies it to the owner's session: `org.freedesktop.appearance` `color-scheme`
(1 dark, 2 light), `accent-color` (sRGB 0–1), `contrast` (1 high) and `reduced-motion` (1
reduced) through `caboose-portal`'s Settings, emitting `SettingChanged`; and the GSettings
keys GTK 3, Qt (through its GTK platform theme) and Xfce read: `org.gnome.desktop.interface`
`color-scheme`, `gtk-theme` (`Adwaita` or `Adwaita-dark`, or `HighContrast` /
`HighContrastInverse`), `accent-color` (the nearest named accent), `enable-animations` and
`text-scaling-factor`, and the matching Xfce settings. Applications that follow neither
keep their own appearance.

Without a phone the computer keeps the appearance it last received.

### Now playing

The daemon watches the session bus for `org.mpris.MediaPlayer2.*` names and keeps
`/home/caboose/.cache/caboose/now-playing.json` equal to the player to show, atomically
replaced and removed when there is none. It records its pid in `bridge/daemon.pid`. The
player shown is the one most recently playing; with none playing, the one most recently
paused.

```ts
{
  id: string,              // /^[A-Za-z0-9._-]{1,64}$/; a new id for a new player or track
  player: string,          // MPRIS Identity, at most 100 characters
  title: string,           // at most 300; "" if none
  artist: string,          // at most 300
  album: string,           // at most 300
  artwork: string | null,  // an https URL from mpris:artUrl, at most 4096; null otherwise
  position: number,        // seconds
  duration: number | null, // seconds; null when unknown or live
  paused: boolean,
  rate: number,            // playback rate, 0 to 16
  canPlay: boolean, canPause: boolean, canNext: boolean, canPrevious: boolean, canSeek: boolean,
  updatedAt: number        // ms since the epoch, guest clock: when `position` holds
}
```

Commands arrive in `/home/caboose/.cache/caboose/now-playing-command.json`:
`{ seq, id, action: "play" | "pause" | "toggle" | "next" | "previous" | "seek", position? }`.
The daemon ignores a `seq` it has passed and an `id` that is no longer shown; `seek`
requires `position` and calls `SetPosition` on the track.

## Host

### Bridge requests

`apps/host/src/bridge.ts`. While the computer is running and at least one control socket
opened with `?phone=1` is connected, the host runs `caboose-bridge drain` as `caboose` every
second. It prints `{ requests: [...], cancels: [id...] }` (at most 16 of each), having moved
each request it prints to `bridge/claimed/`. The host validates each request field by field
(the limits above; strings without control characters) and sends to those sockets:

| Event | Payload |
| --- | --- |
| `bridge.request` | `{ request }` |
| `bridge.cancel` | `{ id }`: the application withdrew it, or it was answered from another phone |

Delivery is at most once. The host remembers outstanding ids for 24 hours.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/bridge/requests/:id` | The answer: `{ response: "ok", paths, filter? }`, `{ response: "cancel" }` or `{ response: "computer" }` → 204. 404 for an id the host did not deliver or already answered; 409 unless running. Never wakes |
| `PUT` | `/v1/bridge/appearance` | The phone's appearance (above) → 204. Applied now if running, and at every wake |
| `PUT` | `/v1/bridge/location` | `{ latitude, longitude, accuracy, altitude? }` → 204 (below) |
| `DELETE` | `/v1/bridge/location` | Stop sharing location → 204 |
| `GET` | `/v1/now-playing` | `{ nowPlaying: <state> \| null }`; null unless running. Never wakes or leases |
| `POST` | `/v1/now-playing/:id/control` | `{ action, position? }` → `{ sent: true }`; 409 unless running |

Answers are validated strictly (400): only the listed fields; `paths` 1–64 absolute paths
under `/home/caboose/`, each at most 4096 bytes, without `.` or `..` segments or control
characters; `filter` an integer index. The host then runs `caboose-bridge respond` with the
answer; it refuses an id that is not claimed. Appearance: the fields above exactly.

### Location

Location is shared only while the owner turns it on in the app. `PUT /v1/bridge/location`
accepts `latitude` −90…90, `longitude` −180…180, `accuracy` 0…100000 metres and
`altitude` −1000…100000 metres, at most once every 5 seconds (429 otherwise). The host
writes `/etc/geolocation` as root (latitude, longitude, altitude, accuracy, one per line),
which GeoClue's static source serves to every application that asks, through the Location
portal or GeoClue directly. `DELETE` and 30 minutes without an update remove the file.

### Now playing relay

`apps/host/src/now-playing.ts` reads `now-playing.json` about once a second while the
computer is running and a display client is connected, ignoring a file whose daemon is not
running, and extrapolates `position` as media handoff does. It broadcasts
`now-playing.changed { nowPlaying }` on every change and `now-playing.stopped { id }`.
Control writes `now-playing-command.json` with a millisecond-based `seq`.

## App

### Open and Save

The app answers `bridge.request` while it is in the foreground:

- **Open** presents the system document picker for the filter's types (any item when no
  type resolves), with multiple selection when asked. A file from Caboose's own File
  Provider answers with its computer path; any other file is copied to
  `Caboose Documents/<uuid>/<name>` and kept in sync with its original as
  [open in place](architecture.md#open-in-place) does, so saving in the Linux application
  writes back to iCloud Drive or wherever it came from.
- **Choose folder** and **Save** present a native sheet browsing the computer's home:
  folders, the file name (its extension kept when a filter applies), the format from the
  application's filters, and confirmation before replacing a file.
- Every sheet offers **Use Computer Dialog**, which answers `computer`. With **Use iPhone
  dialogs** off in the computer's settings, every request is answered `computer`.
- `bridge.cancel` dismisses the sheet.

### Appearance, Now Playing and location

- The app sends its appearance on each control connection and whenever its traits change,
  while **Match iPhone appearance** is on.
- While a track is shown and the display is connected, the app publishes it to
  `MPNowPlayingInfoCenter` and handles play, pause, toggle, next, previous and scrubbing
  from Control Center, the Lock Screen, AirPods and keyboard media keys. The app plays the
  computer's sound only while in the foreground, so this is Now Playing for the computer
  while Caboose is open.
- **Share location with computer** (off by default) asks for When In Use location and sends
  updates while the app is in the foreground; turning it off sends `DELETE`.
