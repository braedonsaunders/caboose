# Native bridge

Linux desktop applications ask their desktop for a few services through freedesktop
standards: choosing files, the colour scheme, media controls, location. Caboose answers
those standards from the phone, so unmodified applications get iOS document pickers (and the
phone's photos, camera and document scanner as places to open from), follow the phone's
appearance, appear in Now Playing, and see the phone's location. `caboose-scan` scans a
document with the phone from a terminal or a script.

Nothing here is per application. An application that uses the standard gets the iOS
behaviour; one that does not keeps its own.

| Linux standard | Answered with | Component |
| --- | --- | --- |
| `org.freedesktop.impl.portal.FileChooser` | The iOS document picker, Photos, the camera and the document scanner; a native save and folder sheet | `caboose-portal` |
| `org.freedesktop.impl.portal.Settings` (`org.freedesktop.appearance`, `org.gnome.desktop.interface`) | The phone's appearance, accent, contrast, Reduce Motion and text size | `caboose-portal`, `caboose-bridge` |
| MPRIS (`org.mpris.MediaPlayer2.*`) | `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` | `caboose-bridge` |
| GeoClue (static source) | Core Location, opt-in | the host, as root |
| `caboose-scan`, Caboose's own command | The iOS document scanner | `caboose-scan` |

This document is the contract between `guest/bridge`, the host (`apps/host/src/bridge.ts`,
`apps/host/src/now-playing.ts`) and the app (`apps/ios/Caboose/Bridge`, CabooseKit's
`Bridge`). Change it in the same pull request as any code that changes it.

## Guest

`guest/bridge` is a guest component (`guest/components/manifest.json`); the components
installer adds `xdg-desktop-portal`, `xdg-desktop-portal-gtk` and `geoclue-2.0`. It installs
into `/opt/caboose/bridge`:

- `caboose-bridge` (also `/usr/local/bin/caboose-bridge`), the command the host runs as
  `caboose`, and its daemon on the owner's session bus (`caboose-bridge.service` in the
  microVM, started by `caboose-session` in the container): MPRIS, the appearance for X11
  applications, and the owner display's launch environment for D-Bus-activated services
  (`UpdateActivationEnvironment`, and the systemd user manager's environment), so the
  portals' dialogs open on the right display.
- `caboose-portal`, the portal backend `org.freedesktop.impl.portal.desktop.caboose`, with
  `caboose.portal` and its D-Bus activation file.
- `caboose-scan` (also `/usr/local/bin/caboose-scan`), which asks the phone to scan a
  document (below).
- `/etc/xdg/xdg-desktop-portal/portals.conf` choosing `caboose` for FileChooser and Settings
  and `gtk` for the rest.
- What makes applications use the portal: `GTK_USE_PORTAL=1` in each seat's launch
  environment (caboose-display), and Firefox's portal preferences for its file picker,
  appearance and location. Qt applications keep the GTK platform theme and its dialogs.

State lives in `/home/caboose/.cache/caboose/bridge/` (mode 0700, owned by `caboose`). It is
the owner seat's only. The agent seat has its own session bus: there the portal backend
serves the computer's own dialogs and the default appearance, and never reaches the phone.

### Phone presence

The host renews the Files presence lease once per second while a foreground phone control
socket is connected. Each renewal touches `bridge/present`. The phone is **present** while
that file's modification time is less than 3 seconds old by the guest's clock. Lease
generations fence stale requests, and missing renewals expire naturally.

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
  type: "file.open" | "file.save" | "scan", // "scan": see Scan below
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

`caboose-bridge drain` prints a request it cannot read as `{ id }` only; the host answers
such a request with `computer`. The answer, written by `caboose-bridge respond` to
`bridge/responses/<id>.json`:

```ts
{ id, response: "ok", paths: string[], filter: number | null }   // absolute paths under /home/caboose
{ id, response: "cancel" }                                         // the owner cancelled: portal response 1
{ id, response: "computer" }                                       // show the computer's own dialog instead
```

`respond` prints `{ "answered": true }`, or `{ "answered": false }` when the request is no
longer claimed (withdrawn, or gone to the computer's dialog), and exits non-zero for an
invalid answer.

For `file.open` and `scan` every path must exist, be a regular file (a directory when
`directory`), and there is exactly one unless `multiple`. For `file.save` there is exactly one path, its
parent directory must exist, and the application writes it after the portal returns. A
path that fails these checks answers response 2. The portal returns `file://` URIs.

### Scan

`caboose-scan [--format pdf|jpeg] [--output PATH]`, run as `caboose`, asks the phone to scan
a document and prints the path of each file it wrote, one per line. It writes a `scan`
request through the same queue, claim and answer as the file chooser:

- Its one filter names the format, and `currentFilter` is `0`: `{ name: "PDF", patterns:
  ["*.pdf"], mimeTypes: ["application/pdf"] }` with `multiple` false (one PDF, every page),
  or `{ name: "JPEG", patterns: ["*.jpg", "*.jpeg"], mimeTypes: ["image/jpeg"] }` with
  `multiple` true (one image per page). `app`, `title`, `acceptLabel`, `currentName` and
  `currentFolder` are `""`, and `directory` is false.
- The answer is `ok` with the scanned files' paths, `cancel`, or `computer` when the phone
  cannot scan (no document scanner, or no connected app that answers scan requests, for
  which the host answers) or cannot show the request now. The phone uploads the scan to
  `~/Caboose Documents/<uuid>/`.
- With `--output`, the scan moves there: a PDF to that file (replacing it) or into that
  folder; JPEG pages into that folder, made when missing.

There is no scanner on the computer to fall back to, so where the file chooser shows the
computer's dialog, `caboose-scan` fails: at once when the phone is not present, when the
request is not claimed within 3 seconds, and when the phone is gone for 10 seconds while the
request is claimed (which withdraws it). Interrupting it withdraws the request. Exit status:
0 scanned, 1 cancelled or failed, 2 usage, 3 the phone is not there.

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

`caboose-portal` serves it on the owner's seat, emitting `SettingChanged` for each value
that changes:

- `org.freedesktop.appearance`: `color-scheme` (1 dark, 2 light), `accent-color` (sRGB
  0–1), `contrast` (1 high) and `reduced-motion` (1 reduced).
- `org.gnome.desktop.interface`, which GTK reads through the portal on Wayland:
  `gtk-theme` (`WhiteSur-Dark` or `WhiteSur-Light`, `Adwaita-dark` or `Adwaita` when that
  WhiteSur variant is not installed), `icon-theme`, `cursor-theme`, `font-name`,
  `color-scheme` (`prefer-dark` or `default`), `accent-color` (the GNOME accent matching
  the phone's system colour), `text-scaling-factor` and `enable-animations`.

The daemon also writes the theme keys of `~/.config/gtk-3.0/settings.ini` and
`gtk-4.0/settings.ini`, which X11 GTK applications read when they start. The agent seat
always has the image's own appearance (dark). Without a phone the computer keeps the
appearance it last received; with none received, the image's own.

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

`apps/host/src/bridge.ts`. While the computer is running and at least one foreground control
socket opened with `?phone=1` is connected, the host subscribes to Files bridge events.
Files claims complete requests into `bridge/claimed/` and retains them until a response.
Transport disconnects do not delete pending records. The host validates each request field by field
(the limits above; strings without control characters; a `scan` exactly as
[Scan](#scan) describes it) and sends to those sockets. Scan requests go only to foreground
sockets also opened with `?scan=1` (an app that answers scan requests):

| Event | Payload |
| --- | --- |
| `bridge.request` | `{ request }` |
| `bridge.cancel` | `{ id }`: the application withdrew it, or it was answered from another phone |

Delivery is at most once. The host remembers outstanding ids for 24 hours. A `scan` with no
connected foreground phone socket opened with `?scan=1` is answered `computer` at once, so
`caboose-scan` fails promptly instead of waiting on an app that cannot answer it.

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

`apps/host/src/now-playing.ts` receives changed `now-playing.json` snapshots through Files while the
computer is running and a display client is connected, ignoring a file whose daemon is not
running, and extrapolates `position` as media handoff does. It broadcasts
`now-playing.changed { nowPlaying }` on every change and `now-playing.stopped { id }`.
Control writes `now-playing-command.json` with a millisecond-based `seq`.

## App

### Open and Save

The app answers `bridge.request` while it is in the foreground. The shell supplies its own
window for presentations and appearance; an external display is never chosen. Requests
retain their original computer and generation through picking, uploading and answering.
Changing computers, losing the control connection or entering the background dismisses
pending dialogs and invalidates their callbacks. Native media handoff suspends the bridge’s
Now Playing metadata and commands until playback returns to the computer.


- **Open** (files, not a folder) first asks where the file comes from, in a sheet that
  lists only the sources whose files the request accepts (judged by the current filter, else
  by all of them), and **Use Computer Dialog**. With Files the only source, the document
  picker opens directly. Closing a source without choosing returns to the sheet.
  - **Files**: the system document picker for the filter's types (any item when no type
    resolves), with multiple selection when asked. A file from Caboose's own File Provider
    answers with its computer path; any other file is copied to
    `Caboose Documents/<uuid>/<name>` and kept in sync with its original as
    [open in place](architecture.md#open-in-place) does, so saving in the Linux
    application writes back to iCloud Drive or wherever it came from.
  - **Photos**: the system photo picker, showing photos, videos or both as accepted, with
    multiple selection (up to 64) when asked. A Live Photo is sent as its still.
  - **Camera**: a new photo or video, on a phone with a camera.
  - **Scan Document**: the document scanner, where VisionKit supports it.
- Photos, captures and scans are new files: each is uploaded to
  `Caboose Documents/<uuid>/<name>` and answered with that path, with nothing to keep in
  sync. A picked photo keeps the name Photos gives it; the others are named when they were
  made (`Photo 2026-10-30 14.05.jpg`, `Video 2026-10-30 14.05.mov`,
  `Scan 2026-10-30 14.05.pdf`, `Scan 2026-10-30 14.05 Page 2.jpg`).
- Formats. A request accepts a type *by name* when a filter lists it, and *as anything* when
  a filter is a wildcard, there are no filters, or a filter gives only its family
  (`image/*`, `video/*`) or a broad type (`application/octet-stream`). A photo or video is
  sent as it is when its type is accepted by name, or accepted as anything and widely
  readable (JPEG, PNG, GIF, TIFF, BMP; QuickTime, MPEG-4). Otherwise it is converted to the
  first format accepted by name, else the first accepted at all, in the order JPEG, PNG,
  HEIC, TIFF for images (an iPhone's HEIC photo for an application that takes any image
  becomes JPEG) and MPEG-4, QuickTime for videos. A camera photo is written the same way.
  A scan is one PDF when PDF is accepted by name, else one image per page when an image
  format is, else a PDF, else JPEG pages. When a request takes one file and an image scan
  has several pages, the app offers to send the first page.
- Metadata is kept: an original is sent byte for byte, and a conversion keeps the photo's
  metadata (drawn upright). A photo from the library can carry where it was taken; Caboose
  does not remove it.
- **Choose folder** and **Save** present a native sheet browsing the computer's home:
  folders, the file name (its extension kept when a filter applies), the format from the
  application's filters, and confirmation before replacing a file.
- The source sheet and the Save and folder sheets offer **Use Computer Dialog**, which
  answers `computer`; so does the alert for a file that could not be sent. With **Open and
  Save with iPhone** off in the computer's settings, every file request is answered
  `computer`.
- `bridge.cancel` dismisses the sheet.
- A request the app cannot read (one from a newer computer) is answered `computer`.
- The app opens its foreground control socket with `?foreground=1&phone=1&scan=1`.

### Scanning

A `scan` request opens the document scanner at once, also with **Open and Save with
iPhone** off: the owner asked for it from the computer. The scan is uploaded as a new file
in the request's format, as above, and the answer is its path (each page's for JPEG).
Cancelling answers `cancel`; a phone without the document scanner answers `computer`. Camera
access is asked for first; without it the app says how to allow it, and answers `cancel`.

### Appearance, Now Playing and location

- The app sends its appearance on each control connection and whenever its traits change,
  while **Match iPhone appearance** is on.
- While a track is shown and the display is connected, the app publishes it to
  `MPNowPlayingInfoCenter` and handles play, pause, toggle, next, previous and scrubbing
  from Control Center, the Lock Screen, AirPods and keyboard media keys. The app plays the
  computer's sound only while in the foreground, so this is Now Playing for the computer
  while Caboose is open.
- **Share Location with This Computer** (off by default) is consent for the paired
  computer only: another computer, or the same phone paired again elsewhere, starts without
  it. It asks for When In Use location and sends updates to that computer while the app is in
  the foreground and connected; turning it off sends `DELETE`.
- Each request, its upload and its answer go to the computer it came from. Signing out,
  switching computers, losing the control connection or going to the background takes down
  what is shown and drops what is waiting; the computer has already given those requests to
  its own dialogs, and a picker that returns afterwards does nothing.
