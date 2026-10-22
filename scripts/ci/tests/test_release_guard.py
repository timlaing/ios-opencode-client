# SPDX-License-Identifier: MPL-2.0
import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from test_helpers import load

guard = load('release_guard')

class PublicationTests(unittest.TestCase):
    def package(self, directory, version='1.2.3'):
        path = Path(directory) / 'package.tgz'
        raw = json.dumps({'name': 'opencode-push-relay', 'version': version}).encode()
        with tarfile.open(path, 'w:gz') as archive:
            info = tarfile.TarInfo('package/package.json')
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        return path, digest

    def test_artifact_digest_metadata_and_channel_must_match(self):
        with tempfile.TemporaryDirectory() as directory:
            path, digest = self.package(directory)
            guard.check_package(path, digest, '1.2.3', 'latest', {'latest': '1.2.2'})
            for bad_hash, version, channel in [('0'*64, '1.2.3', 'latest'), (digest, '9.9.9', 'latest'), (digest, '1.2.3', 'next')]:
                with self.subTest(version=version, channel=channel), self.assertRaises(ValueError):
                    guard.check_package(path, bad_hash, version, channel, {})

    def test_equal_or_older_dist_tag_versions_are_blocked(self):
        for version, channel, current in [('1.2.3', 'latest', '2.0.0'), ('1.2.3', 'latest', '1.2.3'), ('2.0.0-beta.1', 'next', '2.0.0-beta.2')]:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                path, digest = self.package(directory, version)
                with self.assertRaisesRegex(ValueError, 'older or equal'):
                    guard.check_package(path, digest, version, channel, {channel: current})

    def test_prerelease_order_is_semantic(self):
        ordered = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '1.0.1']
        self.assertEqual(sorted(ordered, key=guard.version_key), ordered)
        for invalid in ['01.0.0', '1.0.0-a..b', '1.0.0-01', '--help']:
            with self.assertRaises(ValueError): guard.version_key(invalid)

    def test_moved_tag_blocks_publication(self):
        env = {'GITHUB_REPOSITORY': 'owner/repo', 'RELEASE_TAG': 'plugin-v1.2.3', 'RELEASE_SHA': 'a'*40}
        with patch.dict(os.environ, env), patch.object(guard, 'api', return_value={'sha': 'b'*40}) as api:
            with self.assertRaisesRegex(ValueError, 'moved'): guard.verify_tag()
            api.assert_called_once_with('repos/owner/repo/commits/plugin-v1.2.3')

    def test_app_receipt_prevents_repeat_upload(self):
        env = {'GITHUB_REPOSITORY': 'owner/repo', 'RELEASE_TAG': 'app-v1.2.3', 'RELEASE_SHA': 'a'*40}
        with patch.dict(os.environ, env):
            with patch.object(guard, 'api', side_effect=[{'sha': 'a'*40}, {'assets': [{'name': 'app-uploaded.json'}]}]):
                with self.assertRaisesRegex(ValueError, 'already uploaded'): guard.check_app()
            with patch.object(guard, 'api', side_effect=[{'sha': 'a'*40}, {'assets': []}]): guard.check_app()
            with patch.object(guard.subprocess, 'run') as run:
                guard.record_app()
                self.assertEqual(run.call_args.args[0][:4], ['gh', 'release', 'upload', 'app-v1.2.3'])
                self.assertEqual(run.call_args.args[0][-2:], ['--repo', 'owner/repo'])

    def test_invalid_release_identity_is_rejected(self):
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': '../bad', 'RELEASE_TAG': 'app-v1.2.3', 'RELEASE_SHA': 'a'*40}):
            with self.assertRaises(ValueError): guard.identity()

    def test_cli_verifies_artifact_and_rejects_tampering_without_running_package_code(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / 'release'
            release.mkdir()
            path, digest = self.package(release)
            previous = Path.cwd()
            try:
                os.chdir(directory)
                env = {'PACKAGE_SHA256':digest, 'RELEASE_VERSION':'1.2.3', 'DIST_TAG':'latest'}
                with patch.dict(os.environ, env), patch.object(guard.subprocess, 'check_output', return_value=b'{"latest":"1.2.2"}') as command:
                    guard.main(['check-package'])
                    command.assert_called_once_with(['npm','view','opencode-push-relay','dist-tags','--json'])
                with patch.dict(os.environ, {**env,'PACKAGE_SHA256':'0'*64}), patch.object(guard.subprocess,'check_output',return_value=b'{}'):
                    with self.assertRaisesRegex(SystemExit,'digest mismatch'):
                        guard.main(['check-package'])
            finally:
                os.chdir(previous)
