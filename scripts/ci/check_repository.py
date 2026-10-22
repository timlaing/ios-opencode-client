# SPDX-License-Identifier: MPL-2.0
"""Check committed JSON and local Markdown document links without dependencies."""
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

root = Path(__file__).resolve().parents[2]
files = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
errors = []
for name in filter(None, files):
    path = root / name
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
if errors:
    raise SystemExit('\n'.join(errors))
print('Tracked JSON and local Markdown file links are valid')
