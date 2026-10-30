# Guest notifications

Desktop notifications from the owner's apps, for the phone, and the phone's answers to them.
Each display seat has its own D-Bus session bus and its own `org.freedesktop.Notifications`
endpoint; only the owner's notifications are recorded. caboose-host drains the records while
the computer runs and sends them as `notification` events on `/v1/control` and, with APNs
configured, as pushes; the phone answers through `POST /v1/notifications/:id/respond`, which
runs `caboose-notify` (`docs/architecture.md` § Desktop notifications).

| File | What |
| --- | --- |
| `daemon.py` | The `org.freedesktop.Notifications` endpoint on a seat's session bus. It accepts every notification so that apps never wait on a missing server. With `--owner` it is the owner's: it records each notification and answers `caboose-notify` (below). |
| `notifycore.py` | The D-Bus-free logic both share: what a notification keeps, the live notifications, the queue records and `caboose-notify`'s arguments. |
| `caboose-notify` | `caboose-notify respond ID --action=KEY` or `--reply=TEXT`: answers a recorded notification, as `caboose`. |
| `caboose-notification-daemon.service` | The owner's endpoint (`daemon.py --owner`) on `/run/user/1000/bus`, required by `caboose-display.service`. |
| `caboose-agent-bus.service` | The agent seat's session bus, `/run/user/1000/agent-bus`. |
| `caboose-agent-notification-daemon.service` | The agent seat's endpoint, required by `caboose-display-agent.service`. Its notifications go nowhere. |
| `install.sh` | Installs the scripts in `/opt/caboose/notifications` and the units. |

## The owner's endpoint

It tells applications it supports `actions`, `body` and `inline-reply` (KDE's inline reply);
the agent seat's endpoint supports none. For each `Notify` call it keeps, in memory, the
server ID it answers with and what the phone can do: at most 4 action buttons (`key` and
`label`, keys 1–64 characters, labels one line of at most 64), whether the application
offered the `default` action (activating the notification), whether it offered
`inline-reply` (with the `x-kde-reply-placeholder-text` hint, at most 100 characters), and the
`desktop-entry` hint as a desktop file ID without `.desktop`. It remembers 256 live
notifications; beyond that the oldest is closed as expired. `CloseNotification` closes one.
A notification sent with the `replaces_id` of a live one keeps its server ID and its record
ID.

Each notification is written as a private record (mode 0600) in
`/home/caboose/.cache/caboose/notifications/<record id>.json`:

```json
{ "id": "<uuid>", "app": "Signal", "summary": "Ada", "body": "Lunch?", "created": 1767225600,
  "desktopEntry": "org.signal.Signal", "actions": [{ "key": "read", "label": "Mark as Read" }],
  "defaultAction": true, "reply": { "label": "Reply", "placeholder": "Message Ada" } }
```

`app` is at most 200 characters, `summary` 500 and `body` 1000; `desktopEntry` and `reply` are
null when absent. A replacement overwrites a record the host has not read yet. The newest
100 records are kept.

`caboose-notify respond ID --action=KEY` emits `ActionInvoked` for one of the record's keys
(`default` among them when it was offered); `--reply=TEXT` (1–2000 characters) emits
`NotificationReplied`. The endpoint then closes the notification (`NotificationClosed`,
reason 2) unless the application marked it `resident`. The command calls the endpoint's
`org.caboose.Notifications.Respond` method at `/org/caboose/Notifications` on the owner's
bus, never starting another notification server, and prints one JSON line,
`{"result": R}`: `responded`, `unknown-action` (one the notification did not offer), or
`unknown-notification` (closed, answered, expired, or gone because the endpoint or the owner's
display stopped: the live notifications are held only in the endpoint's memory). The
endpoint emits no `ActivationToken`: Caboose Display has no XDG activation.

## Install

The microVM image and `guest/display/install.sh` run `install.sh` and enable lingering for
`caboose`, so its user manager and session bus run at boot; the owner's display starts the
owner's endpoint. On another Debian guest with the `caboose` user, systemd,
`dbus-user-session`, `python3-gi` and `libnotify-bin`, do the same as root:

```sh
sh guest/notifications/install.sh
mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/caboose
```

`install.sh` also removes the separate monitor and its unit that earlier guest components
installed. A guest component update starts a running owner endpoint again with the new code
without restarting the owner's display; its live notifications are lost, so answering one
recorded before the update finds `unknown-notification`.

The container image installs the scripts; `caboose-session start` and `start-agent` start the
same buses and endpoints as processes (see `guest/container/README.md`).

## Test

- `python3 -m unittest discover -s guest/notifications -p 'test_*.py'`, from the checkout
  root, tests `notifycore.py`: argument parsing and bounds, live notifications, records and
  `caboose-notify`'s arguments. It needs no D-Bus.
- `./check-container.sh`, from a checkout with Docker, runs `daemon.py --owner` on a session
  bus in a disposable Debian 13 container and runs `check-respond.py`: it sends a
  notification with actions and one with an inline reply, checks their records, answers them
  with `caboose-notify` and checks that the application receives `ActionInvoked`,
  `NotificationReplied` and `NotificationClosed`. It then sends an agent notification on a
  separate bus (`check-agent-bus.sh`) and checks that it is not recorded. It needs no VM or
  APNs credentials.
- `sudo bash check.sh`, inside a running computer with the owner's display up, runs
  `check-respond.py` on the owner's bus. The host drains the queue every second while the
  computer runs and can consume a record before the check sees it; the notifications also
  reach the owner's phone.

Delivery to a device needs a registered device and the host's `check-push.mjs`
([`apps/host`](../../apps/host/README.md#real-host-checks)).
