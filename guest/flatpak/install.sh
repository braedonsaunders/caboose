#!/bin/sh
# Installs Flathub and the shared runtime depot's configuration (docs/architecture.md
# § Catalog). Flatpak and its introspection bindings come from guest/components/install.sh.
set -eu
here=$(dirname "$0")
mode=${1:?expected image-vm, image-container, vm or container}
install -Dm644 "$here/flathub.flatpakrepo" /usr/share/caboose/flathub.flatpakrepo
# The pinned repository file carries Flathub's signing key; nothing is fetched to trust it.
flatpak remote-add --system --if-not-exists flathub /usr/share/caboose/flathub.flatpakrepo
install -d -m 0755 /var/lib/caboose/depot
install -Dm644 "$here/caboose-depot.conf" /etc/flatpak/installations.d/caboose-depot.conf
if [ -d /etc/systemd/system ]; then
  install -m 0644 "$here/var-lib-caboose-depot.mount" /etc/systemd/system/var-lib-caboose-depot.mount
fi
if [ "${mode#*container}" != "$mode" ]; then
  # In a container, every bubblewrap sandbox goes through Caboose's wrapper (caboose-bwrap).
  if [ "$(dpkg-divert --truename /usr/bin/bwrap)" = /usr/bin/bwrap ]; then
    dpkg-divert --local --rename --divert /usr/bin/bwrap.distrib --add /usr/bin/bwrap
  fi
  install -m 0755 "$here/caboose-bwrap" /usr/bin/bwrap
fi
