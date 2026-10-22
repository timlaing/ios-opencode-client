# SPDX-License-Identifier: MPL-2.0
"""Validate plugin-only GitHub release tags and emit workflow outputs."""
import os
import re
import sys


def parse_tag(tag):
    match = re.fullmatch(r'plugin-v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?', tag)
    if not match:
        raise ValueError('GitHub releases publish plugins only: use plugin-vX.Y.Z with an optional prerelease suffix')
    version, suffix = match.groups()
    if suffix and any(part.isdigit() and len(part) > 1 and part.startswith('0') for part in suffix[1:].split('.')):
        raise ValueError('Invalid numeric prerelease identifier')
    return 'plugin', version + (suffix or ''), version


if __name__ == '__main__':
    kind, version, _ = parse_tag(sys.argv[1])
    prerelease = os.environ.get('RELEASE_PRERELEASE', '')
    if prerelease in {'true', 'false'} and (prerelease == 'true') != ('-' in version):
        raise ValueError('GitHub prerelease flag must match the plugin version suffix')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'kind={kind}\nversion={version}\n')
