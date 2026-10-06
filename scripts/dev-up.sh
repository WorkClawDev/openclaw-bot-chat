#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dev-common.sh"

load_dev_env

echo "Starting OpenClaw Bot Chat in development mode..."
print_dev_runtime_summary

compose --profile broker up --build -d "$@" postgres redis mqtts-authz mqtts minio-init backend message-ingest
ensure_dev_test_account
compose ps
print_frontend_dev_status || true
print_dev_test_credentials

cat <<EOF

Development mode is ready.
Start frontend HMR:    ./scripts/dev-front.sh
Backend health:        curl http://${BACKEND_BIND_HOST}:${BACKEND_BIND_PORT}/health
Frontend via Nginx:    http://${DOMAIN}
Frontend direct:       http://${FRONTEND_BIND_HOST}:${FRONTEND_BIND_PORT}
Docker logs:           ./scripts/dev-logs.sh
Stop backend stack:    ./scripts/dev-down.sh
EOF
