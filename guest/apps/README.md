# caboose-app

Apps that agents make. An agent app is a web app (HTML, CSS and JavaScript) in
`~/Apps/<id>/` that runs as a real application on the computer: its own window, its own
icon and name in the Apps screen, its own saved data, and, when its manifest declares
them, native capabilities through `window.caboose`. The owner opens it from the phone like
any Linux app. [guide.md](guide.md) is the format and API as agents read it.

| File | Is |
| --- | --- |
| `caboose-app` | The CLI and runtime: a GTK 3 window with a local WebKitGTK view or native handoff, in Python |
| `appcore.py` | Its logic that needs no display: manifests, URLs, desktop entries, the content policy, bridge bounds and file operations |
| `net.py` | The network origin of an app that declares `net` |
| `page.js` | `window.caboose`, injected into the app's top frame |
| `world.js` | The relay between the page and the native bridge, in its own script world |
| `remote.py` | The private, per-instance bridge socket and session grant gate |
| `apps-mcp.mjs` | `caboose-apps`, the MCP server agents use to make apps |
| `guide.md` | How to write an app, served by `app_guide` and `caboose-app guide` |
| `install.sh` | Installs the above at `/opt/caboose/apps` and `caboose-app` in `/usr/local/bin` |

## Commands

```sh
caboose-app run ID            # open the app on this display (DISPLAY / WAYLAND_DISPLAY)
caboose-app check ID          # validate; prints {id, ok, errors, manifest?}
caboose-app publish ID        # validate, then write its desktop entry
caboose-app list              # {apps: [{id, ok, errors, name, description, capabilities, dir, published}]}
caboose-app remove ID [--purge]
caboose-app guide
```

Everything but `run` prints one JSON object and exits 1 when the app is invalid.

## Where things are

| Path | Holds |
| --- | --- |
| `~/Apps/<id>/` | The app: `app.json` and its files, written by the agent |
| `~/.local/share/applications/caboose.app.<id>.desktop` | Its desktop entry, written by `publish` |
| `~/.local/share/caboose/apps/<id>/files/` | `caboose.app.dataDir`, where relative `files` paths go |
| `~/.local/share/caboose/apps/<id>/web/` | Local WebKitGTK `localStorage`, IndexedDB and cookies |
| `~/.local/share/caboose/apps/<id>/icon.svg` | The monogram icon, for an app without one |
| `~/.local/share/caboose/apps/<id>/console.log` | The page's console messages and errors and the runtime's own, from the current run (when not started from a terminal) |
| `~/.cache/caboose/apps/<id>/` | Its web cache |

The desktop entry is what puts the app in the Apps screen: the host's `/v1/apps` lists the
entries under `~/.local/share/applications`, and `/v1/apps/:id/launch` runs its
`Exec=/usr/local/bin/caboose-app run <id>`. The window's Wayland `app_id`, X11 class and
GApplication id are all `caboose.app.<id>`, the entry's name, so Caboose shows the window
with the entry's icon. One instance runs per app per seat: a second `run` raises the open
window.

## The runtime

- **Content.** The page is served from `caboose-app://<id>/` by a custom URI scheme handler
  that answers only for the app's own id, and only with regular files whose real path,
  after percent-decoding and resolving symlinks, is inside `~/Apps/<id>/`. Paths with `.`
  or `..` parts, encoded slashes or NUL are refused. Responses are not cached.
- **Policy.** Every response carries the content security policy in `appcore.CSP`, and every
  HTML page also gets it as its first `<head>` element, so it holds whether or not the
  engine applies a custom scheme's headers. Script runs only from the app's own files: no
  inline script, handler attributes, `javascript:` URLs, `eval`, or `blob:` and `data:`
  scripts; WebAssembly compiles. Frames hold only the app's own pages. Styles, fonts,
  images, media and connections may come from anywhere. `check` and `publish` reject pages
  with inline script, handler attributes or `javascript:` URLs, naming file and line.
- **Input checks.** `check`, `publish` and `list` include nonfatal `warnings` for a valid
  app's entry page when its viewport is missing, duplicated, differs from device-width
  with initial scale 1, or restricts zoom. Reading is bounded to 4 MiB and refuses
  symlinks. The checker never edits app files or storage. MCP `app_publish` returns the
  warnings too. These static hints do not establish working buttons or phone gestures;
  the generation guide specifies pointer, text, scroll and persistence acceptance checks.
