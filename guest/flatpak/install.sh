#!/bin/sh
# Installs Flathub and the shared runtime depot's configuration (docs/architecture.md
# § Catalog). Flatpak and its introspection bindings come from guest/components/install.sh.
set -eu
here=$(dirname "$0")
mode=${1:?expected image-vm, image-container, vm or container}
# The computers' Flatpak (package/, README.md): Debian's, rebuilt with the retry the depot over
# virtio-fs needs. An image build stages it in debs/; it never replaces a newer Debian version.
for deb in "$here"/debs/flatpak_*.deb; do
  [ -f "$deb" ] || break
  staged=$(dpkg-deb -f "$deb" Version)
  installed=$(dpkg-query -W -f='${Version}' flatpak 2>/dev/null || :)
  if [ -z "$installed" ] || dpkg --compare-versions "$staged" gt "$installed"; then
    apt-get install -y -q --no-install-recommends "$here"/debs/*.deb >/dev/null
  fi
done
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
  # The computer mounts FUSE itself (docs/architecture.md § FUSE): fusermount3 is the
  # package's, and the document portal's D-Bus service too.
  if [ "$(dpkg-divert --truename /usr/bin/fusermount3)" != /usr/bin/fusermount3 ]; then
    rm -f /usr/bin/fusermount3
    dpkg-divert --local --rename --remove /usr/bin/fusermount3
  fi
  rm -f /opt/caboose/flatpak/caboose-fuse-broker
  documents=/usr/share/dbus-1/services/org.freedesktop.portal.Documents.service
  if [ "$(dpkg-divert --truename "$documents")" != "$documents" ]; then
    rm -f "$documents"
    dpkg-divert --local --rename --remove "$documents"
  fi
fi
# One document portal serves the user, on the owner's bus, at the /run/user/<uid>/doc every
# sandbox expects; the agent seat's bus forwards to it (keyring/install-services.py takes the
# agent seat's activation files from /opt/caboose/agent-services.d).
install -Dm755 "$here/caboose-documents-forwarder" /opt/caboose/flatpak/caboose-documents-forwarder
install -Dm644 "$here/org.freedesktop.portal.Documents.agent.service" /opt/caboose/agent-services.d/org.freedesktop.portal.Documents.service
