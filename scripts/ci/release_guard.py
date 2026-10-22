# SPDX-License-Identifier: MPL-2.0
"""Fail-closed publication checks; never execute package lifecycle code."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile

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


def check_package(path, expected_hash, expected_version, dist_tag, registry_tags, expected_name='opencode-push-relay', existing_integrity=None):
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
    if expected_name not in {'opencode-push-relay', '@timlaing/opencode-push-relay'}:
        raise ValueError('Unexpected package name')
    if package.get('name') != expected_name or package.get('version') != expected_version:
        raise ValueError('Package metadata does not match release')
    if dist_tag != ('next' if '-' in expected_version else 'latest'):
        raise ValueError('Unexpected npm dist-tag')
    version_key(expected_version)
    if existing_integrity is not None:
        integrity = 'sha512-' + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()
        if existing_integrity != integrity:
            raise ValueError('Existing package version has different contents; refuse to overwrite')
        return False
    current = registry_tags.get(dist_tag)
    if current and version_key(expected_version) <= version_key(current):
        raise ValueError(f'Refusing to move {dist_tag} to an older or equal version')
    return True


def registry_json(name, registry, field=None):
    args = ['npm', 'view', name]
    if field:
        args.append(field)
    args.extend(['--json', '--registry', registry])
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        # npm's --json error record distinguishes first publication from auth,
        # networking and registry failures. Never print registry/token output.
        for content in (result.stdout, result.stderr):
            try:
                error = json.loads(content)
            except (ValueError, TypeError):
                continue
            if isinstance(error, dict) and error.get('error', {}).get('code') == 'E404':
                return None
        raise ValueError('Registry lookup failed; check registry access and credentials')
    return json.loads(result.stdout or 'null')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['verify-tag', 'environment', 'check-package'])
    args = parser.parse_args(argv)
    try:
        if args.mode == 'verify-tag':
            verify_tag()
        elif args.mode == 'environment':
            require_environment(os.environ['GITHUB_REPOSITORY'], os.environ['RELEASE_KIND'])
        else:
            name = os.environ.get('PACKAGE_NAME', 'opencode-push-relay')
            registry = os.environ.get('PACKAGE_REGISTRY', 'https://registry.npmjs.org')
            targets = {'opencode-push-relay': 'https://registry.npmjs.org',
                       '@timlaing/opencode-push-relay': 'https://npm.pkg.github.com'}
            if targets.get(name) != registry:
                raise ValueError('Unexpected package/registry pair')
            version = os.environ['RELEASE_VERSION']
            version_key(version)
            tags = registry_json(name, registry, 'dist-tags') or {}
            if not isinstance(tags, dict):
                raise ValueError('Invalid registry distribution tags')
            published = registry_json(f'{name}@{version}', registry)
            integrity = None
            if published is not None:
                if not isinstance(published, dict) or published.get('version') != version:
                    raise ValueError('Invalid existing package version metadata')
                integrity = published.get('dist', {}).get('integrity')
                if not integrity:
                    raise ValueError('Existing version cannot be verified without its integrity')
            publish = check_package(os.environ.get('PACKAGE_TARBALL', 'release/package.tgz'),
                                    os.environ['PACKAGE_SHA256'], version, os.environ['DIST_TAG'],
                                    tags, name, integrity)
            if os.environ.get('GITHUB_OUTPUT'):
                with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                    output.write(f'publish={str(publish).lower()}\n')
            print('Package verified for publication' if publish else 'Identical version already published; skipping without moving tags')
    except (ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