- **Navigation.** The top frame stays on the app. A link to a web, mail or phone URL that
  the person followed opens in its default application; a redirect or a script-initiated
  navigation opens nothing; `javascript:`, `data:` and `file:` URLs never open. Permission
  requests (camera, microphone, location, web notifications) are denied. Responses the view
  cannot show are not downloaded.
- **Bridge.** `window.caboose` is injected into the top frame only. Calls are window
  messages to `world.js`, which runs in the script world `caboose` in the top frame only
  and is the only code that can reach the `caboose` message handler. It relays only
  messages whose source is the top window itself, tagged with a random per-document token.
  The runtime answers a token only while that document is the one shown: the first token
  after a load commits is admitted and any other is refused. A request whose capability
  `app.json` does not declare is refused. Capabilities are read once, when the app starts.
- **Programs.** `exec` and `spawn` take an argv list (at most 256 arguments, 128 KiB each,
  1 MiB in all), an environment of at most 64 variables, and a working directory under the
  home; there is no shell unless the app runs one. `exec` keeps at most 16 MiB of each
  output stream and kills the program at `timeoutMs` (default 60 s, at most 10 min); its
  `stdin` is written without blocking under the same deadline, so a program that never
  reads its input still times out. `process.write` gives a spawned program 30 s to take
  its input, and writes to one program never interleave. At
  most 16 programs run per app. Each starts its own process group; only those groups are
  ever signalled. When a new document commits, the old document's programs get SIGTERM,
  then SIGKILL after 2 s; when the app quits, all of them do. Nothing is re-run.
- **Files.** A bridge path is absolute under the home, `~/…`, or relative to the app's
  `files` directory. Every directory on the way is opened with `O_NOFOLLOW` below its
  parent's descriptor, and the last part is read, written, listed or removed through that
  descriptor, so a symlink cannot redirect the operation, even one swapped in between check
  and use. A write goes to a new file in the same directory and is renamed over the target,
  so it replaces a symlink rather than following it. Reads and writes are at most 64 MiB.
- **Live reload.** The runtime watches `~/Apps/<id>/` (not dot directories or
  `node_modules`) and reloads the page 300 ms after a change, so an agent sees its edits. A
  reload is a new document: the old one's programs end and its requests are not repeated.
  A changed capability list is logged and takes effect the next time the app starts.
- **Rendering.** On a computer without a render node, `WEBKIT_DISABLE_DMABUF_RENDERER=1`
  is set unless already set, so WebKit uses the shared-memory renderer that every
  compositor shows. `CABOOSE_APP_INSPECTOR=1` enables the Web Inspector.

- **Network.** An app that declares `net` gets a network origin: a loopback HTTP server
  (`net.py`) that only this run of the app knows, `http://127.0.0.1:<port>/<token>/`.
  `<base><scheme>/<authority><path>?<query>` is requested from `<scheme>://<authority>…`
  with curl: the page's method, body and headers (less those describing its own connection
  to the origin, such as `Host`, `Origin`, `Cookie` and `Sec-*`; `X-Caboose-Header-<name>`
  sends `<name>`, which `caboose.fetch` uses for headers script may not set), following up
  to 10 redirects and decoding compressed bodies. The answer streams back with its status
  and headers, less hop-by-hop fields, `Set-Cookie` (sent as `X-Caboose-Set-Cookie`) and the
  remote site's security policies, plus `Access-Control-Allow-Origin` for the app's page and
  `X-Caboose-Url`, the final URL. A request whose `Origin` is not the app's is refused (403);
  one without an `Origin`, as media elements and images send, is admitted by the token. An
  unreachable server is a 502 with `X-Caboose-Error`. Bodies are at most 64 MiB, at most 64
  requests are open at once, and curl keeps no cookies. The network origin is not the app's
  origin, so what comes through it is never the app's script: the content policy's `'self'`
  does not cover it. It ends with the app.

What this protects is the boundary with the web, not the owner from the app: the app's own
code runs as `caboose` with everything its capabilities give it: `exec` gives a terminal's
authority, and `net` reaches whatever the machine running the page can. Agents write apps
in the owner's home, where the owner can read and remove them.

## Native handoff

An app opts in with `"handoff": "files"` in `app.json`: it keeps all persistent state in
`caboose.files`, so its computer and device views see the same state. Apps without this
opt-in run in WebKitGTK. Browser storage (localStorage, IndexedDB and cookies) is not
transferred between the device and computer; it must not hold state the opted-in app needs
when it falls back. On the device, the app has a stable per-computer, per-app loopback origin
and a persistent WebKit data store. If its origin cannot be opened, the app returns to the
computer. The agent seat and displays without a handoff client run locally.

