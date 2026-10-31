import os
import sys
import types
import unittest
from unittest.mock import Mock
sys.path.insert(0, os.path.dirname(__file__))
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
