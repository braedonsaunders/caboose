# Phone handoff in the guest

The guest half of opening, sharing and printing from Linux to the paired iPhone. Commands
queue owner-initiated handoffs in `~/.cache/caboose/phone`; caboose-host reads the queue as
`caboose` and relays each event to the phone's control socket (`docs/architecture.md`
§ Phone handoff has the schema, expiry, confirmation and delivery rules).

| File | Installed as | What |
| --- | --- | --- |
| `caboose-phone` | `/usr/local/bin/caboose-phone`, with `caboose-open` and `caboose-share` linked to it | Queues `phone.open` (http, https, mailto, tel, sms, facetime, facetime-audio, maps and geo URLs), `phone.share` and `phone.print` events. |
| `caboose-phone.desktop` | `/usr/local/share/applications/` | **Open on iPhone**, the default handler for the mailto, tel, sms, facetime, facetime-audio, maps and geo schemes (ordinary web links keep the browser). |
| `caboose-share.desktop` | `/usr/local/share/applications/` | **Share to iPhone** for files. |
| `uca.xml` | merged into `~/.config/Thunar/uca.xml` | Thunar's **Share to iPhone** custom action; the owner's other actions are kept. |
| `cups-backend` | `/usr/lib/cups/backend/caboose-phone` | The `iPhone` printer's backend: stages the PDF as `caboose` and queues `phone.print`. |
| `printer-setup`, `caboose-phone-printer.service` | `/usr/local/libexec/caboose-phone-printer-setup` and a systemd unit | Creates the `iPhone` CUPS queue. |

```sh
caboose-open 'mailto:person@example.com'
caboose-open 'https://example.com/'
caboose-share ~/Pictures/photo.png
lp -d iPhone ~/Documents/report.pdf
```

The printer uses Debian cups-filters' generic PDF PPD with its PJL wrapper removed, so CUPS
converts supported inputs to PDF before the backend runs. Files must be regular files of at
most 10 MiB. Queued requests and staged files older than 24 hours are removed.

## Install

`install.sh`, as root on a Debian guest with the `caboose` user, installs CUPS, cups-filters
and the files above, sets the scheme defaults in `/etc/xdg/mimeapps.list`, and enables
`cups.service` and `caboose-phone-printer.service`. It is part of the guest components
bundle (`guest/components`): both guest images run it, and the host runs it in existing
computers when the bundle changes. In the
container, `caboose-session start` starts CUPS and configures the queue. Log in again or
restart Thunar to load the custom action; a user's own MIME defaults override the system
defaults.

## Test

`check.sh`, as root in a guest where `install.sh` has run, starts CUPS if needed, configures
the printer, checks the scheme handlers, queues a URL and a file, prints a PDF through the
`iPhone` queue, and drains the handoff queue to verify all three events:

```sh
sudo bash guest/phone/check.sh                               # inside a microVM computer
docker exec -u root caboose-owner bash -s < guest/phone/check.sh   # in the container runtime
```

It creates a real CUPS job and consumes pending handoffs, so disconnect the phone first and
do not run it with requests you want to keep. It also runs in a disposable Debian 13
container with this directory mounted at `/src`, a `caboose` user created, and
`bash /src/install.sh` run first. The share sheet, AirPrint and background delivery need the
paired device; see the device checks in [`apps/ios/README.md`](../../apps/ios/README.md).
