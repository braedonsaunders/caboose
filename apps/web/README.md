# Caboose console

The web console a self-hosted `caboose-host` serves on its own port: sign in with the
owner token, then see and manage the computer.

- **Overview** — state, the resources the computer is running with, connected screens
  and working agents; Wake, Park now and Restart (confirmed first); a restart-required
  notice when saved memory or vCPUs wait on a cold boot; the last lifecycle error; and
  the `caboose://connect` link that signs an iPhone in to this host.
- **Settings** — name, memory, vCPUs and auto-park, validated against the host's
  `limits`. Edits made from another device are followed unless there are unsaved
  edits here; "Save and restart" applies new resources in one step.
- **Agents** — start a Claude Code or Codex task, and pause, resume or cancel tasks.

It is built on AppKit (`appkit-ui` for the shell, settings layout, forms, confirm
dialog and toasts; `appkit-dashboard` for metric cards and panels). It talks only to
the documented `/v1` API (see `docs/architecture.md`): the token lives in session
storage for the tab and is sent as `Authorization: Bearer`, never in a URL. Status and
tasks are polled over HTTP, which holds no lease, so an open console never keeps the
computer awake.

## Develop

From the repository root, `pnpm install`, then run a host (see `apps/host/README.md`) and:

```sh
pnpm --filter caboose-web dev        # Vite on :5173, proxying /v1 to CABOOSE_API_URL (default http://127.0.0.1:7310)
```

## Test and build

```sh
pnpm --filter caboose-web typecheck
pnpm --filter caboose-web test
pnpm --filter caboose-web build      # apps/web/dist, which caboose-host serves (CABOOSE_WEB_ROOT)
```

To check the real thing without a VM, start the host on any machine with the built
console and open it: `GET /v1/computer` and every page work while the computer is
parked; Wake, Park and Restart need a host with KVM and a guest image.
