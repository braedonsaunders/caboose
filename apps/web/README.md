# Caboose console

The web console for a self-hosted Caboose host. `caboose-host` serves the built console at
`/` on the same port as its API. Sign in with the owner token.

The console is for running the server, not for using the computer: that is the iPhone
app's job. Launching apps, agent tasks and choosing a default agent live in the app, and
the console does not repeat them.

- **Overview** — the host at a glance: what all the computers are given between them of the
  machine's memory and CPUs, free disk for their disks and snapshots, the computers with
  their state, size, connected screens and auto-park, and anything that needs attention (a
  missing `/dev/kvm`, a desk error, a computer's lifecycle error or failed guest-component
  update).
- **Computers** — every computer on the host, and **New computer**: a name, memory, vCPUs
  and auto-park, validated against the host's limits. A new computer is parked until it is
  first opened.
- **A computer** (`/computers/<id>`) — its state, size and Wake, Park now and Restart
  (confirmed first) above a tab for each thing an owner manages. Every request on these
  tabs goes to `/v1/computers/<id>/…`:
  - **Overview** — the resources it runs with, connected screens, auto-park, runtime,
    image and the state of the guest-component update; a restart-required notice when saved
    memory or vCPUs wait on a cold boot, and the last lifecycle error.
  - **Files** — browse its home folder (hidden files on request), download a file, upload
    into the folder you are in (a taken name becomes "name (2)", nothing is replaced),
    create a folder, rename, or move to the Trash. The folder is in the address
    (`/computers/<id>/files?path=…`), so back and forward work. File requests wake a parked
    computer, so a parked one is woken only when you ask.
  - **Apps** — the optional catalog: install, update, roll back or remove an app, or
    install a whole pack. Queued and running operations show their stage and progress, and
    failures show the installer's error. While the computer is parked the catalog shows
    what was installed when it last ran.
  - **Phones** — **Sign in a phone** shows a single-use pairing code as a QR code, a
    `caboose://connect?host=…&code=…` link and the code itself, counts down its ten minutes,
    and notices when a phone uses it. Below, the phones signed in to the computer, with when
    each was signed in and last used, and **Sign out** for each. Then the phones registered
    for push notifications, by a fingerprint of their token, with the kinds each one enabled
    and whether it uses APNs development or production; remove one. When the host has no
    APNs key it says how to configure one.
  - **Settings** — name, memory, vCPUs and auto-park, validated against the host's
    `limits`. Edits made from another device are followed unless there are unsaved edits
    here; "Save and restart" applies new resources in one step. Any computer but the owner's
    can be deleted here once its name is typed: its disk, files, phones and notifications go
    with it.
- **Host** — the host version, runtime, GPU, the machine's memory, CPUs and disk, image,
  health from `/v1/health`, push and Live Activities configuration, and the non-secret
  `CABOOSE_*` variables the host started with (`GET /v1/host`). These are read-only: they
  change by editing the host's environment and restarting it, which the page explains.

Addresses from earlier consoles (`/computer/…`, `/files`, `/apps`, `/devices`, `/settings`,
`/system`) are rewritten to the owner's computer, or the page that took them over.

The console is React on Vite, built on AppKit: `appkit-ui` for the shell, settings layout,
forms, tables, dialogs, progress, confirm and prompt dialogs and toasts, and
`appkit-dashboard` for metric cards and panels. QR codes are drawn by `qrcode-generator`. It talks only to the documented `/v1` API
([`docs/architecture.md`](../../docs/architecture.md)). The token lives in the tab's session
storage and is sent as `Authorization: Bearer`, never in a URL. Status and health are polled
over HTTP, which holds no lease, so an open console never keeps a computer awake.

Limitations: the console signs in with the owner token, so there are no accounts, people or
tenants yet; phones signed in with the owner token rather than a pairing code are not
listed, and only changing the token signs them out; a single large upload shows which file
is uploading but not its progress (the browser's `fetch` reports none); push registrations
are listed by fingerprint only; Live Activity registrations are not shown.
A download is held in the browser's memory before it is saved, because the token goes in a
header and a plain link cannot carry it.

## Brand

`src/brand/brand.ts` draws every Caboose logo from one set of numbers: the README
wordmarks and app icon in `.github/assets`, `public/favicon.svg`, and the console's
`<Wordmark>` component (`src/brand/Logo.tsx`), which renders the same SVG in the current
text colour. At rest the wordmark rides just clear of its rail, with no ties; the ties show
only while the train rolls three wheel-turns, which it does every 24 s. The sign-in page draws the
wordmark in and rolls it. The wordmark in the sidebar has its hubs lit while a computer is
up, and then rolls now and then; while every computer is parked its hubs are unlit and it
stays still. Loading states keep it rolling. Under reduced motion it is always still.
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

The unit tests cover settings validation, the session token and API client, navigation
(including the old addresses), the catalog and file helpers, host descriptions and the brand output. To try the built console against a real host, start `caboose-host` on any
machine and open it: sign-in, `GET /v1/computer` and every page work while the computer is
parked; Wake, Park and Restart need a host that can run the computer (KVM and a guest image,
or the container runtime).
