"""notifycore: Notify arguments, live notifications, queue records and respond arguments.

    python3 -m unittest discover -s guest/notifications -p 'test_*.py'
"""
import json
import os
import pathlib
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import notifycore as core  # noqa: E402

RECORD = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'


def call(actions=(), hints=None, replaces=0, app='Signal', summary='Ada', body='Lunch?'):
    return (app, replaces, 'icon', summary, body, list(actions), hints or {}, -1)


class Parse(unittest.TestCase):
    def test_keeps_bounded_text_and_no_actions_by_default(self):
        notice = core.parse(call(app='a' * 300, summary='s' * 600, body='b' * 1200))
        self.assertEqual((len(notice['app']), len(notice['summary']), len(notice['body'])), (200, 500, 1000))
        self.assertEqual((notice['actions'], notice['defaultAction'], notice['reply'], notice['desktopEntry']), ([], False, None, None))

    def test_separates_default_inline_reply_and_buttons(self):
        notice = core.parse(call(
            ['default', 'Open', 'inline-reply', 'Reply', 'read', 'Mark as Read', 'mute', 'Mute'],
            {'x-kde-reply-placeholder-text': 'Message\nAda', 'desktop-entry': 'org.signal.Signal.desktop'}))
        self.assertTrue(notice['defaultAction'])
        self.assertEqual(notice['reply'], {'label': 'Reply', 'placeholder': 'Message Ada'})
        self.assertEqual(notice['actions'], [{'key': 'read', 'label': 'Mark as Read'}, {'key': 'mute', 'label': 'Mute'}])
        self.assertEqual(notice['keys'], {'default', 'read', 'mute'})
        self.assertEqual(notice['desktopEntry'], 'org.signal.Signal')

    def test_drops_malformed_duplicate_unlabelled_and_excess_actions(self):
        actions = ['', 'Empty key', 'x' * 65, 'Long key', 'bad\nkey', 'Control', 'a', 'A', 'a', 'Again',
                   'blank', '  \t ', 'b', 'B', 'c', 'C', 'd', 'D', 'e', 'E', 'odd']
        notice = core.parse(call(actions))
        self.assertEqual([action['key'] for action in notice['actions']], ['a', 'b', 'c', 'd'])
        self.assertNotIn('e', notice['keys'])

    def test_labels_are_one_bounded_line(self):
        notice = core.parse(call(['go', '  Open\tthe\n' + 'x' * 100]))
        self.assertEqual(notice['actions'][0]['label'], ('Open the ' + 'x' * 100)[:64])

    def test_validates_desktop_entry_and_resident(self):
        self.assertIsNone(core.parse(call(hints={'desktop-entry': '../evil'}))['desktopEntry'])
        self.assertIsNone(core.parse(call(hints={'desktop-entry': 7}))['desktopEntry'])
        self.assertEqual(core.parse(call(hints={'desktop-entry': 'thunderbird'}))['desktopEntry'], 'thunderbird')
        self.assertTrue(core.parse(call(hints={'resident': True}))['resident'])
        self.assertFalse(core.parse(call(hints={'resident': 1}))['resident'])

    def test_rejects_malformed_calls(self):
        self.assertIsNone(core.parse(('app',)))
        self.assertIsNone(core.parse(call(replaces=-1)))
        self.assertIsNone(core.parse((1, 0, '', '', '', [], {}, 0)))


