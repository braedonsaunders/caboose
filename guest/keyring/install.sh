#!/bin/sh
set -eu
install -Dm755 "$(dirname "$0")/caboose-keyring" /opt/caboose/keyring/caboose-keyring

here=$(dirname "$0")
install -Dm755 "$here/secret-forwarder.py" /opt/caboose/keyring/secret-forwarder.py
install -Dm644 "$here/agent-bus.conf" /opt/caboose/keyring/agent-bus.conf
python3 "$here/install-services.py" /usr/share/dbus-1/services \
  "$here/org.freedesktop.secrets.service" /opt/caboose/keyring/agent-services
