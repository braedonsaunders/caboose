import os
import sys
import types
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, os.path.dirname(__file__))
import a11y
from a11y import Tree, dispatch_accessibility_events


class ValueTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree.__new__(Tree)
        roles = types.SimpleNamespace(**{name: name for name in ('PASSWORD_TEXT', 'ENTRY', 'AUTOCOMPLETE', 'EDITBAR', 'SPIN_BUTTON', 'SLIDER', 'COMBO_BOX')})
        self.tree.Atspi = types.SimpleNamespace(Role=roles, Value=types.SimpleNamespace(get_current_value=lambda node: 0))
        self.tree.has = lambda states, name: name in states
        self.tree.text = Mock(return_value='hello')
        self.node = Mock()
        self.node.get_attributes.return_value = []

    def test_editable_value_is_separate_from_fingerprint(self):
        self.assertEqual(self.tree.value(self.node, 'ENTRY', {'EDITABLE'}), 'hello')
        self.tree.text.assert_called_once_with(self.node, 200)

    def test_password_and_sensitive_values_are_never_read(self):
        self.assertIsNone(self.tree.value(self.node, 'PASSWORD_TEXT', {'EDITABLE'}))
        self.node.get_attributes.return_value = {'text-input-type': 'password'}
        self.assertIsNone(self.tree.value(self.node, 'ENTRY', {'EDITABLE'}))
        self.tree.text.assert_not_called()

    def test_numeric_zero_is_preserved(self):
        self.tree.text.return_value = ''
        self.assertEqual(self.tree.value(self.node, 'SLIDER', set()), '0')


class EventDispatchTests(unittest.TestCase):
    def test_processes_pending_updates_without_waiting(self):
        context = Mock()
        context.pending.side_effect = [True, True, False]
        dispatch_accessibility_events(context)
        self.assertEqual(context.iteration.call_count, 2)
        context.iteration.assert_called_with(False)

    def test_event_storm_cannot_starve_requests(self):
        context = Mock()
        context.pending.return_value = True
        dispatch_accessibility_events(context)
        self.assertEqual(context.iteration.call_count, 256)
        self.assertTrue(all(call.args == (False,) for call in context.iteration.call_args_list))


if __name__ == '__main__':
    unittest.main()


class PressTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree.__new__(Tree)
        self.tree.Atspi = types.SimpleNamespace(Role=types.SimpleNamespace(MENU='MENU', PUSH_BUTTON='PUSH_BUTTON'), Action=Mock())
        self.tree.has = lambda states, name: name in states
        self.tree.press_actions = ('click', 'press')
        self.tree.actions = lambda node: ('iface', ['click'])
        self.tree.bounds = lambda node, origin: {'x': 34, 'y': 0, 'width': 36, 'height': 26}
        self.node, self.screen = Mock(), Mock()

    def press(self, role, states=frozenset({'ENABLED', 'SHOWING'})):
        self.node.get_role.return_value = role
        with patch.object(a11y, 'resolve', return_value=(self.screen, 1, self.tree, self.node, set(states), None)):
            a11y.act(':101', 'id', 'press', None)

    def test_a_menu_on_screen_is_clicked_at_its_own_coordinates(self):
        # A menu's own action can open another menu of its bar.
        self.press('MENU')
        self.screen.click.assert_called_once_with(1, 52, 13)
        self.tree.Atspi.Action.do_action.assert_not_called()

    def test_other_controls_and_off_screen_menus_use_their_own_action(self):
        self.tree.Atspi.Action.do_action.return_value = True
        self.press('PUSH_BUTTON')
        self.press('MENU', {'ENABLED'})
        self.assertEqual(self.tree.Atspi.Action.do_action.call_count, 2)
        self.screen.click.assert_not_called()


class StaleCacheTests(unittest.TestCase):
    def test_a_missed_window_or_element_is_read_again_by_a_fresh_helper(self):
        self.assertTrue(a11y.stale('elements', {'elements': [], 'note': "The focused window was not found in its application's accessibility tree; use a screenshot."}))
        self.assertTrue(a11y.stale('act', {'ok': False, 'error': 'element not found'}))
        self.assertFalse(a11y.stale('elements', {'elements': [], 'note': 'No window is open on this display.'}))
        self.assertFalse(a11y.stale('act', {'ok': False, 'error': 'element is disabled'}))

    def test_a_re_registered_helper_answers_the_replayed_request_first(self):
        import json, subprocess
        env = dict(os.environ, CABOOSE_A11Y_REPLAY=json.dumps({"op": "bogus"}))
        done = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "a11y.py"), "serve", "--display=:999"],
                              input=json.dumps({"op": "also-bogus"}) + "\n", capture_output=True, text=True, env=env, timeout=20)
        lines = [json.loads(l) for l in done.stdout.splitlines()]
        self.assertEqual(lines, [{"error": "invalid worker request"}, {"error": "invalid worker request"}])
