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
| `package/` | Debian trixie's Flatpak rebuilt with `glnx-chase-eagain.patch` (below): `build-in-debian.sh` builds it inside a trixie system (the image builds' `flatpak` stage), `build.sh` in a Docker container, `check-merge-dirs.sh` checks it in a running computer. |
| `var-lib-caboose-depot.mount` | In a microVM, mounts the host's virtio-fs tag `caboose-depot` read-only at `/var/lib/caboose/depot`. Without the tag the mount fails without delaying boot. |

Computers run Debian's Flatpak 1.16.6 rebuilt as `<Debian's version>+caboose1` with one change
from upstream libglnx (`eef7f14c`, in Flatpak 1.18.2 and later): it retries `openat2` when the
kernel answers `EAGAIN`. Flatpak resolves an extension's merge directories (the GL extension's
`vulkan/icd.d` and the rest) with `openat2(RESOLVE_BENEATH)`, which fails with `EAGAIN` when
any mount or rename happens during the lookup, and 1.16.6 then refuses to start the app
(`Extension org.freedesktop.Platform.GL.default has invalid merge-dirs`). Over the microVM's
virtio-fs depot a lookup takes host round trips, so starting apps while others start (Steam
and a game, several apps at once) hits it often. The image builds install the packages from
`debs/`; `install.sh` never puts them over a newer Debian version, which is then rebuilt with
the patch. A computer made before them gets them from its release or by installing
`build.sh`'s output. `package/check-merge-dirs.sh` starts an app many times at once while
other sandboxes mount and fails on any start that exits non-zero.

On the container runtime the host mounts the `caboose-depot` volume at the same path instead.
Apps install into the system installation (`/var/lib/flatpak`); the Library's installer adds the
depot as each transaction's dependency source, so an app whose runtime the depot has installs
alone. With no depot mounted, an app's runtime installs into the system installation as well.
Flatpak exports its apps' desktop entries and icons under `/var/lib/flatpak/exports/share`,
where the host's app listing finds them.

A container computer is created with `/dev/fuse` and mounts FUSE itself, with the package's
`fusermount3` (docs/architecture.md § FUSE); FUSE carries the document portal's
`/run/user/1000/doc`, through which a sandboxed app receives the files chosen for it. On every
computer the agent seat's bus gets `caboose-documents-forwarder` as its document portal
(`/opt/caboose/agent-services.d`, read by `keyring/install-services.py`): it forwards to the
owner bus's one portal, so both seats' sandboxes find their documents at the same path.

`apps/host/scripts/check-flathub.sh` exercises the remote, the depot and an install, run and
removal in disposable containers (see the host README).

`check-portal.py APP_ID --outer-seccomp` runs as the computer's unprivileged user under
`dbus-run-session`. It checks the outer container's exact `setns` type restrictions,
portal subprocesses with both `--sandbox --expose-pids` and `--sandbox --share-pids`,
exit-status propagation, and the inner Flatpak seccomp denials in the app and its children.
The installed app's runtime must include Python 3 and `flatpak-spawn`. Omit
`--outer-seccomp` when checking portal behavior in a microVM. `check-flathub.sh` runs
this check in its disposable guest; it needs no Steam account or graphical session.
