# SPDX-License-Identifier: MPL-2.0
"""Convert Swift LCOV or an xcresult to Sonar generic coverage, repo paths only."""
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]

def repo_path(raw):
    path = Path(raw)
    if path.is_absolute():
        try:
            path = path.relative_to(ROOT)
        except ValueError:
            return None
    if '..' in path.parts or '.build' in path.parts:
        return None
    value = path.as_posix()
    if not value.endswith('.swift') or not value.startswith(('Packages/OpenCodeKit/Sources/', 'OpenCodeRemote/OpenCodeRemote/')):
        return None
    return value if (ROOT / path).is_file() else None

def parse_lcov(text):
    result = {}
    current = None
    for line in text.splitlines():
        if line.startswith('SF:'):
            current = repo_path(line[3:])
        elif line.startswith('DA:') and current:
            number, hits, *_ = line[3:].split(',')
            lines = result.setdefault(current, {})
            lines[int(number)] = lines.get(int(number), False) or int(hits) > 0
        elif line == 'end_of_record':
            current = None
    return result

def parse_xccov(bundle):
    report = json.loads(subprocess.check_output(['xcrun', 'xccov', 'view', '--report', '--json', bundle]))
    result = {}
    for target in report['targets']:
        for file in target['files']:
            path = repo_path(file['path'])
            if not path:
                continue
            output = subprocess.check_output(['xcrun', 'xccov', 'view', '--archive', '--file', file['path'], bundle], text=True)
            lines = result.setdefault(path, {})
            for line in output.splitlines():
                match = re.match(r'\s*(\d+):\s*(\d+)\b', line)
                if match:
                    number, hits = map(int, match.groups())
                    lines[number] = lines.get(number, False) or hits > 0
    return result

def write_report(data, output):
    if not data or not any(data.values()):
        raise ValueError('No repository Swift coverage lines found')
    root = ET.Element('coverage', version='1')
    for path, lines in sorted(data.items()):
        file = ET.SubElement(root, 'file', path=path)
        for number, covered in sorted(lines.items()):
            ET.SubElement(file, 'lineToCover', lineNumber=str(number), covered=str(covered).lower())
    ET.ElementTree(root).write(output, encoding='utf-8', xml_declaration=True)

if __name__ == '__main__':
    mode, source, output = sys.argv[1:]
    data = parse_lcov(Path(source).read_text()) if mode == 'lcov' else parse_xccov(source)
    write_report(data, output)
