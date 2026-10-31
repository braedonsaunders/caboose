"""Shared, D-Bus-free logic for the notification endpoint (daemon.py) and caboose-notify.

What a Notify call keeps, the owner's live notifications, their private queue records and
the respond command's arguments. Everything an application or the host supplies is
validated and bounded here (guest/notifications/README.md).
"""
import json
import os
import pathlib
import re
import uuid
from collections import OrderedDict, namedtuple

QUEUE = pathlib.Path('/home/caboose/.cache/caboose/notifications')
#: Queue records kept; older ones are deleted.
KEEP = 100
#: Live notifications the owner's endpoint remembers; the oldest beyond this expire.
LIVE = 256
APP, SUMMARY, BODY = 200, 500, 1000
LABEL, PLACEHOLDER, KEY = 64, 100, 64
#: Action buttons a record carries, besides the default action and an inline reply.
BUTTONS = 4
#: Characters in a reply.
REPLY = 2000
#: What the owner's endpoint tells applications it supports.
OWNER_CAPABILITIES = ('actions', 'body', 'inline-reply')
#: NotificationClosed reasons (Desktop Notifications Specification 1.2).
EXPIRED, DISMISSED, CLOSED = 1, 2, 3
MAX_ID = 0xFFFFFFFF

RECORD_ID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
DESKTOP_ENTRY = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$')
CONTROL = re.compile(r'[\x00-\x1f\x7f]')

Response = namedtuple('Response', 'result id signal value close')


def valid_key(key):
    """An action key the phone can name: 1 to 64 characters without control characters."""
    return isinstance(key, str) and 0 < len(key) <= KEY and not CONTROL.search(key)


def label(text, limit=LABEL):
    """One line of text for a button or a placeholder: control characters and runs of
    whitespace become one space, at most `limit` characters."""
    if not isinstance(text, str):
        return ''
    return ' '.join(CONTROL.sub(' ', text).split())[:limit].strip()


def desktop_entry(value):
    """The `desktop-entry` hint as a desktop file ID without `.desktop`, or None."""
    if not isinstance(value, str):
        return None
    value = value.strip()
    if value.endswith('.desktop'):
        value = value[:-len('.desktop')]
    return value if DESKTOP_ENTRY.match(value) else None


def parse(args):
    """A Notify call's arguments as what the endpoint keeps, or None when they are malformed.

    `actions` are the buttons (at most BUTTONS, without `default` and `inline-reply`);
    `defaultAction` is whether the application offered `default` (activating the
    notification); `reply` is set when it offered KDE's `inline-reply`. `keys` are the
    action keys a response may name."""
    if not isinstance(args, (tuple, list)) or len(args) != 8:
        return None
    app, replaces, _icon, summary, body, actions, hints, _timeout = args
    if not all(isinstance(value, str) for value in (app, summary, body)):
        return None
    if not isinstance(replaces, int) or isinstance(replaces, bool) or not 0 <= replaces <= MAX_ID:
        return None
    if not isinstance(actions, (tuple, list)) or not isinstance(hints, dict):
        return None
    buttons, keys, reply, seen = [], set(), None, set()
    for index in range(0, len(actions) - 1, 2):
        key, text = actions[index], actions[index + 1]
        if not valid_key(key) or not isinstance(text, str) or key in seen:
            continue
        seen.add(key)
        if key == 'default':
            keys.add(key)
        elif key == 'inline-reply':
            placeholder = hints.get('x-kde-reply-placeholder-text')
            reply = {'label': label(text), 'placeholder': label(placeholder, PLACEHOLDER)}
        elif len(buttons) < BUTTONS and label(text):
            buttons.append({'key': key, 'label': label(text)})
            keys.add(key)
    resident = hints.get('resident')
    return {
        'app': app[:APP], 'summary': summary[:SUMMARY], 'body': body[:BODY],
        'desktopEntry': desktop_entry(hints.get('desktop-entry')),
        'actions': buttons, 'defaultAction': 'default' in keys, 'reply': reply,
        'keys': keys, 'resident': resident is True,
    }


