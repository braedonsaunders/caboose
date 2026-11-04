# Caboose WebMCP

Page tools for the agent seat. A page declares tools for agents with WebMCP
(`document.modelContext.registerTool`, or a `<form toolname tooldescription>` with
`toolparamdescription` on its fields); desktop MCP lists the focused tab's tools in `look`
and calls them with an `act` step `{"tool": name, "args": {...}}`. Every page also offers
tools derived from its own semantics: one per form (`form_<name>`: its fields are the
parameters, it fills them and presses the form's button; `submit: false` only fills), and
`follow_link` and `press_button` for its links and its buttons outside forms. Derived tools are
marked `[derived]` in `look`.

| File | Does |
| --- | --- |
| `page.js` | In the page's own JavaScript world from document_start: lists and runs the page's declared tools through `document.modelContext` (Chromium's WebMCP; where the browser has none, this file provides `registerTool`, `getTools` and `executeTool` itself), and derives and runs the general ones |
| `content.js` | Carries requests from the service worker to `page.js` over window messages, and the replies back |
| `service-worker.js` | Holds the native messaging connection, asks the browser's active tab, and works the tabs (`chrome.tabs`; `evaluate` through the DevTools protocol, `chrome.debugger`, attached for the one command) |
| `caboose-webmcp-host.py` | Native messaging host `com.caboose.webmcp`: listens on `$XDG_RUNTIME_DIR/caboose-webmcp/<browser pid>.sock` (0600, in a 0700 directory) for desktop MCP, one JSON request per line (`{"op": "tools"}`, `{"op": "call", "name", "args"}`, or `{"op": "browser", "name", "args"}` for the tabs: `tabs`, `activate {index}`, `open {url, new_tab?}`, `evaluate {expression}`), one JSON reply per line (`{"ok", "result" \| "error"}`) |
| `zz-caboose-agent` | `/etc/chromium.d` file: on the agent seat (`CABOOSE_SEAT=agent`), Chromium starts with `--force-renderer-accessibility`, `--enable-features=WebMCPTesting` (Chromium's WebMCP with its tool listing and calls), `--silent-debugger-extension-api` (no debugging bar over the page while `evaluate` runs) and this extension |
| `install.sh` | Installs the extension into `/opt/caboose/webmcp`, the host's manifest into `/etc/chromium/native-messaging-hosts`, and the flags file; `guest/components/install.sh` runs it |

Desktop MCP finds a window's host by the window's process, which is the browser that started
the host, so it only ever reaches the agent seat's own browser. Only the active tab of the
browser's last focused window answers. The extension does not run on `file://` pages (an
unpacked extension has no file access by default) or on Chromium's own pages. Nothing is
loaded on the owner's seat.

## Test

`python3 -m unittest guest/webmcp/test_webmcp.py` checks that the extension id in
`install.sh` follows from the manifest's key, that the manifest's files exist, and the host's
socket protocol and framing against a stand-in browser. On a computer, with Chromium open on
the agent seat at a page served over HTTP, `look` lists the page's tools and an `act` tool
step returns the tool's result; `guest/desktop-mcp/bench` has WebMCP tasks.
