# Wine prefixes for the phone's display

Every Wine prefix is set up the same way. `caboose-wine-dpi` writes 96 DPI
(`HKCU\Control Panel\Desktop\LogPixels`) into each one: Wine then reports the display's
real pixels as the screen, which programs check against the resolution they need. On a
display smaller than 1280x720 on either side (a phone in portrait), each prefix also runs in
a Wine virtual desktop (`HKCU\Software\Wine\Explorer` `Desktop` and
`Explorer\Desktops\Default`), landscape and at least 1920x1080 (the display's own size where
that is larger), which Wine reports as the screen; on a larger display the virtual desktop is
removed. caboose-display holds the desktop window at that size and the phone shows it scaled
to fit ([display.md](../../docs/display.md)).

The prefixes are `~/.wine`, winetricks' (`~/.local/share/wineprefixes/*`) and every prefix a
running Wine process on the owner's display names in `WINEPREFIX` (a prefix running on another
seat follows that seat; processes on the agent seat, `CABOOSE_SEAT=agent`, whose windows desktop
MCP reads as they are, never count), which the service remembers in
`~/.local/state/caboose/wine-prefixes`. It checks every 10 s. A prefix gets the settings once
Wine has made its `user.reg`; a running Wine keeps the values it read at start and picks up a
change at its next launch.

| File | Installed as | What it is |
| --- | --- | --- |
| `caboose-wine-dpi` | `/opt/caboose/wine/caboose-wine-dpi` | The service (Python 3 and GTK 3), run as the owner |
| `caboose-wine-dpi.service` | `/etc/caboose/services/` on container computers ([caboose-scopes](../scopes/README.md#services)), `/etc/systemd/system/` on microVMs | Its unit, started with the computer and restarted when it ends, as it does when the display's X server goes away |
| `install.sh` | | Run by `guest/components/install.sh` with its mode |
| `test_wine_dpi.py` | | Unit tests: `python3 -m unittest guest/wine/test_wine_dpi.py` |

The service waits for the owner display's launch environment
(`/run/caboose/display.env`) and connects to its Xwayland with `GDK_BACKEND=x11`. It logs
each prefix it changes to its service log (`caboose-scopes logs caboose-wine-dpi`).
