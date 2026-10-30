# Making a Caboose app

A Caboose app is a small web app that runs as a real application on this computer. It has
its own window, its own icon in the Apps screen, its own saved data, and, when it asks for
them, native powers: running programs, reading and writing files, reaching anything on the
network, sending notifications and opening links; and everything the web platform does,
including sound and video that keep playing when the owner leaves the app. The owner opens
it from their phone like any other app; on iPhone it fills the screen, on iPad or a TV it is
a window.

## Steps

1. Pick an id: a lowercase letter, then up to 47 lowercase letters, digits or hyphens
   (`budget`, `photo-sorter`, `server-status`).
2. Write the app into `~/Apps/<id>/`: `app.json`, `index.html`, and anything else it uses.
3. Publish it: the `app_publish` tool, or `caboose-app publish <id>`. It checks the app and
   lists it in the Apps screen. Fix every error it reports and publish again. Review its
   input-layout warnings; they do not prevent an existing app from opening.
4. Try it: `app_open` opens it on your own display, then use `screenshot`, `elements` and
   `click_element` to see and use it like the owner will. Edit the files and the open window
   reloads by itself. The page's console messages and script errors, including anything
   the content policy blocked, are in `~/.local/share/caboose/apps/<id>/console.log`.

`caboose-app check <id>` validates without publishing; `caboose-app list` shows every app;
`caboose-app remove <id>` takes one off the Apps screen (`--purge` also deletes its files
and data).

## `app.json`

```json
{
  "name": "Server Status",
  "description": "Uptime, load and disk of this computer at a glance.",
  "version": "1.0.0",
  "icon": "icon.svg",
  "categories": ["System"],
  "capabilities": ["exec"],
  "window": { "width": 900, "height": 640, "minWidth": 360, "minHeight": 480, "background": "#0f1115" }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Shown under the icon and as the window title until the page sets `<title>`. At most 60 characters. |
| `description` | | One sentence, at most 300 characters. |
| `version` | | Free text, at most 32 characters. |
| `entry` | | The page that opens, default `index.html`. |
| `icon` | | An `.svg` or `.png` in the app directory, square, at least 128 px. Without one the app gets a monogram. |
| `categories` | | Any of `AudioVideo`, `Audio`, `Video`, `Development`, `Education`, `Game`, `Graphics`, `Network`, `Office`, `Science`, `Settings`, `System`, `Utility`. Default `Utility`. |
| `capabilities` | | Which parts of `window.caboose` the app uses: `exec`, `files`, `net`, `notify`, `open`. Calls to an undeclared one fail. Changes apply the next time the app starts. |
| `handoff` | | Set to `"files"` only when all persistent app state uses `caboose.files`; the phone may run the page locally. Browser storage is not transferred between the phone and computer. Without it the app runs on the computer. An app whose sound should keep playing on the phone in the background needs it. |
| `window` | | Opening size and limits in pixels, and `background`, the colour shown before the page paints (`#rrggbb`). |

Unknown fields are errors, so a typo is caught at publish.

## The page

The app is served from `caboose-app://<id>/`, so relative URLs work as on any site.
Standard web APIs work, including `localStorage`, IndexedDB, canvas, WebGL, Web Audio,
`fetch` and WebSockets to any address. Storage is the app's own and survives the
computer parking and restarting.

**Scripts must be `.js` files in the app directory.** Load them with
`<script src="app.js" defer></script>` or `<script type="module" src="main.js"></script>`; modules may import
other files of the app. These do not run (publishing reports the first three with their
file and line):

- an inline `<script>` with code in it;
- event handler attributes such as `onclick="…"` (use `addEventListener`);
- `javascript:` links;
- `eval`, `new Function` and string arguments to `setTimeout`;
- scripts from other sites, `blob:` or `data:` URLs.

Download a library you need into the app (`curl -L -o vendor/chart.js <url>`) and load it
with a relative path; prefer a library's ES module or UMD build over one that compiles
templates at run time. WebAssembly works. Stylesheets, fonts and images may come from
anywhere, but local copies keep the app working offline. Links to other sites open in the
browser, and remote pages cannot be embedded in frames.

`fetch` from the app follows the web's cross-origin rules, and the page is a secure origin
that may not load plain `http`. Declare `net` and use `caboose.fetch` (below) to reach
anything else.

## `window.caboose`

Available as soon as the page's scripts run.

```js
caboose.app // { id, name, version, dir, dataDir, capabilities }
```

