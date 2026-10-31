#!/bin/sh
# Installs the native bridge (docs/native-bridge.md). Debian dependencies come from
# guest/components/install.sh.
set -eu
here=$(dirname "$0")
install -d -m 0755 /opt/caboose/bridge
install -m 0644 "$here/bridgecore.py" /opt/caboose/bridge/
install -m 0755 "$here/caboose-bridge" "$here/caboose-portal" "$here/caboose-scan" /opt/caboose/bridge/
ln -sf /opt/caboose/bridge/caboose-bridge /usr/local/bin/caboose-bridge
ln -sf /opt/caboose/bridge/caboose-scan /usr/local/bin/caboose-scan
install -Dm644 "$here/caboose.portal" /usr/share/xdg-desktop-portal/portals/caboose.portal
install -Dm644 "$here/org.freedesktop.impl.portal.desktop.caboose.service" /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.caboose.service
install -Dm644 "$here/portals.conf" /etc/xdg/xdg-desktop-portal/portals.conf
install -Dm644 "$here/geoclue.conf" /etc/geoclue/conf.d/90-caboose.conf
if [ -d /usr/lib/firefox-esr ]; then
  install -Dm644 "$here/firefox-portal.js" /usr/lib/firefox-esr/defaults/pref/caboose-portal.js
fi
# GTK 3 uses the portal for file choosing and, on Wayland, reads its settings from it.
install -d -m 0755 /etc/environment.d
printf 'GTK_USE_PORTAL=1\n' > /etc/environment.d/91-caboose-portal.conf
if [ -d /etc/systemd/system ]; then
  install -m 0644 "$here/caboose-bridge.service" /etc/systemd/system/caboose-bridge.service
fi
