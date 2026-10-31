"""Model-free ownership tests for the opt-in hardware supervisor."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('reload_probe', Path(__file__).resolve().parents[1]/'probe-parakeet-reload.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class ReloadProbeOwnershipTests(unittest.TestCase):
    def mapping(self):
        return 'p42\nftxt\nn'+str((probe.ROOT/'swift/.build').resolve())+'/out/Products/Debug/VoxEngineTests.xctest/Contents/MacOS/VoxEngineTests'

    def test_helper_requires_parent_and_loaded_checkout_bundle(self):
        with patch.object(probe, 'capture', side_effect=['11', self.mapping()]):
            self.assertTrue(probe.owned_helper(42, 11))

    def test_rejects_another_parent_without_inspecting_its_files(self):
        with patch.object(probe, 'capture', return_value='99') as capture:
            self.assertFalse(probe.owned_helper(42, 11))
            self.assertEqual(capture.call_count, 1)

    def test_rejects_another_checkout(self):
        with patch.object(probe, 'capture', side_effect=['11', 'p42\nftxt\nn/tmp/other/VoxEngineTests.xctest/Contents/MacOS/VoxEngineTests']):
            self.assertFalse(probe.owned_helper(42, 11))

    def test_missing_process_is_not_owned(self):
        with patch.object(probe, 'capture', side_effect=subprocess.CalledProcessError(1, 'ps')):
            self.assertFalse(probe.owned_helper(42, 11))

    def test_unverified_helper_is_never_signalled(self):
        process = Mock(pid=11)
        process.poll.return_value = None
        with patch.object(probe, 'owned_helper', return_value=False), patch.object(probe.os, 'kill') as kill, patch.object(probe.os, 'killpg') as group:
            probe.stop_owned_processes(process, 42)
            kill.assert_not_called()
            group.assert_called_once_with(11, probe.signal.SIGTERM)

    def test_separate_verified_helper_is_stopped_before_launcher(self):
        process = Mock(pid=11)
        process.poll.return_value = None
        with patch.object(probe, 'owned_helper', side_effect=[True, False, False]), patch.object(probe.os, 'kill') as kill, patch.object(probe.os, 'killpg') as group:
            probe.stop_owned_processes(process, 42)
            kill.assert_called_once_with(42, probe.signal.SIGTERM)
            group.assert_called_once_with(11, probe.signal.SIGTERM)

if __name__ == '__main__': unittest.main()
