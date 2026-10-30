#!/bin/sh
set -eu
install -Dm755 "$(dirname "$0")/caboose-keyring" /opt/caboose/keyring/caboose-keyring

here=$(dirname "$0")
install -Dm755 "$here/secret-forwarder.py" /opt/caboose/keyring/secret-forwarder.py
install -Dm644 "$here/agent-bus.conf" /opt/caboose/keyring/agent-bus.conf
install -Dm644 "$here/org.freedesktop.secrets.service" /opt/caboose/keyring/agent-services/org.freedesktop.secrets.service
# Preserve installed application activation, excluding every credential writer.
# No owner-home service registrations are read or copied.
for service in /usr/share/dbus-1/services/*.service; do
  [ -f "$service" ] || continue
  case "$(basename "$service")" in
    org.freedesktop.secrets.service|*keyring*|*kwallet*) continue ;;
  esac
  if grep -Eiq '^Exec=.*(gnome-keyring|kwallet)' "$service"; then continue; fi
  install -m 0644 "$service" "/opt/caboose/keyring/agent-services/$(basename "$service")"
done
