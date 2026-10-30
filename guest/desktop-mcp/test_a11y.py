import os
import sys
import types
import unittest
from unittest.mock import Mock
sys.path.insert(0, os.path.dirname(__file__))
from a11y import Tree


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


if __name__ == '__main__':
    unittest.main()
