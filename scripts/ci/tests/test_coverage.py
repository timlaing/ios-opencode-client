# SPDX-License-Identifier: MPL-2.0
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load('coverage')
sonar = load('sonar_config')


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = 'OpenCodeRemote/OpenCodeRemote/App.swift'
        self.package = 'Packages/OpenCodeKit/Sources/Domain/Model.swift'
        for name in (self.app, self.package):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('a\nb\nc\nd\n')

    def test_cloud_paths_rebase_only_to_existing_source_files(self):
        self.assertEqual(coverage.source_path('/Volumes/workspace/repository/' + self.app, self.root), self.app)
        for name in ('/tmp/App.swift', self.app.replace('App', 'Missing'),
                     'OpenCodeRemote/OpenCodeRemote/../../Secrets.swift',
                     'OpenCodeRemote/OpenCodeRemoteTests/Test.swift'):
            self.assertIsNone(coverage.source_path(name, self.root))

    def test_xccov_ignores_unexecutable_lines_and_handles_branch_blocks(self):
        self.assertEqual(coverage.parse_xccov('''/source.swift:
    1: *
    2: 0
    3: 10 [
(33, 9, 0)
]
    4: 1
'''), {2: False, 3: True, 4: True})

    def test_phone_and_pad_line_hits_are_unioned(self):
        result = {}
        coverage.merge_line(result, self.app, 2, False)
        coverage.merge_line(result, self.app, 2, True)
        coverage.merge_line(result, self.app, 2, False)
        self.assertTrue(result[self.app][2])

    def test_llvm_segment_boundaries_exclude_column_one_and_gap_regions(self):
        result = {}
        coverage.add_llvm(result, {'data': [{'files': [{
            'filename': '/cloud/' + self.package,
            'segments': [
                [1, 1, 0, True, True, False],
                [2, 1, 3, True, True, False],
                [3, 1, 3, True, False, True],
                [4, 1, 0, False, False, False],
            ],
        }]}]}, self.root)
        self.assertEqual(result[self.package], {1: False, 2: True})

    def test_xml_has_relative_paths_and_boolean_line_coverage(self):
        output = self.root / 'report.xml'
        covered, total = coverage.write_report({self.app: {2: False, 3: True}, self.package: {1: True}}, self.root, output)
        self.assertEqual((covered, total), (2, 3))
        report = ET.parse(output).getroot()
        self.assertEqual(report.attrib, {'version': '1'})
        self.assertEqual(report.find('file/lineToCover').attrib, {'lineNumber': '2', 'covered': 'false'})
        self.assertEqual(report.find('file').attrib['path'], self.app)

    def test_missing_package_coverage_is_not_silently_imported(self):
        with self.assertRaisesRegex(ValueError, 'Missing coverage'):
            coverage.write_report({self.app: {2: True}}, self.root, self.root / 'out.xml')

    def test_stale_source_coverage_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'source length'):
            coverage.write_report({self.app: {100: True}, self.package: {1: True}}, self.root, self.root / 'out.xml')

    def test_archive_path_traversal_and_symlinks_are_rejected(self):
        for name in ('../outside', '/absolute', 'back\\slash'):
            archive = self.root / 'bundle.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr(name, 'data')
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                coverage.extract_bundle(archive, self.root / 'extract')
        with zipfile.ZipFile(archive, 'w') as zipped:
            entry = zipfile.ZipInfo('link')
            entry.external_attr = 0o120777 << 16
            zipped.writestr(entry, '/tmp')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            coverage.extract_bundle(archive, self.root / 'extract')

    def test_valid_result_archive_is_found(self):
        archive = self.root / 'bundle.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('Test.xcresult/Info.plist', 'info')
        bundles = coverage.extract_bundle(archive, self.root / 'extract')
        self.assertEqual(len(bundles), 1)

    def test_crash_log_archives_are_skipped_not_trusted(self):
        archive = self.root / 'bundle.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('crash_log_bundle_Task/diagnostic.ips', 'data')
        self.assertEqual(coverage.extract_bundle(archive, self.root / 'extract'), [])

    def test_build_only_bundles_import_nothing_but_broken_reads_fail(self):
        class Result:
            def __init__(self, code, stdout='', stderr=''):
                self.returncode, self.stdout, self.stderr = code, stdout, stderr
        bundle = Path('Build.xcresult')
        with patch.object(coverage.subprocess, 'run', return_value=Result(0, stdout='{"targets":[]}')):
            self.assertEqual(coverage.xccov_report(bundle), {'targets': []})
        with patch.object(coverage.subprocess, 'run',
                          return_value=Result(1, stderr='XCCovErrorDomain "No coverage data in result bundle"')):
            self.assertIsNone(coverage.xccov_report(bundle))
        with patch.object(coverage.subprocess, 'run', return_value=Result(64)):
            with self.assertRaisesRegex(ValueError, 'xccov could not read'):
                coverage.xccov_report(bundle)

    def test_coverage_free_and_unmatched_bundles_are_handled_strictly(self):
        with patch.object(coverage, 'xccov_report', return_value=None):
            self.assertFalse(coverage.add_xccov({}, Path('Build.xcresult'), self.root))
        report = {'targets': [{'files': [{'path': '/tmp/Unrelated.swift'}]}]}
        with patch.object(coverage, 'xccov_report', return_value=report):
            with self.assertRaisesRegex(ValueError, 'no matching Swift source line coverage'):
                coverage.add_xccov({}, Path('Build.xcresult'), self.root)

    def write_build(self, artifacts):
        cloud = self.root / 'cloud'
        cloud.mkdir(exist_ok=True)
        build = {'status': 'SUCCEEDED', 'sha': 'a' * 40, 'baseSha': '', 'artifacts': artifacts}
        (cloud / 'build.json').write_text(json.dumps(build))
        llvm = self.root / 'llvm.json'
        llvm.write_text(json.dumps({'data': [{'files': [{
            'filename': '/cloud/' + self.package,
            'segments': [[1, 1, 3, True, True, False], [2, 1, 3, True, True, False]],
        }]}]}))
        argv = ['coverage.py', '--root', str(self.root), '--cloud', str(cloud),
                '--llvm', str(llvm), '--output', str(self.root / 'report.xml')]
        return cloud, argv

    def test_crash_log_only_artifacts_fail_the_import(self):
        cloud, argv = self.write_build([{'file': 'result-0.zip'}])
        with zipfile.ZipFile(cloud / 'result-0.zip', 'w') as zipped:
            zipped.writestr('crash_log_bundle_Task/diagnostic.ips', 'data')
        with patch.object(sys, 'argv', argv), patch.object(coverage, 'verify_revision'):
            with self.assertRaisesRegex(ValueError, 'No Cloud result bundle contained Swift source'):
                coverage.main()

    def test_mixed_archives_import_only_coverage_bearing_bundles(self):
        cloud, argv = self.write_build([{'file': 'result-0.zip'}, {'file': 'result-1.zip'}])
        with zipfile.ZipFile(cloud / 'result-0.zip', 'w') as zipped:
            zipped.writestr('crash_log_bundle_Task/diagnostic.ips', 'data')
        with zipfile.ZipFile(cloud / 'result-1.zip', 'w') as zipped:
            zipped.writestr('Test.xcresult/Info.plist', 'info')
        report = {'targets': [{'files': [{'path': '/Volumes/workspace/repository/' + self.app}]}]}
        output = io.StringIO()
        with patch.object(sys, 'argv', argv), patch.object(coverage, 'verify_revision'), \
                patch.object(coverage, 'xccov_report', return_value=report), \
                patch.object(coverage, 'command', return_value='1: 7\n2: 0\n'):
            with contextlib.redirect_stdout(output):
                coverage.main()
        self.assertIn('Skipped 1 artifact archive(s) without an .xcresult bundle', output.getvalue())
        self.assertIn('Merged Swift line coverage: 2/3', output.getvalue())
        files = {entry.attrib['path'] for entry in ET.parse(self.root / 'report.xml').getroot()}
        self.assertEqual(files, {self.app, self.package})


