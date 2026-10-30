# Native bridge (guest)

The computer's side of the native bridge ([docs/native-bridge.md](../../docs/native-bridge.md)):
Linux applications choose files with the phone's pickers, follow the phone's appearance,
show their media in the phone's Now Playing, and read the phone's location when the owner
shares it; `caboose-scan` scans a document with the phone.

| File | What |
| --- | --- |
| `caboose-portal` | The xdg-desktop-portal backend `org.freedesktop.impl.portal.desktop.caboose`: `FileChooser` (answered from the phone, or by `xdg-desktop-portal-gtk`) and `Settings` (`org.freedesktop.appearance`, `org.gnome.desktop.interface`, `org.gnome.desktop.wm.preferences`). D-Bus activated on each seat's session bus. |
| `caboose-bridge` | The host's commands (`drain`, `respond`, `appearance`) and the owner seat's daemon (`daemon`): MPRIS to `now-playing.json` and commands back, the appearance in GTK's `settings.ini` for X11 applications, and the display's environment for D-Bus-activated services. |
| `caboose-scan` | `caboose-scan [--format pdf\|jpeg] [--output PATH]`: the phone scans a document; prints each file's path. |
| `bridgecore.py` | Validation and the logic both share, without D-Bus. |
| `caboose.portal`, `org.freedesktop.impl.portal.desktop.caboose.service` | The backend's portal registration and D-Bus activation. |
| `portals.conf` | `/etc/xdg/xdg-desktop-portal/portals.conf`: Caboose for FileChooser and Settings, GTK for the rest. |
| `firefox-portal.js` | Firefox ESR uses the portal for its file picker, appearance and location. |
| `geoclue.conf` | `/etc/geoclue/conf.d/90-caboose.conf`: GeoClue's static source, and the portal and Firefox allowed without a GeoClue agent. |
| `caboose-bridge.service` | The daemon on the owner's seat, wanted by and part of `caboose-display.service`. |
| `install.sh` | Installs the above into `/opt/caboose/bridge`, `/usr/local/bin/caboose-bridge`, `/usr/local/bin/caboose-scan` and the system locations. |
| `selftest.py`, `check.py`, `check.sh` | Tests (below). |

## Install

The bridge is a guest component: `guest/components/install.sh` adds its Debian
dependencies (`xdg-desktop-portal`, `xdg-desktop-portal-gtk`, `geoclue-2.0`), runs
`install.sh` and, in the microVM, enables `caboose-bridge.service`. In the container
`caboose-session start` starts the daemon with the owner's display, and a components
update restarts it. Computers made before the bridge get it with the next components
update, as every component does.

Applications started on a seat get `GTK_USE_PORTAL=1` from its launch environment
(caboose-display), so GTK 3 uses the portal's file chooser and, on Wayland, reads its theme
and text size from the portal's Settings. `/etc/environment.d/91-caboose-portal.conf` sets
the same for services the systemd user manager starts.

## Configuration

None. Phone presence, the appearance and file requests live in
`/home/caboose/.cache/caboose/bridge/`, private to the owner; Now Playing in
`/home/caboose/.cache/caboose/now-playing.json`. The location is `/etc/geolocation`,
written by the host.

## What follows the phone

- **File choosing** for applications that use the FileChooser portal, from the phone's
  Files, Photos, camera or document scanner: GTK 4, GTK 3 applications that use
  `GtkFileChooserNative`, Chromium and Electron applications such as VS Code, and Firefox. Applications that draw their own dialog (GTK 3's
  `GtkFileChooserDialog`, Qt through its GTK platform theme, LibreOffice's GTK 3 dialogs)
  keep it.
- **Appearance** live for Wayland GTK and libadwaita applications and for applications
  that read `org.freedesktop.appearance` (Chromium, Firefox, Electron); X11 GTK
  applications follow from their next start. Light mode uses WhiteSur-Light where the image
  has it and Adwaita otherwise; high contrast is reported through the portal's `contrast`
  for applications that honour it.
- **Now Playing** for any MPRIS player: Spotify, mpv, VLC, Rhythmbox, and web media in
  Chromium and Firefox.
- **Scanning** from a terminal or a script: `caboose-scan` shows the phone's document
  scanner and prints where the scan was saved (`~/Caboose Documents/<uuid>/`, or
  `--output`). PDF is the default; `--format jpeg` writes one image per page. It needs
  Caboose open and connected on the phone, and fails at once otherwise (status 3); a
  cancelled scan is status 1.
- **Location** for applications that ask GeoClue, directly or through the Location portal,
  in the microVM. GeoClue needs the system bus; in the container runtime it runs when the
  container's system bus can activate it.

## Test

- `python3 selftest.py` checks the shared logic anywhere, without D-Bus.
- `./check.sh`, as root on a running computer with the owner's display up, runs the
  self-test and then `check.py` on the owner's session bus: it sets the appearance and reads
  it back through the Settings portal, calls `OpenFile` and `SaveFile` through the portal
  while playing the host's part (drain and answer), runs `caboose-scan` the same way (and,
  with no phone connected, checks that it fails at once), and runs an MPRIS test player to check
  that it is published, takes a pause command and disappears when it goes.
