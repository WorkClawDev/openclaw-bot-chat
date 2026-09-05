#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap. Each package install runs in a subshell so
# `cd` never leaks into later steps (a multi-line `cd backend && ...` then
# `cd frontend` script fails because the second cd is relative to backend/).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

(cd "$ROOT/backend" && go mod download)
(cd "$ROOT/frontend" && npm ci)
(cd "$ROOT/extensions/openclaw-bot-chat" && npm ci)
