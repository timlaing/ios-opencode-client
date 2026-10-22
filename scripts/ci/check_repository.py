# SPDX-License-Identifier: MPL-2.0
"""Check committed JSON and local Markdown document links without dependencies."""
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]


def validate_files(root, filenames):
    errors = []
    for name in filter(None, filenames):
        path = root / name
        if not path.is_file(): # Deleted files may still be in the local index.
            continue
        if path.suffix == '.json':
            try:
                json.loads(path.read_text())
            except (ValueError, OSError) as error:
                errors.append(f'{name}: {error}')
        if path.suffix != '.md' or not (name.startswith('docs/') or '/' not in name):
            continue
        text = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
        for target in re.findall(r'\]\(([^\s)]+)(?:\s+"[^"]*")?\)', text):
            target = unquote(target.strip('<>').split('#')[0])
            if not target or re.match(r'[a-zA-Z][a-zA-Z0-9+.-]*:', target):
                continue
            if not (path.parent / target).exists():
                errors.append(f'{name}: missing local link {target}')
    return errors


def main():
    filenames = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    errors = validate_files(ROOT, filenames)
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Tracked JSON and local Markdown file links are valid')


if __name__ == '__main__':
    main()
