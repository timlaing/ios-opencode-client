# SPDX-License-Identifier: MPL-2.0
import importlib.util
from pathlib import Path
import tempfile
import sys
import unittest
import xml.etree.ElementTree as ET

def load(name):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

coverage = load('swift_coverage')
release = load('release_metadata')

class CoverageTests(unittest.TestCase):
    def test_only_repository_sources_and_duplicate_hits_are_merged(self):
        source = next((coverage.ROOT / 'Packages/OpenCodeKit/Sources').rglob('*.swift')).relative_to(coverage.ROOT).as_posix()
        data = coverage.parse_lcov(f'SF:{coverage.ROOT}/{source}\nDA:1,0\nDA:2,3\nend_of_record\nSF:{source}\nDA:1,1\nend_of_record\nSF:/tmp/vendor.swift\nDA:1,4\n')
        self.assertEqual(data, {source: {1: True, 2: True}})
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'coverage.xml'
            coverage.write_report(data, output)
            self.assertEqual(ET.parse(output).getroot().find('file').attrib['path'], source)
    def test_empty_coverage_fails(self):
        with self.assertRaises(ValueError):
            coverage.write_report({}, '/dev/null')
    def test_invalid_paths_are_excluded(self):
        for path in ['../bad.swift', '/tmp/vendor.swift', 'Packages/OpenCodeKit/.build/vendor.swift']:
            self.assertIsNone(coverage.repo_path(path))

class ReleaseTests(unittest.TestCase):
    def test_versions_are_separate(self):
        self.assertEqual(release.parse_tag('plugin-v0.1.0-beta.1'), ('plugin', '0.1.0-beta.1', '0.1.0'))
        self.assertEqual(release.parse_tag('plugin-v1.2.3'), ('plugin', '1.2.3', '1.2.3'))
    def test_arbitrary_refs_are_rejected(self):
        for value in ['main', 'v1.2.3', 'app-v1.2', 'app-v1.2.3', 'plugin-v01.2.3', 'plugin-v1.2.3-01', 'plugin-v1.2.3;echo bad']:
            with self.assertRaises(ValueError):
                release.parse_tag(value)


