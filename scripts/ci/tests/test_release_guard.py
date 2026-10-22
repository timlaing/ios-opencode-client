# SPDX-License-Identifier: MPL-2.0
import hashlib
import base64
import subprocess
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

    def test_app_tags_are_rejected_before_publication(self):
        env = {'GITHUB_REPOSITORY': 'owner/repo', 'RELEASE_TAG': 'app-v1.2.3', 'RELEASE_SHA': 'a'*40}
        with patch.dict(os.environ, env), patch.object(guard, 'api') as api:
            with self.assertRaisesRegex(ValueError, 'plugins only'):
                guard.verify_tag()
            api.assert_not_called()

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
                env = {'PACKAGE_SHA256':digest, 'RELEASE_VERSION':'1.2.3', 'DIST_TAG':'latest', 'GITHUB_OUTPUT': str(Path(directory)/'output')}
                with patch.dict(os.environ, env), patch.object(guard, 'registry_json', side_effect=[{'latest':'1.2.2'}, None]) as command:
                    guard.main(['check-package'])
                    self.assertEqual(command.call_count, 2)
                    self.assertEqual((Path(directory)/'output').read_text(), 'publish=true\n')
                with patch.dict(os.environ, {**env,'PACKAGE_SHA256':'0'*64}), patch.object(guard,'registry_json',side_effect=[{}, None]):
                    with self.assertRaisesRegex(SystemExit,'digest mismatch'):
                        guard.main(['check-package'])
            finally:
                os.chdir(previous)


class RegistryTests(unittest.TestCase):
    def test_first_publication_404_is_allowed_but_auth_errors_fail(self):
        for code, missing in [('E404', True), ('E401', False), ('E403', False)]:
            result = subprocess.CompletedProcess([], 1, json.dumps({'error': {'code': code}}), '')
            with self.subTest(code=code), patch.object(guard.subprocess, 'run', return_value=result):
                if missing:
                    self.assertIsNone(guard.registry_json('opencode-push-relay', 'https://registry.npmjs.org'))
                else:
                    with self.assertRaisesRegex(ValueError, 'Registry lookup failed'):
                        guard.registry_json('opencode-push-relay', 'https://registry.npmjs.org')

    def test_rerun_skips_identical_published_bytes_without_rolling_back_tags(self):
        helper = PublicationTests()
        with tempfile.TemporaryDirectory() as directory:
            path, digest = helper.package(directory)
            integrity = 'sha512-' + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()
            self.assertFalse(guard.check_package(path, digest, '1.2.3', 'latest', {'latest': '2.0.0'}, existing_integrity=integrity))
            with self.assertRaisesRegex(ValueError, 'different contents'):
                guard.check_package(path, digest, '1.2.3', 'latest', {}, existing_integrity='sha512-wrong')

    def test_package_registry_mismatch_fails_before_lookup(self):
        with patch.dict(os.environ, {'PACKAGE_NAME': '@timlaing/opencode-push-relay', 'PACKAGE_REGISTRY': 'https://registry.npmjs.org'}), patch.object(guard, 'registry_json') as registry:
            with self.assertRaisesRegex(SystemExit, 'package/registry pair'):
                guard.main(['check-package'])
            registry.assert_not_called()


class MirrorTests(unittest.TestCase):
    def test_github_mirror_preserves_code_and_is_deterministic(self):
        mirror = load('package_mirror')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'npm.tgz'
            files = {'package/package.json': json.dumps({'name':'opencode-push-relay','version':'1.2.3','exports':{'.':'./dist/index.js'}}).encode(),
                     'package/dist/index.js': b'export const tested = true;\n'}
            with tarfile.open(source,'w:gz') as archive:
                for name, raw in files.items():
                    info=tarfile.TarInfo(name); info.size=len(raw); info.mode=0o644
                    archive.addfile(info,io.BytesIO(raw))
            first, second = root/'github.tgz', root/'again.tgz'
            mirror.mirror_package(source,first)
            mirror.mirror_package(source,second)
            self.assertEqual(first.read_bytes(),second.read_bytes())
            with tarfile.open(first,'r:gz') as archive:
                metadata=json.load(archive.extractfile('package/package.json'))
                self.assertEqual(metadata['name'],'@timlaing/opencode-push-relay')
                self.assertEqual(archive.extractfile('package/dist/index.js').read(),files['package/dist/index.js'])
                self.assertEqual(metadata['exports'],{'.':'./dist/index.js'})
            digest=hashlib.sha256(first.read_bytes()).hexdigest()
            self.assertTrue(guard.check_package(first,digest,'1.2.3','latest',{},'@timlaing/opencode-push-relay'))

    def test_mirror_rejects_unsafe_archive_members(self):
        mirror=load('package_mirror')
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'bad.tgz'
            with tarfile.open(source,'w:gz') as archive:
                info=tarfile.TarInfo('../outside'); info.size=1
                archive.addfile(info,io.BytesIO(b'x'))
            with self.assertRaises(ValueError):
                mirror.mirror_package(source,Path(directory)/'out.tgz')
