# SPDX-License-Identifier: MPL-2.0
"""Fail-closed publication checks; never execute package lifecycle code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

from release_metadata import parse_tag
from require_release_checks import api, require_environment


def identity():
    repository = os.environ['GITHUB_REPOSITORY']
    tag = os.environ['RELEASE_TAG']
    sha = os.environ['RELEASE_SHA']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', repository) or not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid release identity')
    parse_tag(tag)
    return repository, tag, sha


def verify_tag():
    repository, tag, sha = identity()
    if api(f'repos/{repository}/commits/{tag}')['sha'] != sha:
        raise ValueError('Release tag moved after validation')


def app_receipt_exists():
    repository, tag, _ = identity()
    if parse_tag(tag)[0] != 'app':
        raise ValueError('Expected an app release')
    release = api(f'repos/{repository}/releases/tags/{tag}')
    return any(asset['name'] == 'app-uploaded.json' for asset in release['assets'])


def check_app():
    verify_tag()
    if app_receipt_exists():
        raise ValueError('This app tag was already uploaded')


def record_app():
    repository, tag, sha = identity()
    with tempfile.TemporaryDirectory(prefix='opencode-upload-') as directory:
        path = Path(directory) / 'app-uploaded.json'
        path.write_text(json.dumps({'tag': tag, 'sha': sha, 'build': parse_tag(tag)[2]}) + '\n')
        subprocess.run(['gh', 'release', 'upload', tag, str(path), '--repo', repository], check=True)


def version_key(version):
    match = re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?', version)
    if not match:
        raise ValueError('Invalid semantic version')
    major, minor, patch, suffix = match.groups()
    identifiers = (suffix or '').split('.') if suffix else []
    if any(not part or (part.isdigit() and len(part) > 1 and part.startswith('0')) for part in identifiers):
        raise ValueError('Invalid prerelease identifier')
    prerelease = tuple((0, int(part)) if part.isdigit() else (1, part) for part in identifiers)
    return int(major), int(minor), int(patch), not bool(suffix), prerelease


def check_package(path, expected_hash, expected_version, dist_tag, registry_tags):
    path = Path(path).resolve(strict=True)
    if path.suffix != '.tgz' or not path.is_file():
        raise ValueError('Expected a package tarball')
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    if not re.fullmatch(r'[0-9a-f]{64}', expected_hash) or digest != expected_hash:
        raise ValueError('Package artifact digest mismatch')
    with tarfile.open(path, 'r:gz') as archive:
        member = archive.getmember('package/package.json')
        if not member.isfile() or member.size > 1_000_000:
            raise ValueError('Invalid package metadata')
        with archive.extractfile(member) as stream:
            package = json.load(stream)
    if package.get('name') != 'opencode-push-relay' or package.get('version') != expected_version:
        raise ValueError('Package metadata does not match release')
    if dist_tag != ('next' if '-' in expected_version else 'latest'):
        raise ValueError('Unexpected npm dist-tag')
    current = registry_tags.get(dist_tag)
    if current and version_key(expected_version) <= version_key(current):
        raise ValueError(f'Refusing to move {dist_tag} to an older or equal version')
    version_key(expected_version)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['verify-tag', 'environment', 'check-app', 'record-app', 'check-package'])
    args = parser.parse_args(argv)
    try:
        if args.mode == 'verify-tag':
            verify_tag()
        elif args.mode == 'environment':
            require_environment(os.environ['GITHUB_REPOSITORY'], os.environ['RELEASE_KIND'])
        elif args.mode == 'check-app':
            check_app()
        elif args.mode == 'record-app':
            record_app()
        else:
            tags = json.loads(subprocess.check_output(['npm', 'view', 'opencode-push-relay', 'dist-tags', '--json']))
            check_package('release/package.tgz', os.environ['PACKAGE_SHA256'], os.environ['RELEASE_VERSION'], os.environ['DIST_TAG'], tags)
    except (ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
