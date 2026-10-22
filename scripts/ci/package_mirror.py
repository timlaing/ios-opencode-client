# SPDX-License-Identifier: MPL-2.0
"""Create the GitHub-scoped mirror without rebuilding or executing package code."""
import copy
import gzip
import io
import json
from pathlib import Path
import sys
import tarfile


def mirror_package(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Mirror output must differ from its input')
    with tarfile.open(source, 'r:gz') as archive:
        members = archive.getmembers()
        names = [entry.name for entry in members]
        if len(names) != len(set(names)) or names.count('package/package.json') != 1:
            raise ValueError('Ambiguous package archive')
        for entry in members:
            if not entry.name.startswith('package/') or '..' in Path(entry.name).parts or not (entry.isfile() or entry.isdir()):
                raise ValueError('Unexpected package entry')
        metadata = archive.getmember('package/package.json')
        if metadata.size > 1_000_000:
            raise ValueError('Package metadata exceeds size limit')
        with archive.extractfile(metadata) as stream:
            package = json.load(stream)
        if package.get('name') != 'opencode-push-relay':
            raise ValueError('Expected the npm plugin package')
        package['name'] = '@timlaing/opencode-push-relay'
        raw = (json.dumps(package, indent=2) + '\n').encode()
        # mtime and the gzip filename are fixed, so repeated builds of a given
        # input produce an identical mirror (important for safe registry retries).
        with destination.open('xb') as output:
            with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w') as target:
                    for member in members:
                        info = copy.copy(member)
                        if member.name == 'package/package.json':
                            info.size = len(raw)
                            target.addfile(info, io.BytesIO(raw))
                        elif member.isfile():
                            with archive.extractfile(member) as stream:
                                target.addfile(info, stream)
                        else:
                            target.addfile(info)


if __name__ == '__main__':
    mirror_package(sys.argv[1], sys.argv[2])
