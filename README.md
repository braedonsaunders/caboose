<h1 align="center">Caboose</h1>

<p align="center"><strong>Your phone's computer.</strong><br />
A real Linux computer that lives on a server, wakes the moment you open it, parks
itself — every app still open — when you leave, and is shared by you and your
agents. On your iPhone it is not a remote desktop: each Linux app arrives as its
own native surface.</p>

<p align="center"><img alt="License: AGPL-3.0-or-later" src="https://img.shields.io/badge/License-AGPL--3.0--or--later-f5a623" />
<img alt="Status: pre-alpha" src="https://img.shields.io/badge/status-pre--alpha-ef4444" /></p>

---

## Why

Phones are the computer most people carry, and the least capable one they own.
Cloud desktops solve the capability and lose the phone: a picture of a desktop,
squeezed onto glass, driven by a fake mouse. Agent computers solve a different
problem: the machine belongs to the agent and you watch it.

Caboose starts from the other end. The computer is yours, it is persistent, and
it is woven into iOS:

- **Linux apps as native surfaces.** Every window streams on its own — title,
  icon, menus, dialogs — and the app shows it like an iOS app on iPhone and like a
  window on iPad or an external display.
- **Resumable.** Your computer parks with its memory. Reopen the app and every
  program is exactly where you left it.
- **Shared with agents, without fighting them.** Agents work on the same machine
  on their own seat, keep working when your phone is locked, and ask before they
  act.
- **Yours.** Open source, self-hostable, bring your own model keys. A hosted
  service runs the same code.

## Status

Pre-alpha, moving fast toward iteration 1: open the app, your computer wakes, tap
an app, use it. See [docs/architecture.md](docs/architecture.md) for the design
every component is built against.

## Layout

| Path | What |
| --- | --- |
| `apps/ios` | The iPhone/iPad app (Swift, SwiftUI + UIKit) and `CabooseKit`, its Xpra client |
| `apps/host` | `caboose-host`: accounts, computer lifecycle, display relay (TypeScript, AppKit) |
| `apps/web` | The self-host console the host serves: computer settings, park and restart, agents (React, AppKit UI) |
| `guest/image` | The golden machine image: Debian 13, Xpra seamless, apps, agent CLIs |
| `docs` | Architecture and decisions |

Caboose is built on [AppKit](https://github.com/braedonsaunders/appkit) —
notably `appkit-desk`, the Cloud Hypervisor microVM layer it shares with
[Bunkhouse](https://github.com/braedonsaunders/bunkhouse) — and contributes its
improvements upstream.

## License

[AGPL-3.0-or-later](LICENSE).
