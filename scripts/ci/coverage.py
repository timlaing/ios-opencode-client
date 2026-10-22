# SPDX-License-Identifier: MPL-2.0
"""Merge Xcode Cloud xccov and SwiftPM LLVM line coverage into Sonar generic XML."""
import argparse
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import xml.etree.ElementTree as ET
import zipfile

SOURCE_ROOTS = ('OpenCodeRemote/OpenCodeRemote/', 'Packages/OpenCodeKit/Sources/')


def source_path(filename, root):
    """Map a Cloud checkout path to an existing, allowed source in this checkout."""
    for prefix in SOURCE_ROOTS:
        if filename.startswith(prefix):
            relative = filename
        elif '/' + prefix in filename:
            relative = prefix + filename.split('/' + prefix, 1)[1]
        else:
            continue
        path = PurePosixPath(relative)
        if '..' in path.parts or path.suffix != '.swift':
            return None
        local = (root / relative).resolve()
        if local.is_relative_to(root.resolve()) and local.is_file():
            return relative
    return None


def merge_line(coverage, filename, line, covered):
    if line < 1:
        raise ValueError('Coverage line numbers must be positive')
    lines = coverage.setdefault(filename, {})
    lines[line] = lines.get(line, False) or covered


def parse_xccov(text):
    """Ignore headings, non-executable lines and optional branch tuples."""
    lines = {}
    for row in text.splitlines():
        match = re.match(r'^\s*(\d+):\s+(\d+)(?:\s|$)', row)
        if match:
            line, count = map(int, match.groups())
            lines[line] = lines.get(line, False) or count > 0
    return lines


def command(*args):
    return subprocess.check_output(args, text=True)


def add_xccov(coverage, bundle, root):
    report = json.loads(command('xcrun', 'xccov', 'view', '--report', '--json', str(bundle)))
    files = {f['path'] for target in report['targets'] for f in target.get('files', [])}
    found = False
    for filename in sorted(files):
        relative = source_path(filename, root)
        if not relative:
            continue
        rows = parse_xccov(command('xcrun', 'xccov', 'view', '--archive', '--file', filename, str(bundle)))
        for line, covered in rows.items():
            merge_line(coverage, relative, line, covered)
        found = found or bool(rows)
    if not found:
        raise ValueError('A Cloud result bundle contains no matching Swift source line coverage')


def add_llvm(coverage, report, root):
    for unit in report['data']:
        for source in unit['files']:
            relative = source_path(source['filename'], root)
            if not relative or not relative.startswith(SOURCE_ROOTS[1]):
                continue
            segments = source['segments']
            for current, following in zip(segments, segments[1:]):
                line, column, count, has_count = current[:4]
                is_gap = len(current) > 5 and current[5]
                if not has_count or is_gap:
                    continue
                end_line, end_column = following[:2]
                # A region ending at column 1 excludes that final line.
                last = end_line - (end_column == 1)
                for number in range(line, last + 1):
                    merge_line(coverage, relative, number, count > 0)


def extract_bundle(archive, destination):
    """Never allow paths or symlinks in an artifact to escape its directory."""
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if sum(item.file_size for item in entries) > 8 * 1024**3 or len(entries) > 200_000:
            raise ValueError('Result archive exceeds extraction limits')
        for item in entries:
            path = PurePosixPath(item.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in item.filename
                    or stat.S_ISLNK(item.external_attr >> 16)):
                raise ValueError('Unsafe result archive entry')
        zipped.extractall(destination)
    bundles = list(destination.rglob('*.xcresult'))
    if not bundles:
        raise ValueError('Result archive contains no .xcresult bundle')
    return bundles


def write_report(coverage, root, output):
    for prefix in SOURCE_ROOTS:
        if not any(path.startswith(prefix) and lines for path, lines in coverage.items()):
            raise ValueError(f'Missing coverage for {prefix}')
    report = ET.Element('coverage', version='1')
    covered = total = 0
    for filename, lines in sorted(coverage.items()):
        # Catch stale/mismatched source paths rather than importing unrelated data.
        line_count = len((root / filename).read_text().splitlines())
        if lines and max(lines) > line_count:
            raise ValueError(f'Coverage exceeds current source length: {filename}')
        entry = ET.SubElement(report, 'file', path=filename)
        for number, hit in sorted(lines.items()):
            ET.SubElement(entry, 'lineToCover', lineNumber=str(number), covered=str(hit).lower())
            covered += hit
            total += 1
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(report)
    ET.ElementTree(report).write(output, encoding='utf-8', xml_declaration=True)
    return covered, total


def verify_revision(metadata, root):
    def revision(ref):
        return command('git', '-C', str(root), 'rev-parse', ref).strip()
    if metadata.get('baseSha'):
        # Cloud tests a merge, so use GitHub's merge tree, not the head-only tree.
        if revision('HEAD^1') != metadata['baseSha'] or revision('HEAD^2') != metadata['sha']:
            raise ValueError('PR merge parents do not match the Cloud source/base commits')
    elif revision('HEAD') != metadata['sha']:
        raise ValueError('Cloud coverage commit does not match the source checkout')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--cloud', type=Path, required=True)
    parser.add_argument('--llvm', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    coverage = {}
    metadata = json.loads((args.cloud / 'build.json').read_text())
    verify_revision(metadata, args.root)
    if metadata['status'] != 'SUCCEEDED' or not metadata['artifacts']:
        raise ValueError('Only successful Cloud builds with result artifacts can be imported')
    for index, artifact in enumerate(metadata['artifacts']):
        filename = artifact['file']
        if Path(filename).name != filename or not re.fullmatch(r'result-\d+\.zip', filename):
            raise ValueError('Unexpected result artifact filename')
        for bundle in extract_bundle(args.cloud / filename, args.cloud / f'extracted-{index}'):
            add_xccov(coverage, bundle, args.root)
    add_llvm(coverage, json.loads(args.llvm.read_text()), args.root)
    covered, total = write_report(coverage, args.root, args.output)
    print(f'Merged Swift line coverage: {covered}/{total} ({100 * covered / total:.2f}%)')


if __name__ == '__main__':
    main()
