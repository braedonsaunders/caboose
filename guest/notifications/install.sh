#!/bin/sh
set -eu
here=$(dirname "$0")
install -d -m 0755 /opt/caboose/notifications
install -m 0755 "$here/daemon.py" "$here/caboose-notify" /opt/caboose/notifications/
install -m 0644 "$here/notifycore.py" /opt/caboose/notifications/
# The owner's endpoint records the owner's notifications; remove the separate monitor that
# earlier components installed.
rm -f /opt/caboose/notifications/monitor.py
if [ -d /etc/systemd/system ]; then
  if [ -f /etc/systemd/system/caboose-notifications.service ]; then
    if [ -d /run/systemd/system ]; then systemctl disable --now caboose-notifications.service || :; fi
    rm -f /etc/systemd/system/caboose-notifications.service /etc/systemd/system/multi-user.target.wants/caboose-notifications.service
  fi
  install -m 0644 "$here/caboose-notification-daemon.service" /etc/systemd/system/caboose-notification-daemon.service
  install -m 0644 "$here/caboose-agent-bus.service" /etc/systemd/system/caboose-agent-bus.service
  install -m 0644 "$here/caboose-agent-notification-daemon.service" /etc/systemd/system/caboose-agent-notification-daemon.service
fi
