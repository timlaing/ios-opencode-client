# SPDX-License-Identifier: MPL-2.0
"""Locate the test executable across SwiftPM build-system bundle naming variants."""
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
bundles = list(root.glob('*.xctest'))
if len(bundles) != 1:
    raise SystemExit(f'Expected one Swift package test bundle, found {len(bundles)}')
bundle = bundles[0]
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
if not executable.is_file():
    raise SystemExit('Swift test executable missing')
print(executable)
