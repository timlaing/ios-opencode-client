#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Xcode Cloud discovers this beside OpenCodeRemote.xcodeproj.
set -eu
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
package_path="$repo_root/Packages/OpenCodeKit"

# These package tests are not part of the app scheme. Fail the Cloud action
# if they fail, and include their coverage report in the post-clone log.
swift test --package-path "$package_path" --enable-code-coverage
coverage_path="$(swift test --package-path "$package_path" --show-codecov-path)"
# Use SwiftPM's exported JSON instead of assuming a test-binary layout:
# SwiftPM's native and Xcode build systems use different bundle names.
python3 - "$coverage_path" "$package_path/Sources/" <<'PYCODE'
import json
import sys

with open(sys.argv[1]) as report:
    data = json.load(report)
covered = count = 0
print("OpenCodeKit source line coverage (excluding tests and dependencies):")
for unit in data["data"]:
    for source in unit["files"]:
        if not source["filename"].startswith(sys.argv[2]):
            continue
        lines = source["summary"]["lines"]
        covered += lines["covered"]
        count += lines["count"]
        print(f'{lines["percent"]:6.2f}%  {source["filename"]}')
if not count:
    raise SystemExit("No OpenCodeKit source coverage found")
print(f"TOTAL: {covered}/{count} lines ({100 * covered / count:.2f}%)")
PYCODE
