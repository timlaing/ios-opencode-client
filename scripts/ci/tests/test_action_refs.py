# SPDX-License-Identifier: MPL-2.0
import contextlib
import importlib.util
import io
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'check_action_refs.py'
spec = importlib.util.spec_from_file_location('check_action_refs', SCRIPT)
refs = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = refs
spec.loader.exec_module(refs)

class ActionPinTests(unittest.TestCase):
    def test_floating_short_or_inconsistent_refs_fail(self):
        path = refs.WORKFLOW_DIR / 'tests.yml'
        def item(ref, comment=' # v7'):
            return refs.Reference('actions/checkout', ref, path, 1, 'uses: actions/checkout@'+ref+comment)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(refs.check_references([item('a'*40)]), 0)
            for values in [[item('v7')], [item('a'*7)], [item('a'*40, '')], [item('a'*40), item('b'*40)]]:
                self.assertGreater(refs.check_references(values), 0)
            with patch.dict('os.environ', {'GITHUB_ACTIONS': 'true'}):
                refs.report('bad', item('v7'))

    def test_workflow_paths_cannot_escape_or_follow_external_symlinks(self):
        with tempfile.TemporaryDirectory() as outside, tempfile.TemporaryDirectory(dir=refs.WORKFLOW_DIR) as inside:
            target = Path(outside) / 'private.yml'
            target.write_text('secret-like content never read')
            link = Path(inside) / 'external.yml'
            link.symlink_to(target)
            for path in [target, link, refs.WORKFLOW_DIR / '../../../etc/passwd']:
                with self.assertRaises((OSError, ValueError)): refs.collect_references([path])

    def test_cli_only_accepts_repo_yaml_and_checks_sha_annotations(self):
        with tempfile.TemporaryDirectory(dir=refs.WORKFLOW_DIR) as directory:
            file = Path(directory) / 'sample.yml'
            file.write_text('steps:\n  - uses: actions/checkout@'+'a'*40+' # v7\n')
            self.assertEqual(refs.resolve_paths([Path(directory)]), [file.resolve()])
            found = refs.collect_references([file])
            self.assertEqual(found[0].ref, 'a'*40)
            with patch.object(sys, 'argv', [str(SCRIPT), str(file)]), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(refs.main(), 0)
            file.write_text('steps:\n  - uses: actions/checkout@v7\n')
            with patch.object(sys, 'argv', [str(SCRIPT), str(file)]), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(refs.main(), 1)
            non_yaml = Path(directory) / 'bad.txt'
            non_yaml.write_text('no')
            with self.assertRaises(ValueError): refs.collect_references([non_yaml])
            for path in ['/tmp', directory+'/missing']:
                with patch.object(sys, 'argv', [str(SCRIPT), path]), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(refs.main(), 2)
