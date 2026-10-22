# SPDX-License-Identifier: MPL-2.0
"""Require consistent immutable action pins inside this repository's workflow tree."""
from __future__ import annotations
import argparse
from collections import defaultdict
from dataclasses import dataclass
import os
from pathlib import Path
import re

WORKFLOW_DIR = Path(__file__).resolve().parents[1] / '.github/workflows'
FULL_SHA_PATTERN = re.compile(r'^[0-9a-f]{40}$')
USES_PATTERN = re.compile(r"^[^#]*uses:\s*['\"]?(?P<action>[\w.-]+(?:/[\w.-]+)+)@(?P<ref>[\w.+/-]+)")
VERSION_COMMENT_PATTERN = re.compile(r'#\s*v\d+(?:\.\d+)*\s*$')

@dataclass(frozen=True)
class Reference:
    action: str
    ref: str
    path: Path
    line: int
    line_text: str

def checked_path(path):
    resolved = Path(path).resolve(strict=True)
    if not resolved.is_relative_to(WORKFLOW_DIR):
        raise ValueError('Workflow paths must stay inside .github/workflows')
    return resolved

def resolve_paths(paths):
    result = []
    for path in paths:
        path = checked_path(path)
        candidates = sorted(path.iterdir()) if path.is_dir() else [path]
        for candidate in candidates:
            candidate = checked_path(candidate)
            if candidate.is_file() and candidate.suffix in {'.yml', '.yaml'}:
                result.append(candidate)
    return result

def collect_references(paths):
    result = []
    for value in paths:
        path = checked_path(value)
        if path.suffix not in {'.yml', '.yaml'} or not path.is_file():
            raise ValueError('Expected a YAML workflow file')
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if match := USES_PATTERN.search(line):
                result.append(Reference(match['action'], match['ref'], path, number, line))
    return result

def report(message, reference):
    path = reference.path.relative_to(WORKFLOW_DIR.parents[1])
    if 'GITHUB_ACTIONS' in os.environ:
        print(f'::error file={path},line={reference.line}::{message}')
    else:
        print(f'{path}:{reference.line}: {message}')

def check_references(references):
    failures = 0
    by_repo = defaultdict(set)
    for reference in references:
        repo = '/'.join(reference.action.split('/')[:2])
        by_repo[repo].add(reference.ref)
        if not FULL_SHA_PATTERN.fullmatch(reference.ref):
            report('Remote actions must use a full immutable commit SHA', reference)
            failures += 1
        elif not VERSION_COMMENT_PATTERN.search(reference.line_text):
            report('SHA pins need a trailing version comment for Dependabot', reference)
            failures += 1
    for reference in references:
        if len(by_repo['/'.join(reference.action.split('/')[:2])]) > 1:
            report('Action repository uses inconsistent SHA pins', reference)
            failures += 1
    return failures

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workflows', type=Path, nargs='*', default=[WORKFLOW_DIR])
    args = parser.parse_args()
    try:
        paths = resolve_paths(args.workflows)
        if not paths:
            raise ValueError('No workflow files found')
        references = collect_references(paths)
    except (OSError, ValueError) as error:
        print(f'error: {error}')
        return 2
    failures = check_references(references)
    if failures:
        return 1
    print(f'{len(references)} action references use consistent full-SHA pins')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
