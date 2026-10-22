# SPDX-License-Identifier: MPL-2.0
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile


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
            with self.assertRaises(ValueError):
                sonar.properties(self.env(**extra))

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
