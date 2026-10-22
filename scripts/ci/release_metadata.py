# SPDX-License-Identifier: MPL-2.0
"""Validate separate app/plugin release tags and emit workflow outputs."""
import os
import re
import sys

def parse_tag(tag):
    match = re.fullmatch(r'(app|plugin)-v(\d+\.\d+\.\d+)(-[0-9A-Za-z.-]+)?', tag)
    if not match:
        raise ValueError('Use app-vX.Y.Z or plugin-vX.Y.Z, optionally with a prerelease suffix')
    kind, version, suffix = match.groups()
    return kind, version + (suffix or ''), version

if __name__ == '__main__':
    kind, version, app_version = parse_tag(sys.argv[1])
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'kind={kind}\nversion={version}\napp-version={app_version}\n')
