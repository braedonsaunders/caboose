#!/bin/sh
set -eu
install -d -m 0755 /opt/caboose/notifications
install -m 0755 "$(dirname "$0")/monitor.py" "$(dirname "$0")/daemon.py" /opt/caboose/notifications/
if [ -d /etc/systemd/system ]; then
  install -m 0644 "$(dirname "$0")/caboose-notifications.service" /etc/systemd/system/caboose-notifications.service
  install -m 0644 "$(dirname "$0")/caboose-notification-daemon.service" /etc/systemd/system/caboose-notification-daemon.service
  install -m 0644 "$(dirname "$0")/caboose-agent-bus.service" /etc/systemd/system/caboose-agent-bus.service
  install -m 0644 "$(dirname "$0")/caboose-agent-notification-daemon.service" /etc/systemd/system/caboose-agent-notification-daemon.service
fi