class LiveNotifications(unittest.TestCase):
    def notice(self, *actions, hints=None):
        return core.parse(call(actions, hints))

    def test_assigns_ids_and_keeps_replacements_in_place(self):
        live = core.Live()
        first, record, expired = live.notify(0, self.notice(), lambda: RECORD)
        self.assertEqual((first, record, expired), (1, RECORD, []))
        again, same, _ = live.notify(first, self.notice(), lambda: 'other')
        self.assertEqual((again, same), (1, RECORD))
        foreign, fresh, _ = live.notify(40, self.notice(), lambda: 'new')
        self.assertEqual((foreign, fresh), (40, 'new'))
        self.assertEqual(live.notify(0, self.notice())[0], 2)

    def test_skips_live_ids_and_wraps(self):
        live = core.Live()
        live.notify(core.MAX_ID, self.notice())
        live.last = core.MAX_ID - 1
        self.assertEqual(live.notify(0, self.notice())[0], 1)

    def test_expires_the_oldest_beyond_its_bound(self):
        live = core.Live(limit=2)
        for _ in range(3):
            number, _, expired = live.notify(0, self.notice())
        self.assertEqual((number, expired), (3, [1]))
        self.assertEqual(list(live.entries), [2, 3])

    def test_close(self):
        live = core.Live()
        number = live.notify(0, self.notice())[0]
        self.assertTrue(live.close(number))
        self.assertFalse(live.close(number))

    def test_actions_answer_once_and_close(self):
        live = core.Live()
        number = live.notify(0, self.notice('default', '', 'read', 'Read'), lambda: RECORD)[0]
        self.assertEqual(live.respond(RECORD, 'action', 'mute').result, 'unknown-action')
        self.assertEqual(live.respond(RECORD, 'reply', 'hi').result, 'unknown-action')
        self.assertEqual(live.respond(RECORD, 'action', 'read'), core.Response('responded', number, 'ActionInvoked', 'read', True))
        self.assertEqual(live.respond(RECORD, 'action', 'default').result, 'unknown-notification')

    def test_resident_notifications_stay(self):
        live = core.Live()
        live.notify(0, self.notice('default', 'Open', hints={'resident': True}), lambda: RECORD)
        self.assertFalse(live.respond(RECORD, 'action', 'default').close)
        self.assertEqual(live.respond(RECORD, 'action', 'default').result, 'responded')

    def test_replies(self):
        live = core.Live()
        number = live.notify(0, self.notice('inline-reply', 'Reply'), lambda: RECORD)[0]
        self.assertEqual(live.respond(RECORD, 'reply', 'x' * 2001).result, 'unknown-action')
        self.assertEqual(live.respond(RECORD, 'action', 'inline-reply').result, 'unknown-action')
        self.assertEqual(live.respond(RECORD, 'reply', 'On my way'), core.Response('responded', number, 'NotificationReplied', 'On my way', True))


class Records(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.queue = pathlib.Path(self.temp.name)

    def test_record_fields(self):
        notice = core.parse(call(['default', 'Open', 'read', 'Read'], {'desktop-entry': 'signal'}))
        self.assertEqual(core.record(notice, RECORD, 1000.7), {
            'id': RECORD, 'app': 'Signal', 'summary': 'Ada', 'body': 'Lunch?', 'created': 1000,
            'desktopEntry': 'signal', 'actions': [{'key': 'read', 'label': 'Read'}], 'defaultAction': True, 'reply': None})

    def test_spool_is_private_replaces_pending_and_bounded(self):
        notice = core.parse(call())
        core.spool(core.record(notice, RECORD, 1), self.queue)
        core.spool(dict(core.record(notice, RECORD, 2), summary='Updated'), self.queue)
        path = self.queue / (RECORD + '.json')
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(path.read_text())['summary'], 'Updated')
        for index in range(4):
            core.spool(core.record(notice, f'{index:08d}-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 3), self.queue, keep=3)
        self.assertEqual(len(list(self.queue.glob('*.json'))), 3)
        self.assertEqual(list(self.queue.glob('.*')), [])


class RespondArguments(unittest.TestCase):
    def test_accepts_both_forms(self):
        self.assertEqual(core.respond_arguments(['respond', RECORD, '--action=default']), (RECORD, 'action', 'default'))
        self.assertEqual(core.respond_arguments(['respond', RECORD, '--reply', '--help']), (RECORD, 'reply', '--help'))
        self.assertEqual(core.respond_arguments(['respond', RECORD, '--reply=a=b']), (RECORD, 'reply', 'a=b'))

    def test_rejects_everything_else(self):
        for argv in (
            [], ['respond', RECORD], ['close', RECORD, '--action=x'], ['respond', '../x', '--action=x'],
            ['respond', RECORD.upper(), '--action=x'], ['respond', RECORD, '--action='], ['respond', RECORD, '--reply='],
            ['respond', RECORD, '--other=x'], ['respond', RECORD, 'action=x'], ['respond', RECORD, '--action', 'a\nb'],
            ['respond', RECORD, '--reply=' + 'x' * 2001], ['respond', RECORD, '--reply=a\x00b'],
            ['respond', RECORD, '--reply=\udcff'], ['respond', RECORD, '--action=x', 'extra'],
        ):
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                core.respond_arguments(argv)


if __name__ == '__main__':
    unittest.main()
