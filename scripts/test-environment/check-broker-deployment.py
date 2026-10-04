#!/usr/bin/env python3
"""Validate effective Compose configurations without starting any services."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
env = os.environ.copy()
env.update(BROKER_SECURITY_CALLBACK_TOKEN='c' * 40, MQTT_PASSWORD='p' * 40,
           JWT_SECRET='j' * 40, OPENAI_COMPAT_BASE_URL='https://model.example/v1',
           OPENAI_COMPAT_MODEL='fixture', DATABASE_USER='postgres',
           DATABASE_PASSWORD='fixture', DATABASE_DBNAME='fixture',
           MQTTS_IMAGE='mqtts:independent-fixture')
variants = [
    (root, ['docker-compose.yml']),
    (root, ['deploy/docker-compose.test.yml']),
]
for overrides in [[], ['compose.proxy.yaml'], ['compose.seaweedfs.yaml'],
                  ['compose.proxy.yaml', 'compose.seaweedfs.yaml']]:
    variants.append((root / 'deploy/personal-agent',
                     ['deploy/personal-agent/' + name for name in ['compose.yaml'] + overrides]))

for directory, files in variants:
    command = ['docker', 'compose', '--env-file', '/dev/null', '--project-directory', str(directory)]
    for name in files:
        command += ['-f', str(root / name)]
    for profile in [[], ['--profile', 'broker']]:
        result = subprocess.run(command + profile + ['config', '--format', 'json'],
                                env=env, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError('Compose validation failed: ' + result.stderr)
        services = json.loads(result.stdout)['services']
        if profile:
            assert 'build' not in services['mqtts'], 'Consumer configuration must not build broker source'
            assert services['mqtts']['image'] == 'mqtts:independent-fixture'
        else:
            assert 'mqtts' not in services, 'External mode must not create a local broker'
        assert all('mqtts' not in service.get('depends_on', {}) for service in services.values()), \
            'Application services must start independently of a bundled broker'
        print('PASS', ', '.join(files), 'prebuilt broker' if profile else 'external broker')