**`exec`** — run programs as the computer's user, with that user's full authority.

```js
const { code, stdout, stderr, timedOut, truncated } =
  await caboose.exec(['df', '-h', '/'], { cwd, env, stdin, timeoutMs, encoding })
```

`argv` is the program and its arguments; no shell is involved, so use
`['sh', '-c', '…']` when you want one. `cwd` defaults to `caboose.app.dataDir`. `timeoutMs`
defaults to 60000 and is at most 600000; on timeout the program is killed, including while
it leaves `stdin` unread. Output is text,
or base64 with `encoding: 'base64'`, and at most 16 MB of each stream is kept.

```js
const server = await caboose.spawn(['python3', '-u', 'worker.py'], {
  cwd: caboose.app.dir,
  onStdout: text => log(text),
  onStderr: text => log(text),
  onExit: ({ code, signal }) => done(code),
})
await server.write('input line\n')
await server.closeStdin()
await server.kill()        // 'TERM' by default; 'INT', 'HUP' or 'KILL'
await server.exited        // { code, signal }
```

`write` fails if the program has not taken the input within 30 seconds. At most 16
programs run at once per app. Programs end when the page reloads or navigates,
and when the app closes; nothing is ever re-run by a reload.

**`files`** — read and write files. A relative path is inside `caboose.app.dataDir`, the
app's private directory; an absolute path (or `~/…`) must be inside `/home/caboose`.
Symbolic links are never followed. Writes replace the file whole.

```js
await caboose.files.writeJSON('settings.json', settings)
const settings = await caboose.files.readJSON('settings.json')
await caboose.files.readText('~/Documents/notes.md')
await caboose.files.readBytes(path)          // Uint8Array
await caboose.files.writeText(path, text)
await caboose.files.writeBytes(path, bytes)  // Uint8Array or ArrayBuffer
await caboose.files.list('~/Pictures')       // [{ name, kind, size, modified }]
await caboose.files.stat(path)               // { name, kind, size, modified }
await caboose.files.exists(path)
await caboose.files.mkdir(path)              // with parents
await caboose.files.remove(path, { recursive: true })
```

A file read or write is at most 64 MB.

**`net`** — the whole network: any `http` or `https` URL, with no CORS, plain `http`
allowed, any method, headers and body, and the response streamed.

```js
const response = await caboose.fetch('http://192.168.1.20/api/state', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
  body: JSON.stringify({ on: true }),
})
const data = await response.json()       // a standard Response: json(), text(), body streams
response.headers.get('X-Caboose-Url')    // the final URL, after redirects

img.src = caboose.net.url('http://camera.local/snapshot.jpg')    // a URL for any element
audio.src = caboose.net.url('http://stream.example:8000/live')   // <audio>, <video>, <img>,
new EventSource(caboose.net.url('https://api.example/events'))   // CSS, EventSource, fetch
```

`caboose.fetch` takes the same arguments as `fetch` and also sends the headers a page may not
set itself (`Cookie`, `User-Agent`, `Referer`, `Origin`). Requests carry no cookies of their
own: send what a service needs in headers, and read the cookies it sets from the response's
`X-Caboose-Set-Cookie` headers. A server that cannot be reached answers `502` with the reason
in `X-Caboose-Error`. Requests go out from wherever the page runs: the computer, or the
owner's phone when the app runs there (`handoff`), so `localhost` and LAN addresses mean that
machine's. WebSockets (`wss:`) connect directly without `net`.

**`notify`** — a notification, which reaches the owner's phone.

```js
await caboose.notify('Backup finished', '42 GB copied to the NAS')
```

**`open`** — a web, mail or phone link in its default app, or a file in the home with its
default application.

```js
await caboose.open('https://example.com')
await caboose.open('~/Documents/report.pdf')
```

Every call returns a promise that rejects with an `Error` whose message says what to fix.

## Sound and video

Play anything the web plays: `<audio>`, `<video>`, Web Audio, from the app's files or from
the network (`caboose.net.url` for a source the page cannot reach itself). When the app runs
on the owner's phone (it needs `handoff: "files"`), a page that is playing when they leave Caboose or lock the phone keeps
running in the background, so the sound goes on; a video goes on in Picture in Picture when
they start it from its controls. Describe what plays with the
[Media Session API](https://developer.mozilla.org/docs/Web/API/Media_Session_API)
(`navigator.mediaSession.metadata` and action handlers) and the system's media controls (the
Lock Screen, Control Center, headphones and AirPlay) show and control it. While the phone
keeps the page running, its `net` requests and timers carry on, but calls that reach the
computer (`exec`, `files`, `notify`, `open`) fail until the owner opens Caboose again, when
the same page reconnects without reloading. The phone's WebKit does not play Ogg streams
(Vorbis or Opus): check a stream with `ffprobe` and prefer its MP3, AAC or HLS version. On
the computer, sound plays through the display, so it stops reaching the phone when Caboose
leaves the screen.

