# SPDX-License-Identifier: MPL-2.0
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_helpers import load

CI = Path(__file__).resolve().parents[1]

class ToolingEntrypointTests(unittest.TestCase):
    def test_simulator_selection_is_family_and_runtime_specific(self):
        devices = {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [{'name':'iPad Air','udid':'ipad','isAvailable':True}, {'name':'iPhone Pro','udid':'phone','isAvailable':True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-28-0': [{'name':'iPhone','udid':'wrong','isAvailable':True}],
        }}
        with tempfile.TemporaryDirectory() as directory, patch('subprocess.check_output', return_value=json.dumps(devices).encode()):
            env = Path(directory) / 'env'
            for family, expected in [('iPhone','phone'),('iPad','ipad')]:
                env.write_text('')
                with patch.dict(os.environ, {'DEVICE_FAMILY':family,'GITHUB_ENV':str(env)}), contextlib.redirect_stdout(io.StringIO()):
                    runpy.run_path(str(CI / 'select_simulator.py'), run_name='__main__')
                self.assertEqual(env.read_text(), f'SIMULATOR_ID={expected}\n')
            with patch.dict(os.environ, {'DEVICE_FAMILY':'watch','GITHUB_ENV':str(env)}):
                with self.assertRaisesRegex(SystemExit, 'No available'):
                    runpy.run_path(str(CI / 'select_simulator.py'), run_name='__main__')

    def test_test_bundle_uses_declared_executable_and_rejects_missing_or_ambiguous_bundles(self):
        script = str(CI / 'package_test_binary.py')
        with tempfile.TemporaryDirectory() as directory, patch.object(sys, 'argv', [script, directory]):
            root = Path(directory)
            with self.assertRaisesRegex(SystemExit, 'Expected one'):
                runpy.run_path(script, run_name='__main__')
            bundle = root / 'OpenCodeKitTests.xctest/Contents'
            (bundle / 'MacOS').mkdir(parents=True)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'ActualTests'}))
            with self.assertRaisesRegex(SystemExit, 'executable missing'):
                runpy.run_path(script, run_name='__main__')
            executable = bundle / 'MacOS/ActualTests'
            executable.touch()
            output = io.StringIO()
            with contextlib.redirect_stdout(output): runpy.run_path(script, run_name='__main__')
            self.assertEqual(output.getvalue().strip(), str(executable))
            (root / 'Other.xctest').mkdir()
            with self.assertRaisesRegex(SystemExit, 'Expected one'):
                runpy.run_path(script, run_name='__main__')

    def test_json_and_document_links_are_checked_without_external_link_requests(self):
        checker = load('check_repository')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'docs').mkdir()
            (root / 'docs/target.md').write_text('ok')
            (root / 'data.json').write_text('{"valid":true}')
            (root / 'README.md').write_text('[local](docs/target.md#anchor) [external](https://example.com)\n```\n[ignored](absent.md)\n```\n')
            names=['README.md','data.json','deleted.md','docs/target.md']
            self.assertEqual(checker.validate_files(root,names), [])
            (root / 'data.json').write_text('invalid json')
            (root / 'README.md').write_text('[broken](docs/missing.md)')
            errors = checker.validate_files(root,names)
            self.assertEqual(len(errors),2)
            self.assertTrue(any('missing local link' in error for error in errors))

    def test_release_metadata_entrypoint_outputs_stable_app_version(self):
        script=str(CI / 'release_metadata.py')
        with tempfile.TemporaryDirectory() as directory, patch.object(sys,'argv',[script,'app-v1.2.3']):
            output=Path(directory)/'output'
            with patch.dict(os.environ,{'GITHUB_OUTPUT':str(output)}):
                runpy.run_path(script,run_name='__main__')
            self.assertEqual(output.read_text(),'kind=app\nversion=1.2.3\napp-version=1.2.3\n')
