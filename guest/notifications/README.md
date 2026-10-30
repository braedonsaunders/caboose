# Guest notifications

Desktop notifications from the owner's apps, for the phone. Each display seat has its own
D-Bus session bus and its own `org.freedesktop.Notifications` endpoint; only the owner's
notifications are recorded. caboose-host accepts records through the Files event receiver while the computer runs and sends
them as `notification` events on `/v1/control` and, with APNs configured, as pushes
(`docs/architecture.md` § Notifications).

| File | What |
| --- | --- |
| `daemon.py` | The `org.freedesktop.Notifications` endpoint on a seat's session bus. It accepts every notification so that apps never wait on a missing server. |
| `monitor.py` | Watches `Notify` calls on the owner's session bus and writes private, bounded JSON records (`id`, `app`, `summary`, `body`, `created`) to `/home/caboose/.cache/caboose/notifications`. |
| `caboose-notifications.service` | The owner's monitor (enabled at boot). |
| `caboose-notification-daemon.service` | The owner's endpoint on `/run/user/1000/bus`, required by `caboose-display.service`. |
| `caboose-agent-bus.service` | The agent seat's session bus, `/run/user/1000/agent-bus`. |
| `caboose-agent-notification-daemon.service` | The agent seat's endpoint, required by `caboose-display-agent.service`. Its notifications go nowhere. |
| `install.sh` | Installs the two scripts in `/opt/caboose/notifications` and the units. |

## Install

The microVM image and `guest/display/install.sh` run `install.sh`, enable
`caboose-notifications.service` and enable lingering for `caboose`, so its user manager and
session bus run at boot. On another Debian guest with the `caboose` user, systemd,
`dbus-user-session`, `python3-gi` and `libnotify-bin`, do the same as root:

```sh
sh guest/notifications/install.sh
systemctl enable caboose-notifications.service
mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/caboose
```

The container image installs the scripts; `caboose-session start` and `start-agent` start the
same buses, monitor and endpoints as processes (see `guest/container/README.md`).

## Test

- `./check-container.sh`, from a checkout with Docker, runs `daemon.py` and `monitor.py` on
  a session bus in a disposable Debian 13 container, sends an owner notification and an agent
  notification on a separate bus (`check-agent-bus.sh`), and checks that the owner's is
  recorded and the agent's is not. It needs no VM or APNs credentials.
- `sudo bash check.sh`, inside a running computer with the owner's display up, sends a
  notification on the owner's bus and waits for its record in the queue. The Files event receiver delivers and acknowledges the
  queue while the computer runs and can consume the record before the check
  sees it.

Delivery to a device needs a registered device and the host's `check-push.mjs`
([`apps/host`](../../apps/host/README.md#real-host-checks)).