The launcher connects to the display's game socket and binds to its own window. The client
receives a random instance identifier and a fresh display-session grant over its authenticated
display connection. A private socket in the guest handles the bridge; the host's authenticated
`POST /v1/webview/<instance>/bridge` relays to it through the authenticated guest file
service. The guest checks the grant and the current document revision, then dispatches through
the app's startup capability set. The owner token stays in native code. A takeover changes
the grant; a replaced or inactive document's processes are terminated. The client polls for
spawn output and reloads, and no request is replayed after a disconnect. If the socket or
client goes away, the local WebKit view starts in the same window.

The device serves `net` itself, on its own loopback port under the same contract, so the
requests go out from the device and need no computer. When Caboose leaves the screen, a page
that is playing media (`WKWebView`'s media playback state) is kept running instead of
closing with the display connection; WebKit's Media Session support gives it the system's
media controls. Its computer bridge is cut, and its calls fail, until the computer announces
the app again: the kept page then takes the new announcement's place without a reload and
registers again over the new grant. Once the computer has announced its apps without that
one, the page ends. At most four pages are kept. See
[docs/architecture.md](../../docs/architecture.md#agent-apps).

The device origin serves only the app directory through the host's fenced file service, with
a content security policy and an isolated top-frame bridge. `caboose.open` file targets use
the computer's default handler and follow symlinks; the `caboose.files` operations do not.

## `caboose-apps` (MCP)

`caboose-agentd` passes `apps-mcp.mjs` to every agent as the `caboose-apps` stdio server,
with the agent seat's launch environment, when `/opt/caboose/apps/apps-mcp.mjs` exists
(`CABOOSE_APPS_MCP` overrides the path).

| Tool | Arguments | Does |
| --- | --- | --- |
| `app_guide` | — | Returns [guide.md](guide.md) |
| `app_publish` | `id` | `caboose-app publish`; a tool error lists every problem to fix |
| `app_list` | — | `caboose-app list` |
| `app_open` | `id` | Checks the app and starts `caboose-app run` on the agent seat, with accessibility on, so the agent can see it with `screenshot` and `elements` |
| `app_remove` | `id`, `purge?` | `caboose-app remove` |

`CABOOSE_APP_RUNTIME` overrides the `caboose-app` it runs.

## Install

`guest/components/install.sh` installs `gir1.2-webkit2-4.1` and `curl` and runs `install.sh`,
in both image builds and on existing computers when the host updates their components. The files
are replaced atomically; an open app keeps the code it loaded.

## Test

```sh
python3 -m unittest discover -s guest/apps -p 'test_*.py'   # appcore, net (with curl)
node --test guest/apps/apps-mcp.test.mjs guest/apps/agent-page.test.mjs  # MCP and page relay
guest/apps/check-runtime.sh                                 # the runtime, in Docker
guest/apps/check-handoff.sh                                # handoff, bridge and fallback in Docker
```

`check-runtime.sh` builds a Debian 13 image with Xvfb, WebKitGTK 4.1, GStreamer's good
plugins and curl and runs `check/run.sh` in it; `sudo bash check/run.sh` runs the same check
inside a Caboose computer, on its own display `:150`, session bus and throwaway home. Its probe app
(`check/probe`) asserts that publish writes the entry and refuses inline script; that
inline, `data:`, `blob:`, `eval` and `Function` script and remote frames are blocked by the
policy; that `exec` returns code and output, times out (also while a program leaves a
large input unread) and refuses a non-list argv; that an
undeclared capability and a path outside the home are refused; that `spawn` streams; that
script navigation away is refused and a frame's forged request is ignored; that a classic
script runs and a page without `<meta charset>` decodes as UTF-8; that an edit
reloads the page, ending the old page's programs (including an exec whose input is
blocked) and keeping its storage; that a page `fetch` from a server without CORS consent
fails while `caboose.fetch` reads it with its method, body and reserved headers and reports
the final URL, an image and an audio element's stream load through `caboose.net.url` and
an unreachable server is a 502; that a second
launch raises the first; that quitting ends every program; and that storage survives a
restart.

The apps MCP keeps the task runner's HOME when opening a Caboose app on the agent seat,
so `~/Apps` and each app's existing data remain shared. It still uses the agent display,
session bus and GUI isolation environment; browser/editor profiles remain seat-specific.
