#!/usr/bin/env python3
"""Create an ignored Xcode test plan with disposable local account credentials.

Usage: python3 scripts/test-environment/ios-live-test-plan.py path/to/built.xctestrun
The output lives beside the input so __TESTROOT__ references remain valid.
"""
import json
import os
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parents[2]
source = Path(sys.argv[1]).resolve()
if root / 'artifacts' not in source.parents:
    raise SystemExit('The test plan must be under the ignored artifacts directory')
account = json.loads((root / 'run/test-env/account.json').read_text())
plan = plistlib.loads(source.read_bytes())
for configuration in plan['TestConfigurations']:
    for target in configuration['TestTargets']:
        if target['BlueprintName'] == 'clawchatUITests':
            target.setdefault('EnvironmentVariables', {}).update({
                'V5_TEST_USERNAME': account['username'],
                'V5_TEST_PASSWORD': account['password'],
                'V5_TEST_BOT_ID': account['bot']['id'],
                'V5_TEST_GROUP_ID': account['group']['id'],
                'V5_TEST_BASE_URL': os.environ.get('V5_TEST_BASE_URL', 'http://127.0.0.1:23000'),
            })
            if 'V5_TEST_PHOTO_SOURCE_PATH' in os.environ:
                photo = Path(os.environ['V5_TEST_PHOTO_SOURCE_PATH']).resolve()
                if root / 'artifacts' not in photo.parents or not photo.is_file() or photo.suffix.lower() != '.png':
                    raise SystemExit('Photo fixture must be an existing PNG under ignored artifacts')
                target['EnvironmentVariables']['V5_TEST_PHOTO_SOURCE_PATH'] = str(photo)
            if 'V5_TEST_RENEWAL_WAIT_SECONDS' in os.environ:
                seconds = int(os.environ['V5_TEST_RENEWAL_WAIT_SECONDS'])
                if not 1 <= seconds <= 330:
                    raise SystemExit('Renewal wait must be between 1 and 330 seconds')
                target['EnvironmentVariables']['V5_TEST_RENEWAL_WAIT_SECONDS'] = str(seconds)
            if os.environ.get('V5_TEST_NETWORK_CONTROL') == '1':
                target['EnvironmentVariables']['V5_TEST_NETWORK_CONTROL'] = '1'
destination = source.with_name('v5-live.xctestrun')
fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'wb') as output:
    plistlib.dump(plan, output)
os.chmod(destination, 0o600)
print('Local integration test plan prepared (credentials not displayed).')