class Live:
    """The notifications an endpoint has accepted and not closed, by server ID, oldest first."""

    def __init__(self, limit=LIVE):
        self.limit = limit
        self.entries = OrderedDict()
        self.last = 0

    def _next(self):
        while True:
            self.last = self.last % MAX_ID + 1
            if self.last not in self.entries:
                return self.last

    def notify(self, replaces, notice, new_record=lambda: str(uuid.uuid4())):
        """Accepts a notification: (server ID, record ID, server IDs it expired).

        A replacement keeps its server ID (as the specification requires) and its record
        ID, so the phone replaces its copy too."""
        previous = self.entries.pop(replaces, None) if replaces else None
        number = replaces or self._next()
        record = previous['record'] if previous else new_record()
        self.entries[number] = dict(notice, record=record)
        expired = []
        while len(self.entries) > self.limit:
            expired.append(self.entries.popitem(last=False)[0])
        return number, record, expired

    def close(self, number):
        """Forgets a notification; whether it was live."""
        return self.entries.pop(number, None) is not None

    def respond(self, record, kind, value):
        """Answers a record with an action key or reply text.

        `result` is `responded`, `unknown-notification` (closed, replaced by a restart, or
        never this endpoint's) or `unknown-action` (one it did not offer). A responded
        notification is closed unless the application marked it resident."""
        for number, entry in self.entries.items():
            if entry['record'] == record:
                break
        else:
            return Response('unknown-notification', None, None, None, False)
        if kind == 'reply' and entry['reply'] is not None and 0 < len(value) <= REPLY:
            signal = 'NotificationReplied'
        elif kind == 'action' and value in entry['keys']:
            signal = 'ActionInvoked'
        else:
            return Response('unknown-action', None, None, None, False)
        close = not entry['resident']
        if close:
            del self.entries[number]
        return Response('responded', number, signal, value, close)


def record(notice, record_id, created):
    """The queue record the host reads (docs/architecture.md § Guest services)."""
    return {
        'id': record_id, 'app': notice['app'], 'summary': notice['summary'], 'body': notice['body'],
        'created': int(created), 'desktopEntry': notice['desktopEntry'], 'actions': notice['actions'],
        'defaultAction': notice['defaultAction'], 'reply': notice['reply'],
    }


def spool(entry, queue=QUEUE, keep=KEEP):
    """Writes a record privately and atomically. A replacement overwrites a record the host
    has not read yet; beyond `keep`, the oldest records are deleted."""
    temporary = queue / ('.' + entry['id'] + '.' + uuid.uuid4().hex)
    with temporary.open('x', encoding='utf-8') as file:
        os.chmod(temporary, 0o600)
        json.dump(entry, file, ensure_ascii=True)
    temporary.rename(queue / (entry['id'] + '.json'))
    # The host can drain concurrently; a disappearing file must not discard this record.
    entries = []
    for path in queue.glob('*.json'):
        try:
            entries.append((path.stat().st_mtime_ns, path))
        except FileNotFoundError:
            pass
    for _, path in sorted(entries)[:-keep]:
        path.unlink(missing_ok=True)


def respond_arguments(argv):
    """`respond ID --action=KEY` or `respond ID --reply=TEXT` (or with the value as the next
    argument) → (record ID, 'action' or 'reply', value). Raises ValueError otherwise."""
    if len(argv) not in (3, 4) or argv[0] != 'respond':
        raise ValueError('usage: caboose-notify respond ID (--action=KEY | --reply=TEXT)')
    record_id, option = argv[1], argv[2]
    if not RECORD_ID.match(record_id):
        raise ValueError('ID must be a notification record ID')
    if len(argv) == 4:
        if option not in ('--action', '--reply'):
            raise ValueError('expected --action or --reply')
        kind, value = option[2:], argv[3]
    else:
        kind, separator, value = option[2:].partition('=')
        if not option.startswith('--') or not separator or kind not in ('action', 'reply'):
            raise ValueError('expected --action=KEY or --reply=TEXT')
    if kind == 'action' and not valid_key(value):
        raise ValueError('KEY must be 1 to 64 characters without control characters')
    if kind == 'reply':
        try:
            value.encode('utf-8')
        except UnicodeEncodeError:
            raise ValueError('TEXT must be UTF-8') from None
        if not 0 < len(value) <= REPLY or '\x00' in value:
            raise ValueError('TEXT must be 1 to 2000 characters without NUL')
    return record_id, kind, value
