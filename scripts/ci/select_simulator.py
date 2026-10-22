# SPDX-License-Identifier: MPL-2.0
"""Select an available iOS 27.0 simulator in the requested device family."""
import json
import os
import subprocess

family = os.environ['DEVICE_FAMILY']
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
matches = [d for runtime, rows in devices.items() if runtime.endswith('iOS-27-0')
           for d in rows if d['name'].startswith(family) and d.get('isAvailable')]
if not matches:
    raise SystemExit(f'No available iOS 27.0 {family} simulator; update the pinned CI toolchain explicitly')
device = sorted(matches, key=lambda d: d['name'])[0]
with open(os.environ['GITHUB_ENV'], 'a') as stream:
    stream.write(f"SIMULATOR_ID={device['udid']}\n")
print(f"Selected {device['name']} ({device['udid']})")
