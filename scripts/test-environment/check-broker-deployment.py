#!/usr/bin/env python3
"""Validate effective Compose configurations without starting any services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
env = os.environ.copy()
env.update(MQTTS_AUTHZ_QUERY_TOKEN='q' * 40, BROKER_SECURITY_ADMIN_TOKEN='a' * 40, MQTT_PASSWORD='p' * 40, INGEST_MQTT_PASSWORD='i' * 40,
           JWT_SECRET='j' * 40, OPENAI_COMPAT_BASE_URL='https://model.example/v1',
           OPENAI_COMPAT_MODEL='fixture', DATABASE_USER='postgres',
           DATABASE_PASSWORD='fixture', DATABASE_DBNAME='fixture',
           MQTTS_AUTHZ_IMAGE='mqtts-authz:independent-fixture', MQTTS_IMAGE='mqtts:independent-fixture', STORAGE_S3_BUCKET='fixture')
variants = [
    (root, ['docker-compose.yml']),
    (root, ['deploy/docker-compose.test.yml']),
]
for overrides in [[], ['compose.proxy.yaml'], ['compose.seaweedfs.yaml'],
                  ['compose.proxy.yaml', 'compose.seaweedfs.yaml']]:
    variants.append((root / 'deploy/personal-agent',
                     ['deploy/personal-agent/' + name for name in ['compose.yaml'] + overrides]))

# Resolve deployment paths against a disposable directory. Compose validates
# service env_file existence even with --no-env-resolution, so provide an empty
# fixture instead of relying on or modifying a developer's ignored .env.test.
with tempfile.TemporaryDirectory(prefix='broker-deployment-') as directory:
    fixture_root = Path(directory)
    (fixture_root / '.env.test').touch(mode=0o600)
    for directory, files in variants:
        fixture_directory = fixture_root / directory.relative_to(root)
        fixture_directory.mkdir(parents=True, exist_ok=True)
        command = ['docker', 'compose', '--env-file', '/dev/null', '--project-directory', str(fixture_directory)]
        for name in files:
            command += ['-f', str(root / name)]
        for profile in [[], ['--profile', 'broker']]:
            # Verify structure without reading ignored runtime .env/secret files.
            result = subprocess.run(command + profile + ['config', '--format', 'json'],
                                    env=env, text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError('Compose validation failed: ' + result.stderr)
            services = json.loads(result.stdout)['services']
            assert 'message-ingest' in services
            ingest = services['message-ingest']
            assert 'backend' not in ingest.get('depends_on', {})
            assert ingest['environment']['PUSH_ENABLED'] == services['backend']['environment']['PUSH_ENABLED'] == 'false'
            # Provider credentials must not leak into the independent consumer.
            assert not any(k in ingest['environment'] for k in ['PUSH_PRIVATE_KEY_PATH', 'PUSH_TEAM_ID', 'PUSH_KEY_ID'])
            assert ingest['environment']['MQTT_USERNAME'] != services['backend']['environment'].get('MQTT_USERNAME')
            assert any(v['target'] == '/data' for v in ingest.get('volumes', []))
            if profile:
                assert 'build' not in services['mqtts-authz']
                assert services['mqtts-authz']['image'] == 'mqtts-authz:independent-fixture'
                assert 'ports' not in services['mqtts-authz'], 'Management RPC must remain private by default'
                assert 'build' not in services['mqtts'], 'Consumer configuration must not build broker source'
                assert services['mqtts']['image'] == 'mqtts:independent-fixture'
                assert any(v['target'] == '/data' and v['type'] == 'volume' for v in services['mqtts'].get('volumes', [])), 'Durable broker requires its own persistent volume'
            else:
                assert 'mqtts-authz' not in services
                assert 'mqtts' not in services, 'External mode must not create a local broker'
            assert all(not {'mqtts', 'mqtts-authz'} & set(service.get('depends_on', {})) for service in services.values()), \
                'Application services must start independently of a bundled broker'
            print('PASS', ', '.join(files), 'prebuilt broker' if profile else 'external broker')
