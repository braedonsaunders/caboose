# Guest notifications

The owner session's monitor observes `org.freedesktop.Notifications.Notify` calls on its
D-Bus session and writes private, bounded JSON records to
`/home/caboose/.cache/caboose/notifications`. The host drains them while the guest runs.
The agent seat has a separate session bus. For Caboose Display, `daemon.py` owns the
notification name; Xpra provides that endpoint when it is the owner display.

Both guest image builds install this directory. On a Debian guest with the `caboose`
user, systemd, `dbus-user-session`, `python3-gi` and `libnotify-bin`, run `sudo sh
install.sh`, enable `caboose-notifications.service`, and enable lingering for `caboose`.
The image build and `guest/display/install.sh` do this already. The agent-seat bus is
started by `caboose-xpra-agent.service`; the Caboose Display endpoint is started by
`caboose-display.service`. The container session script starts their counterparts.

Run `./check-container.sh` from a checkout with Docker to exercise the monitor and
separate session buses in an ephemeral Debian container. With the owner display running,
run `sudo bash check.sh` inside the guest to send a notification and check the queue;
the host's concurrent drain can consume it before the check sees it. End-to-end APNs
and presentation need a registered device and the host's `check-push.mjs`.
