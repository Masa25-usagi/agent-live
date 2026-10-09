"""Exercise USB setup safety with fake commands; never touches a real device."""
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install_iphone.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class USBSetupTests(unittest.TestCase):
    def run_setup(self, root, transfer_fails=False, stale_report=False):
        fixture_key = 'synthetic-test-key-not-a-real-credential'
        pairing = root / 'source.json'
        pairing.write_text(json.dumps({'endpoint': 'https://fixture.invalid', 'token': fixture_key,
            'voice': 'hermes', 'agent_provider': 'nous', 'agent_model': 'fixture-model', 'speech_provider': '', 'live_conversation': 'true',
            'economy_fast_mode': 'true', 'gemini_fast_mode': 'true', 'direct_gemini': 'false', 'direct_jev': 'false'}))
        pairing.chmod(0o600)
        scratch = root / 'scratch'
        commands = []
        reads = 0

        def fake_execute(command, env, timeout=180, log=None):
            nonlocal reads
            commands.append(command)
            self.assertNotIn(fixture_key, ' '.join(command))
            if command[0] == 'xcodebuild':
                app = scratch / 'Build/Build/Products/Debug-iphoneos/AgentLive.app'
                app.mkdir(parents=True)
                (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fixture.agentlive'}))
            if 'copy' in command and 'to' in command:
                temporary = Path(command[command.index('--source') + 1])
                self.assertEqual(temporary.stat().st_mode & 0o777, 0o600)
                self.assertEqual(json.loads(temporary.read_text())['token'], fixture_key)
                self.assertEqual(json.loads(temporary.read_text())['agent_provider'], 'nous')
                self.assertEqual(json.loads(temporary.read_text())['voice'], 'hermes')
                self.assertEqual(json.loads(temporary.read_text())['agent_model'], 'fixture-model')
                self.assertEqual(json.loads(temporary.read_text())['speech_provider'], '')
                self.assertEqual(json.loads(temporary.read_text())['live_conversation'], 'true')
                self.assertEqual(json.loads(temporary.read_text())['economy_fast_mode'], 'true')
                self.assertEqual(json.loads(temporary.read_text())['gemini_fast_mode'], 'true')
                self.assertEqual(json.loads(temporary.read_text())['direct_gemini'], 'false')
                self.assertEqual(json.loads(temporary.read_text())['direct_jev'], 'false')
                if transfer_fails:
                    raise RuntimeError('Synthetic USB transfer failure')
            if 'copy' in command and 'from' in command:
                reads += 1
                destination = Path(command[command.index('--destination') + 1])
                destination.write_text(json.dumps({'configuration_imported': True, 'configured': True,
                    'server_reachable': True, 'recording': False,
                    'checked_at_epoch': 0 if stale_report and reads == 1 else 200}))
            return None

        args = ['install_iphone', '--pairing', str(pairing), '--scratch', str(scratch), '--team', 'SYNTHETIC']
        output = io.StringIO()
        with patch.object(installer.sys, 'argv', args), patch.object(installer, 'xcode_environment', return_value={}), \
             patch.object(installer, 'select_device', return_value='00000000-0000000000000000'), \
             patch.object(installer, 'execute', side_effect=fake_execute), \
             patch.object(installer.time, 'time', return_value=100), patch.object(installer.time, 'sleep'), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = installer.main()
        self.assertNotIn(fixture_key, output.getvalue())
        self.assertFalse((scratch / 'agentlive-pairing.json').exists())
        self.assertTrue(pairing.exists())
        self.assertEqual(scratch.stat().st_mode & 0o777, 0o700)
        return code, commands, reads

    def test_success_keeps_key_out_of_arguments_and_launches_without_capture(self):
        with tempfile.TemporaryDirectory() as value:
            code, commands, _ = self.run_setup(Path(value))
            self.assertEqual(code, 0)
            launch = next(command for command in commands if 'launch' in command)
            self.assertIn('--connect-only', launch)
            build = next(command for command in commands if command[0] == 'xcodebuild')
            self.assertIn('-allowProvisioningDeviceRegistration', build)
            self.assertEqual(build[build.index('-destination') + 1], 'platform=iOS,id=00000000-0000000000000000')

    def test_transfer_failure_removes_temporary_key_and_never_launches(self):
        with tempfile.TemporaryDirectory() as value:
            code, commands, _ = self.run_setup(Path(value), transfer_fails=True)
            self.assertEqual(code, 1)
            self.assertFalse(any('launch' in command for command in commands))

    def test_old_connection_report_does_not_confirm_a_new_install(self):
        with tempfile.TemporaryDirectory() as value:
            code, _, reads = self.run_setup(Path(value), stale_report=True)
            self.assertEqual(code, 0)
            self.assertEqual(reads, 2)

    def test_missing_xcode_stops_before_device_install(self):
        with tempfile.TemporaryDirectory() as value:
            args = ['install_iphone', '--pairing', '/not/read.json', '--scratch', value]
            with patch.object(installer.sys, 'argv', args), \
                 patch.object(installer, 'xcode_environment', side_effect=RuntimeError('Xcode is missing')), \
                 patch.object(installer, 'execute') as execute, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(installer.main(), 1)
                execute.assert_not_called()


if __name__ == '__main__':
    unittest.main()