class ReleaseGateTests(unittest.TestCase):
    def test_skipped_sonar_blocks_release(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        sha = 'a' * 40
        run = {'id': 10, 'head_sha': sha, 'head_branch': 'main', 'conclusion': 'success'}
        with patch.object(gate, 'api', side_effect=[{'workflow_runs': [run]}, {'jobs': [{'name': 'Native Cloud and SonarQube / Required CI', 'conclusion': 'skipped'}]}]):
            with self.assertRaisesRegex(ValueError, 'Sonar'):
                gate.require_checks('owner/repo', sha)
    def test_all_exact_commit_checks_pass(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        sha = 'b' * 40
        run = {'id': 10, 'head_sha': sha, 'head_branch': 'main', 'conclusion': 'success'}
        with patch.object(gate, 'api', side_effect=[{'workflow_runs': [run]}, {'jobs': [{'name': 'Native Cloud and SonarQube / Required CI', 'conclusion': 'success'}]}, {'workflow_runs': [run]}, {'workflow_runs': [run]}]) as api:
            gate.require_checks('owner/repo', sha)
            self.assertEqual(api.call_count, 4)
            self.assertIn('/linting.yml/runs?', api.call_args.args[0])
    def test_missing_or_failed_lint_blocks_release(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        sha = 'b' * 40
        run = {'id': 10, 'head_sha': sha, 'head_branch': 'main', 'conclusion': 'success'}
        for lint in ([], [{**run, 'conclusion': 'failure'}], [{**run, 'conclusion': 'skipped'}]):
            with self.subTest(lint=lint), patch.object(gate, 'api', side_effect=[
                {'workflow_runs': [run]},
                {'jobs': [{'name': 'Native Cloud and SonarQube / Required CI', 'conclusion': 'success'}]},
                {'workflow_runs': [run]}, {'workflow_runs': lint},
            ]):
                with self.assertRaisesRegex(ValueError, 'linting.yml'):
                    gate.require_checks('owner/repo', sha)

    def test_other_branch_or_sha_cannot_satisfy_gate(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        run = {'id': 10, 'head_sha': 'c' * 40, 'head_branch': 'feature', 'conclusion': 'success'}
        with patch.object(gate, 'api', return_value={'workflow_runs': [run]}):
            with self.assertRaisesRegex(ValueError, 'no main push'):
                gate.require_checks('owner/repo', 'c' * 40)


class XccovTests(unittest.TestCase):
    def test_xccov_counts_merge_across_targets(self):
        from unittest.mock import patch
        import json
        source = next((coverage.ROOT / 'OpenCodeRemote/OpenCodeRemote').rglob('*.swift'))
        report = {'targets': [{'files': [{'path': str(source)}]}, {'files': [{'path': str(source)}]}]}
        with tempfile.TemporaryDirectory(suffix='.xcresult') as bundle:
            with patch.object(coverage.subprocess, 'check_output', side_effect=[json.dumps(report).encode(), '  1: 0\n  2: 4\n  3: *\n', '  1: 2\n  2: 0\n']) as command:
                data = coverage.parse_xccov(bundle)
                self.assertEqual(command.call_args.args[0][-1], str(Path(bundle).resolve()))
                self.assertEqual(command.call_args.args[0][-2], str(source.resolve()))
        self.assertEqual(data, {source.relative_to(coverage.ROOT).as_posix(): {1: True, 2: True}})


class EnvironmentTests(unittest.TestCase):
    def test_publishing_requires_environment_reviewers(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        with patch.object(gate, 'api', return_value={'protection_rules': []}) as api:
            with self.assertRaisesRegex(ValueError, 'required reviewers'):
                gate.require_environment('owner/repo', 'plugin')
            api.assert_called_once_with('repos/owner/repo/environments/npm')
        with patch.object(gate, 'api', return_value={'protection_rules': [{'type': 'required_reviewers', 'reviewers': [{'type': 'User'}]}]}) as api:
            gate.require_environment('owner/repo', 'plugin')
            api.assert_called_once_with('repos/owner/repo/environments/npm')


class GateRegressionTests(unittest.TestCase):
    def test_missing_failed_or_newer_failed_codeql_blocks_release(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        sha = 'a' * 40
        run = {'id': 10, 'head_sha': sha, 'head_branch': 'main', 'conclusion': 'success'}
        for codeql in [[], [{**run, 'conclusion': 'failure'}], [run, {**run, 'id': 11, 'conclusion': 'failure'}]]:
            with self.subTest(codeql=codeql), patch.object(gate, 'api', side_effect=[{'workflow_runs': [run]}, {'jobs': [{'name': 'Native Cloud and SonarQube / Required CI', 'conclusion': 'success'}]}, {'workflow_runs': codeql}]) as api:
                with self.assertRaisesRegex(ValueError, 'codeql'):
                    gate.require_checks('owner/repo', sha)
                self.assertEqual(api.call_count, 3)
    def test_main_with_wrong_sha_is_rejected(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        run = {'id': 10, 'head_sha': 'b' * 40, 'head_branch': 'main', 'conclusion': 'success'}
        with patch.object(gate, 'api', return_value={'workflow_runs': [run]}):
            with self.assertRaisesRegex(ValueError, 'no main push'):
                gate.require_checks('owner/repo', 'a' * 40)
    def test_invalid_identity_and_kind_fail_before_api(self):
        from unittest.mock import patch
        gate = load('require_release_checks')
        with patch.object(gate, 'api') as api:
            with self.assertRaises(ValueError): gate.require_checks('owner/repo', '--help')
            with self.assertRaises(ValueError): gate.require_environment('owner/repo', 'other')
            api.assert_not_called()
    def test_app_prerelease_is_not_silently_remapped(self):
        with self.assertRaisesRegex(ValueError, 'plugins only'):
            release.parse_tag('app-v1.2.3-beta.1')
    def test_xccov_rejects_invalid_bundle_before_subprocess(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory, patch.object(coverage.subprocess, 'check_output') as command:
            with self.assertRaises(ValueError): coverage.parse_xccov(directory)
            command.assert_not_called()
