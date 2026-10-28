# Caboose console

The web console for a self-hosted computer. `caboose-host` serves the built console at `/`
on the same port as its API: sign in with the owner token, then see and manage the computer.

- **Overview** — state, the resources the computer is running with, connected screens
  and working agents; Wake, Park now and Restart (confirmed first); a restart-required
  notice when saved memory or vCPUs wait on a cold boot; the last lifecycle error; and
  the `caboose://connect` link that signs an iPhone in to this host.
- **Settings** — name, memory, vCPUs, auto-park and the default agent, validated against
  the host's `limits`. Edits made from another device are followed unless there are unsaved
  edits here; "Save and restart" applies new resources in one step.
- **Apps** — open any app installed in the computer on its screen, and manage the optional
  catalog: install, update, roll back or remove an app, or install a whole pack. Queued and
  running operations show their stage and progress, and failures show the installer's error.
  While the computer is parked the catalog shows what was installed when it last ran.
- **Files** — browse the computer's home folder (hidden files on request), download a file,
  upload into the folder you are in (a taken name becomes "name (2)", nothing is replaced),
  create a folder, rename, move to the Trash, or open an item on the computer's screen. The
  folder is in the address (`/files?path=…`), so back and forward work. File requests wake a
  parked computer, so a parked one is woken only when you ask.
- **Devices** — the phones registered for push notifications, by a fingerprint of their
  token, with the kinds each one enabled (approvals, tasks, desktop) and whether it uses
  APNs development or production; remove one. When the host has no APNs key it says how to
  configure one.
- **System** — the host version, runtime, GPU, image, push and Live Activities
  configuration, health from `/v1/health`, the last lifecycle error, and the non-secret
  `CABOOSE_*` variables the host started with (`GET /v1/host`). These are read-only: they
  change by editing the host's environment and restarting it, which the page explains.
- **Agents** — pick any agent from the Agent Client Protocol registry (installed ones
  first), install or update it, sign in to it on the computer's screen or give it an API key
  (its environment in the computer; names are shown, values never), and start a task
  that can ask before acting (answered with Approve, the agent's always-allow option, or
  Deny on the task); pause, resume or cancel it, sign in from a task that found its agent
  signed out, and reply to a finished task to continue its conversation.

The console is React on Vite, built on AppKit: `appkit-ui` for the shell, settings layout,
forms, tables, progress, confirm and prompt dialogs and toasts, and `appkit-dashboard` for
metric cards and panels. It talks only to the documented `/v1` API
([`docs/architecture.md`](../../docs/architecture.md)). The token lives in the tab's session
storage and is sent as `Authorization: Bearer`, never in a URL. Status and tasks are polled
over HTTP, which holds no lease, so an open console never keeps the computer awake.

Limitations: a single large upload shows which file is uploading but not its progress (the
browser's `fetch` reports none); opening a file always uses the computer's default handler,
although `/v1/fs/open` accepts an `app`; phones are listed by fingerprint only, since the
host stores no name for them; Live Activity registrations and media handoff are not shown.
A download is held in the browser's memory before it is saved, because the token goes in a
header and a plain link cannot carry it.

## Brand

`src/brand/brand.ts` draws every Caboose logo from one set of numbers: the README
wordmarks and app icon in `.github/assets`, `public/favicon.svg`, and the console's
`<Wordmark>` component (`src/brand/Logo.tsx`), which renders the same SVG in the current
text colour. The sign-in page draws the wordmark in. The wordmark in the sidebar has its
hubs lit while the computer is up and unlit while it is parked. Loading states roll it.
The app icon and favicon are one of its wheels on navy. `brand.test.ts` holds the checked-in
files to the generator's output; after changing `brand.ts`, regenerate them with
`pnpm --filter caboose-web test -u`, then render the iOS icon with
`apps/ios/scripts/render-app-icon.sh`. The iOS app draws the same geometry natively in
`apps/ios/Caboose/Brand/CabooseBrand.swift`; keep the two in step.

## Develop

From the repository root, `pnpm install`, then run a host (see
[`apps/host/README.md`](../host/README.md)) and:

```sh
pnpm --filter caboose-web dev        # Vite on :5173, proxying /v1 to CABOOSE_API_URL (default http://127.0.0.1:7310)
```

## Test and build

```sh
pnpm --filter caboose-web typecheck
pnpm --filter caboose-web test
pnpm --filter caboose-web build      # apps/web/dist, which caboose-host serves (CABOOSE_WEB_ROOT)
```

The unit tests cover settings validation, the session token and API client, agent tasks,
navigation, the catalog and file helpers, host descriptions and the brand output. To try the built console against a real host, start `caboose-host` on any
machine and open it: sign-in, `GET /v1/computer` and every page work while the computer is
parked; Wake, Park and Restart need a host that can run the computer (KVM and a guest image,
or the container runtime).
