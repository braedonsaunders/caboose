# Flatpak

Flathub in every computer, and the computer's view of the host's shared runtimes
(`docs/architecture.md` § Catalog and § Runtime depot). `guest/components/install.sh` installs
Flatpak, its introspection bindings (`gir1.2-flatpak-1.0`) and bubblewrap, then runs
`install.sh` here.

| File | What |
| --- | --- |
| `install.sh` | Adds the Flathub remote to the system installation, the depot's installation and its mount. |
| `flathub.flatpakrepo` | Flathub's repository file as Flathub publishes it, with its signing key, so trusting Flathub fetches nothing. |
| `caboose-depot.conf` | `/etc/flatpak/installations.d/caboose-depot.conf`: the read-only installation at `/var/lib/caboose/depot`. |
| `var-lib-caboose-depot.mount` | In a microVM, mounts the host's virtio-fs tag `caboose-depot` read-only at `/var/lib/caboose/depot`. Without the tag the mount fails without delaying boot. |

On the container runtime the host mounts the `caboose-depot` volume at the same path instead.
Apps install into the system installation (`/var/lib/flatpak`); the Library's installer adds the
depot as each transaction's dependency source, so an app whose runtime the depot has installs
alone. With no depot mounted, an app's runtime installs into the system installation as well.
Flatpak exports its apps' desktop entries and icons under `/var/lib/flatpak/exports/share`,
where the host's app listing finds them.

`apps/host/scripts/check-flathub.sh` exercises the remote, the depot and an install, run and
removal in disposable containers (see the host README).
