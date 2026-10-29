# Making a Caboose app

A Caboose app is a small web app that runs as a real application on this computer. It has
its own window, its own icon in the Apps screen, its own saved data, and, when it asks for
them, native powers: running programs, reading and writing files, sending notifications and
opening links. The owner opens it from their phone like any other app; on iPhone it fills
the screen, on iPad or a TV it is a window.

## Steps

1. Pick an id: a lowercase letter, then up to 47 lowercase letters, digits or hyphens
   (`budget`, `photo-sorter`, `server-status`).
2. Write the app into `~/Apps/<id>/`: `app.json`, `index.html`, and anything else it uses.
3. Publish it: the `app_publish` tool, or `caboose-app publish <id>`. It checks the app and
   lists it in the Apps screen. Fix every error it reports and publish again.
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
| `capabilities` | | Which parts of `window.caboose` the app uses: `exec`, `files`, `notify`, `open`. Calls to an undeclared one fail. Changes apply the next time the app starts. |
| `window` | | Opening size and limits in pixels, and `background`, the colour shown before the page paints (`#rrggbb`). |

Unknown fields are errors, so a typo is caught at publish.

## The page

The app is served from `caboose-app://<id>/`, so relative URLs work as on any site.
Standard web APIs work, including `localStorage`, IndexedDB, canvas, WebGL, Web Audio,
`fetch` and WebSockets to any address. Storage is the app's own and survives the
computer parking and restarting.

**Scripts must be `.js` files in the app directory.** Load them with
`<script src="app.js">` or `<script type="module" src="main.js">`; modules may import
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

`fetch` from the app follows the web's cross-origin rules. For an API that does not allow
it, call it with `curl` through `caboose.exec`.

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
defaults to 60000 and is at most 600000; on timeout the program is killed. Output is text,
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

At most 16 programs run at once per app. Programs end when the page reloads or navigates,
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

Check the result with a screenshot at a phone size and a desktop size before you finish.

## What an app can do

An app is code in the owner's home that runs as the owner's user, and its own code is
trusted with everything its capabilities give it. One that declares `exec` can do anything
a terminal can. Declared capabilities say what the app uses; they are not a sandbox.

What the runtime keeps out is the web: script runs only from the app's own files, only the
app's top frame can reach `window.caboose`, and the page cannot be navigated to another
site. That holds only while the app's own code does not run what it downloads (for
example, by passing fetched text to `caboose.exec` as a program). Put text from the network
or from files into the page with `textContent` rather than `innerHTML`.