## Making it beautiful

The owner usually sees the app on a phone, full screen, and expects it to feel like an iOS
app, not a web page.

- **Design for a phone first.** Lay out for 390 px wide and let it grow to a desktop
  window: one column that becomes two, not a desktop layout squeezed down. Keep touch
  targets at least 44 px. Never rely on hover.
- **Fill the window.** `html, body { height: 100% ; margin: 0 }`, no page scrollbars on
  the app's chrome, scrolling only inside the content that scrolls. Add
  `<meta name="viewport" content="width=device-width, initial-scale=1">`.
- **Type.** `font-family: Inter, system-ui, sans-serif` (Inter is installed), and
  `JetBrains Mono` for code and numbers that line up. Use `font-variant-numeric:
  tabular-nums` for figures that change.
- **Colour.** Support light and dark with `prefers-color-scheme`. Pick one accent colour;
  use it for the primary action and state, nothing else. Set `window.background` to the
  page's background colour so the window never flashes white.
- **Feel.** Give every action immediate feedback, animate state changes for 150–250 ms with
  `transform` and `opacity`, show skeletons or progress while waiting, and design the
  empty, loading and error states as carefully as the full one.
- **No mock data.** Show the real thing, from `exec`, `files`, `fetch` or what the owner
  enters, and remember the owner's data with `localStorage` or `files`.
- **An icon.** A simple, bold, square SVG with a rounded-rectangle background reads well on
  the Apps screen.

## Interaction acceptance checks

Before calling an app ready, open it with `app_open` on your own seat and check it at
390 × 780 and a desktop window size. `check` and `publish` validate files and report
static viewport warnings; they do not execute the app or prove that its controls work.

1. Inspect the layout and console. Use one device-width viewport with initial scale 1,
   controls at least 44 CSS px across, and text inputs at least 16 CSS px. Load scripts
   after the DOM is available. Keep browser zoom available; do not hide an input defect
   with `user-scalable=no`, a maximum scale, or a page-wide `touch-action:none`.
2. Use real pointer clicks through the desktop tools on the primary action and every
   distinct control type (buttons, filters, checkboxes, links). Confirm the resulting UI
   change, not just a pressed style. Accessibility activation is useful too, but can
   bypass overlays and pointer hit testing. A screenshot alone does not prove input.
3. Focus an input, type and submit; confirm the expected result. Scroll overflowing
   content in both directions and check that controls remain reachable. Keep native
   scrolling and touch handling; custom gestures belong only on the surface needing them.
4. For stateful apps, use clearly test-owned records to verify save and reload, then
   remove only those records. Preserve existing owner data, files and storage. Do not
   enable `handoff: "files"` on an existing browser-storage app as an input workaround:
   device and computer browser storage are separate.
5. If a phone test is available, check a single tap and one-finger scroll in the actual
   presentation (card or Desktop), and text entry. Record whether the app runs in guest
   WebKitGTK or native handoff. Agent-seat pointer tests do not verify phone gestures.

Report the tested sizes, interactions and observed results. If a capability or phone
is unavailable, name the untested check plainly; do not describe it as passing. Diagnose
page construction separately from Caboose input routing before changing either.

## What an app can do

An app is code in the owner's home that runs as the owner's user, and its own code is
trusted with everything its capabilities give it. One that declares `exec` can do anything
a terminal can; one that declares `net` can reach anything the machine it runs on can,
including its own services and the owner's network. Declared capabilities say what the app
uses; they are not a sandbox.

What the runtime keeps out is the web: script runs only from the app's own files, only the
app's top frame can reach `window.caboose`, and the page cannot be navigated to another
site. What `caboose.fetch` and `caboose.net.url` bring in comes from a different origin, so
it is data, never the app's script. That holds only while the app's own code does not run what it downloads (for
example, by passing fetched text to `caboose.exec` as a program). Put text from the network
or from files into the page with `textContent` rather than `innerHTML`.
