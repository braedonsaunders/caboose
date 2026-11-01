# Wine at the display's density

Wine takes its DPI from each prefix's registry (`HKCU\Control Panel\Desktop\LogPixels`,
96 when absent), not from X11, so on a phone display at scale 3 every Wine and Proton
window, dialogs and launchers included, was a third of the size of the computer's other
windows. `caboose-wine-dpi` follows the owner display's density, the XSETTINGS `Xft/DPI`
that caboose-display publishes for X11 clients ([x11_scale.rs](../display/compositor/src/x11_scale.rs)),
and writes it as `LogPixels` (96 × scale, at most 480) into `~/.wine` and winetricks'
prefixes (`~/.local/share/wineprefixes/*`).

Steam games' Proton prefixes (`steamapps/compatdata/*/pfx`, in every library Steam's
`libraryfolders.vdf` names, for the Flatpak's Steam and native Steam) are kept at 96. Wine
shows a program that does not declare itself DPI-aware a screen smaller by the DPI's
factor, and a game checks that screen against its minimum resolution: Halo: The Master
Chief Collection refused to run on a 1338x911 display at 192 DPI, which it saw as 669x455.

On a display smaller than 1280x720 on either side, the least games commonly require (a
phone in portrait), each Steam game's prefix also runs in a Wine virtual desktop
(`HKCU\Software\Wine\Explorer` `Desktop` and `Explorer\Desktops\Default`), landscape and at
least 1920x1080 (the display's own size where that is larger). Wine reports it as the
screen, so a game's minimum resolution holds. On a larger display the virtual desktop is
removed and games run on the display itself. caboose-display
holds the desktop window at that size and the phone shows it scaled to fit
([display.md](../../docs/display.md)). A full-screen game's swapchain covers the desktop and
renders on the phone's GPU; a windowed game inside the desktop does not cover it, and shows
the window's own pixels.

It writes when the density changes and checks every 10 s for new prefixes. A prefix gets
the setting once Wine has made its `user.reg`, so a game's very first launch runs at 96 DPI.
A running Wine keeps the value it read at start; a game the value changes under picks it up
at its next launch.

Wine scales the windows of programs that do not declare themselves DPI-aware, so their
dialogs become legible.

| File | Installed as | What it is |
| --- | --- | --- |
| `caboose-wine-dpi` | `/opt/caboose/wine/caboose-wine-dpi` | The service (Python 3 and GTK 3), run as the owner; `--once DPI` sets every prefix now and exits |
| `caboose-wine-dpi.service` | `/etc/caboose/services/` on container computers ([caboose-scopes](../scopes/README.md#services)), `/etc/systemd/system/` on microVMs | Its unit, started with the computer and restarted when it ends, as it does when the display's X server goes away |
| `install.sh` | | Run by `guest/components/install.sh` with its mode |
| `test_wine_dpi.py` | | Unit tests: `python3 -m unittest guest/wine/test_wine_dpi.py` |

The service waits for the owner display's launch environment
(`/run/caboose/display.env`) and connects to its Xwayland with `GDK_BACKEND=x11`. It logs
each prefix it changes to its service log (`caboose-scopes logs caboose-wine-dpi`).
