# Flatpak

Flathub in every computer, and the computer's view of the host's shared runtimes
(`docs/architecture.md` § Catalog and § Runtime depot). `guest/components/install.sh` installs
Flatpak, its introspection bindings (`gir1.2-flatpak-1.0`) and bubblewrap, then runs
`install.sh` here with its mode; only the container modes install `caboose-bwrap`.

| File | What |
| --- | --- |
| `install.sh` | Adds the Flathub remote to the system installation, the depot's installation and its mount. |
| `flathub.flatpakrepo` | Flathub's repository file as Flathub publishes it, with its signing key, so trusting Flathub fetches nothing. |
| `caboose-depot.conf` | `/etc/flatpak/installations.d/caboose-depot.conf`: the read-only installation at `/var/lib/caboose/depot`. |
| `caboose-bwrap` | In a container computer, `/usr/bin/bwrap` (the real one is diverted to `bwrap.distrib`): each sandbox gets the container's `/proc` read-only, without bubblewrap's sysctl lock on user namespaces, and root's sandboxes start in a user namespace of their own (`docs/architecture.md` § Catalog). Every other argument passes through. |
| `caboose-steam-defaults` | `/usr/local/libexec/caboose-steam-defaults`: Steam's defaults on a Caboose computer, written to Steam's `config.vdf` (Flatpak and native) while Steam is not running. Container computers run it as the owner when their session starts (`caboose-session start`). Shader pre-caching is off (`DisableShaderCache`): Steam would compile a game's recorded pipelines for the computer's own driver before launch, work a game rendering on the phone's GPU never uses. Games whose videos Steam delivers re-encoded for Proton through pre-caching play their original videos. `test_steam_defaults.py` tests it. |
| `caboose-steam-adopt` | `/usr/local/bin/caboose-steam-adopt APPID`: makes a Steam game whose `steamapps/common/<dir>` links to read-only files (another library's, shared between computers) a normal install that takes updates and DLC. Run as the owner while Steam is not running: it copies the linked tree into the library as a real directory (with `copy_file_range`, which shares blocks on XFS or Btrfs), keeps the link as `<dir>.farm` and the manifest in `Steam/caboose-adopted/`, and marks the game update-required, so Steam validates it against its depots at its next start and downloads what is missing. `--keep-dlc ID,…` records only the base depots and those DLC as installed and asks for those DLC; `--skip DIR,…` leaves out top-level directories of DLC not kept. A container cannot mount an overlay Steam's sandbox would see, so the game is copied. The game's Proton prefix is marked as having run DirectX's Common Redistributable step (`HKLM\Software\Valve\Steam\Apps\CommonRedist\DirectX\Jun2010`, `dxsetup`, both registry views): a real install gets the Common Redistributables the link never had, and under Proton `DXSETUP.exe /silent` has nothing to install and can wait forever. `test_steam_adopt.py` tests it. |
| `var-lib-caboose-depot.mount` | In a microVM, mounts the host's virtio-fs tag `caboose-depot` read-only at `/var/lib/caboose/depot`. Without the tag the mount fails without delaying boot. |

`install.sh` also shares `~/.local/state/caboose/game-diagnostics` into Steam's sandbox
(`com.valvesoftware.Steam`), which otherwise has no `~/.local/state`. A game launched with
the launch options `PROTON_LOG=1 PROTON_LOG_DIR=/home/<user>/.local/state/caboose/game-diagnostics %command%`
writes its Proton log, `steam-<appid>.log`, there, and the log stays after the game exits.

On the container runtime the host mounts the `caboose-depot` volume at the same path instead.
Apps install into the system installation (`/var/lib/flatpak`); the Library's installer adds the
depot as each transaction's dependency source, so an app whose runtime the depot has installs
alone. With no depot mounted, an app's runtime installs into the system installation as well.
Flatpak exports its apps' desktop entries and icons under `/var/lib/flatpak/exports/share`,
where the host's app listing finds them.

`apps/host/scripts/check-flathub.sh` exercises the remote, the depot and an install, run and
removal in disposable containers (see the host README).

`check-portal.py APP_ID --outer-seccomp` runs as the computer's unprivileged user under
`dbus-run-session`. It checks the outer container's exact `setns` type restrictions,
portal subprocesses with both `--sandbox --expose-pids` and `--sandbox --share-pids`,
exit-status propagation, and the inner Flatpak seccomp denials in the app and its children.
The installed app's runtime must include Python 3 and `flatpak-spawn`. Omit
`--outer-seccomp` when checking portal behavior in a microVM. `check-flathub.sh` runs
this check in its disposable guest; it needs no Steam account or graphical session.
