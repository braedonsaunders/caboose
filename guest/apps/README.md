# caboose-app

Apps that agents make. An agent app is a web app (HTML, CSS and JavaScript) in
`~/Apps/<id>/` that runs as a real application on the computer: its own window, its own
icon and name in the Apps screen, its own saved data, and, when its manifest declares
them, native capabilities through `window.caboose`. The owner opens it from the phone like
any Linux app. [guide.md](guide.md) is the format and API as agents read it.

| File | Is |
| --- | --- |
| `caboose-app` | The CLI and the runtime: a GTK 3 window around a WebKitGTK 4.1 view, in Python |
| `appcore.py` | Its logic that needs no display: manifests, URLs, desktop entries, the content policy, bridge bounds and file operations |
| `page.js` | `window.caboose`, injected into the app's top frame |
| `world.js` | The relay between the page and the native bridge, in its own script world |
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
| `~/.local/share/caboose/apps/<id>/web/` | Its `localStorage`, IndexedDB and cookies |
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
  output stream and kills the program at `timeoutMs` (default 60 s, at most 10 min). At
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

What this protects is the boundary with the web, not the owner from the app: the app's own
code runs as `caboose` with everything its capabilities give it, and `exec` gives a
terminal's authority. Agents write apps in the owner's home, where the owner can read and
remove them.

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

`guest/components/install.sh` installs `gir1.2-webkit2-4.1` and runs `install.sh`, in both
image builds and on existing computers when the host updates their components. The files
are replaced atomically; an open app keeps the code it loaded.

## Test

```sh
python3 -m unittest discover -s guest/apps -p 'test_*.py'   # appcore
node --test guest/apps/apps-mcp.test.mjs                   # the MCP server and the CLI
guest/apps/check-runtime.sh                                 # the runtime, in Docker
```

`check-runtime.sh` builds a Debian 13 image with Xvfb and WebKitGTK 4.1 and runs
`check/run.sh` in it; `sudo bash check/run.sh` runs the same check inside a Caboose
computer, on its own display `:150`, session bus and throwaway home. Its probe app
(`check/probe`) asserts that publish writes the entry and refuses inline script; that
inline, `data:`, `blob:`, `eval` and `Function` script and remote frames are blocked by the
policy; that `exec` returns code and output, times out and refuses a non-list argv; that an
undeclared capability and a path outside the home are refused; that `spawn` streams; that
script navigation away is refused and a frame's forged request is ignored; that an edit
reloads the page, ending the old page's programs and keeping its storage; that a second
launch raises the first; that quitting ends every program; and that storage survives a
restart.
