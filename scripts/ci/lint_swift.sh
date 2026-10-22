#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo_root"
lint_bin="${SWIFTLINT_BIN:-swiftlint}"
expected_version="$(cat .swiftlint-version)"
if [ "$("$lint_bin" version)" != "$expected_version" ]; then
    echo "SwiftLint $expected_version is required (see .swiftlint-version)" >&2
    exit 1
fi
mkdir -p reports
# SwiftLint exits 2 for existing errors. Retain and validate the complete report
# before separately enforcing the no-new-violations gate with the baseline.
status=0
"$lint_bin" lint --config .swiftlint.yml --quiet --no-cache --reporter json --output reports/swiftlint-all.json || status=$?
if [ "$status" -gt 2 ]; then exit "$status"; fi
python3 - <<'PYCODE'
import json
from pathlib import Path
issues = json.loads(Path('reports/swiftlint-all.json').read_text())
if not isinstance(issues, list):
    raise SystemExit('Invalid SwiftLint report')
summary = f"SwiftLint: {len(issues)} total findings before the existing-debt baseline.\n"
print(summary, end='')
import os
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
        output.write(summary + 'Full findings: swiftlint-report artifact. New findings fail the check.\n')
PYCODE
"$lint_bin" lint --config .swiftlint.yml --baseline .swiftlint-baseline.json --strict --quiet --no-cache --reporter github-actions-logging