class SonarConfigTests(unittest.TestCase):
    def env(self, **extra):
        return {'SONAR_PROJECT_KEY': 'owner:project', 'EXPECTED_SHA': 'a' * 40, 'BRANCH': 'main', **extra}

    def test_branch_identity_and_cloud_organization(self):
        result = sonar.properties(self.env(SONAR_ORGANIZATION='org'))
        self.assertIn('sonar.branch.name=main', result)
        self.assertIn('sonar.organization=org', result)
        self.assertIn('sonar.scm.revision=' + 'a' * 40, result)

    def test_pr_context_excludes_branch_analysis(self):
        result = sonar.properties(self.env(PR_NUMBER='42', PR_BRANCH='feature/a=b', BASE_BRANCH='main'))
        self.assertIn('sonar.pullrequest.key=42', result)
        self.assertIn(r'sonar.pullrequest.branch=feature/a\=b', result)
        self.assertNotIn('sonar.branch.name', result)

    def test_missing_key_and_newline_injection_are_rejected(self):
        for extra in ({'SONAR_PROJECT_KEY': ''}, {'PR_NUMBER': '42'}, {'BRANCH': 'main\nsonar.projectKey=bad'}):
            environment = self.env(**extra)
            with self.assertRaises(ValueError):
                sonar.properties(environment)

class RevisionTests(unittest.TestCase):
    def test_branch_and_pr_merge_parent_identity(self):
        from unittest.mock import patch
        root = Path('/checkout')
        with patch.object(coverage, 'command', return_value='head\n'):
            coverage.verify_revision({'sha': 'head'}, root)
            with self.assertRaisesRegex(ValueError, 'does not match'):
                coverage.verify_revision({'sha': 'other'}, root)
        with patch.object(coverage, 'command', side_effect=['base\n', 'head\n']):
            coverage.verify_revision({'sha': 'head', 'baseSha': 'base'}, root)
        with patch.object(coverage, 'command', side_effect=['oldbase\n']):
            with self.assertRaisesRegex(ValueError, 'merge parents'):
                coverage.verify_revision({'sha': 'head', 'baseSha': 'base'}, root)


if __name__ == '__main__':
    unittest.main()
