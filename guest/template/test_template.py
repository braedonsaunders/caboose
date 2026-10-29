import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('caboose_template', pathlib.Path(__file__).with_name('caboose-template.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class TemplateHelperTest(unittest.TestCase):
    def test_prepare_refuses_running_users_without_writing_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'ready'
            with patch.object(helper, 'READY', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'run'), patch.object(helper, 'user_processes', return_value=['123']):
                with self.assertRaisesRegex(RuntimeError, 'User processes'):
                    helper.prepare()
                self.assertFalse(marker.exists())

    def test_agent_restart_requires_a_new_process_identity(self):
        with patch.object(helper, 'agent_identity', return_value='123:456'):
            with self.assertRaisesRegex(RuntimeError, 'has not restarted'):
                helper.check_agent('123:456')
            helper.check_agent('123:455')
            with self.assertRaisesRegex(RuntimeError, 'Invalid prior'):
                helper.check_agent('invalid')

    def test_reprobe_requires_exactly_one_device(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            driver = root / 'virtio_rng'
            driver.mkdir()
            (driver / 'unbind').touch()
            (driver / 'bind').touch()
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                helper.rebind_driver('virtio_rng', root)
            (driver / 'virtio0').touch()
            helper.rebind_driver('virtio_rng', root)
            self.assertEqual((driver / 'unbind').read_text(), 'virtio0')
            self.assertEqual((driver / 'bind').read_text(), 'virtio0')
            (driver / 'virtio1').touch()
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                helper.rebind_driver('virtio_rng', root)

    def test_activate_refuses_to_start_user_services_before_reset(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'initialized'
            marker.write_text('incorrect\n')
            with patch.object(helper, 'INITIALIZED', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'not been reinitialized'):
                    helper.activate()
                run.assert_not_called()

    def test_reinitialize_rejects_invalid_identity_before_reading_entropy(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / 'ready'
            marker.write_text('prepared\n')
            with patch.object(helper, 'READY', marker), patch.object(helper, 'template_boot'), patch.object(helper, 'user_processes', return_value=[]), patch.object(helper, 'hardware_random') as random:
                with self.assertRaisesRegex(RuntimeError, 'MAC'):
                    helper.reinitialize('01:00:00:00:00:01', 10)
                with self.assertRaisesRegex(RuntimeError, 'CID'):
                    helper.reinitialize('02:00:00:00:00:01', 2)
                random.assert_not_called()
                self.assertTrue(marker.exists())


if __name__ == '__main__':
    unittest.main()
