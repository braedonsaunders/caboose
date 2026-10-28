# Phone handoff in the guest

`install.sh` installs `caboose-open`, `caboose-share`, the phone URL desktop handler,
Thunar's **Share to iPhone** custom action, and an `iPhone` CUPS queue. Both guest image
builders install it. It can also be run as root on an existing Debian guest with an
existing `caboose` user. Log in again or restart Thunar to reload custom actions; a user's
own MIME defaults may override the system defaults.

```
caboose-open 'mailto:person@example.com'
caboose-open 'https://example.com/'
caboose-share ~/Pictures/photo.png
lp -d iPhone ~/Documents/report.pdf
```

The printer uses Debian cups-filters' generic PDF PPD with its PJL wrapper removed. CUPS
converts supported inputs to PDF, then the root backend stages the result as user caboose.
This works independently of Xpra and Caboose Display. The container starts CUPS and
configures the queue at owner-display startup; the microVM uses the installed systemd unit.
Files must be regular and no larger than 10 MiB. The host and phone protocol, expiry,
confirmation and delivery limits are in `../../docs/architecture.md` § iOS weave.

For a scripted check on a disposable guest, run `sudo bash guest/phone/check.sh` after
installation. It starts CUPS if necessary, configures the printer, checks MIME handlers,
queues a sample URL and file, prints a PDF, and drains the guest handoff queue to verify
all three events. Disconnect phone control clients first: the check consumes pending
handoffs, so do not run it with requests you want to keep. It creates a real CUPS job.
This can also be run in a disposable Debian 13 container with the source mounted at
`/src`, a `caboose` user created, and `bash /src/install.sh` run first. Full share-sheet,
AirPrint and background behavior requires the paired iOS device and a real computer;
follow the checks in `apps/ios/README.md`.
