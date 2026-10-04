#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.test"
TOOLS_DIR="$REPO_ROOT/scripts/test-environment"
STATE_DIR="$REPO_ROOT/run/test-env"
export OPENCLAW_TEST_ENV_FILE="$ENV_FILE"
export TEST_STATE_DIR="$STATE_DIR"

compose() {
  # Always operate on the local Docker daemon for this test environment.
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --host=unix:///var/run/docker.sock compose \
    --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" \
    -f "$REPO_ROOT/deploy/docker-compose.test.yml" "$@"
}

find_go() {
  local candidate
  for candidate in "${GO_BIN:-}" "$(command -v go || true)" /workspace/.tools/go/bin/go; do
    if [[ -n "$candidate" ]] && "$candidate" version 2>/dev/null | grep -q '^go version go'; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  echo 'Go 1.25+ is required; set GO_BIN to its executable.' >&2
  return 1
}

install_package() {
  local directory="$1"
  if [[ ! -f "$directory/node_modules/.package-lock.json" || "$directory/package-lock.json" -nt "$directory/node_modules/.package-lock.json" || "$directory/package.json" -nt "$directory/node_modules/.package-lock.json" ]]; then
    (cd "$directory" && npm ci --no-audit --no-fund --cache "$REPO_ROOT/backend/.cache/npm")
  fi
}

prepare() {
  mkdir -p "$STATE_DIR" "$REPO_ROOT/backend/bin"
  node "$TOOLS_DIR/configure.mjs"
  node "$TOOLS_DIR/install-storage.mjs"
  install_package "$TOOLS_DIR"
  install_package "$REPO_ROOT/frontend"
  install_package "$REPO_ROOT/extensions/openclaw-bot-chat"
  install_package "$REPO_ROOT/test/openclaw-bot-chat"
  local go_bin
  go_bin="$(find_go)"
  (cd "$REPO_ROOT/backend" && CGO_ENABLED=0 GOMAXPROCS=4 \
    GOCACHE="${GOCACHE:-$REPO_ROOT/backend/.cache/go-build}" \
    GOMODCACHE="${GOMODCACHE:-$REPO_ROOT/backend/.cache/go-mod}" \
    "$go_bin" build -p 4 -o bin/test-server ./cmd/server)
}

up() {
  prepare
  compose up -d --wait --wait-timeout 120 postgres redis
  compose up -d --force-recreate --wait --wait-timeout 120 emqx
  compose up -d --force-recreate --wait --wait-timeout 120 storage
  compose up -d --force-recreate --wait --wait-timeout 240 backend frontend proxy
  node "$TOOLS_DIR/seed.mjs"
  compose up -d --force-recreate --wait --wait-timeout 90 echo-bot
  node "$TOOLS_DIR/smoke.mjs"
  status
}

status() {
  compose --profile fixtures ps
  node -e 'const fs=require("fs"),{parseEnv}=require("util");const c=parseEnv(fs.readFileSync(process.argv[1],"utf8"));console.log("Web: "+c.TEST_PUBLIC_URL);console.log("Credentials: "+process.argv[2])' "$ENV_FILE" "$STATE_DIR/account.json"
}

case "${1:-up}" in
  up) up ;;
  install) prepare ;;
  down) compose --profile fixtures down ;;
  restart) compose --profile fixtures down; up ;;
  status) status ;;
  logs) compose --profile fixtures logs --tail 80 "${@:2}" ;;
  smoke) node "$TOOLS_DIR/smoke.mjs" ;;
  check)
    go_bin="$(find_go)"
    (cd "$REPO_ROOT/backend" && GOMAXPROCS=4 GOCACHE="${GOCACHE:-$REPO_ROOT/backend/.cache/go-build}" GOMODCACHE="${GOMODCACHE:-$REPO_ROOT/backend/.cache/go-mod}" "$go_bin" test -p 4 ./...)
    (cd "$REPO_ROOT/extensions/openclaw-bot-chat" && npm test && npm run check && npm run build)
    (cd "$REPO_ROOT/frontend" && npx --no-install tsc --noEmit)
    (cd "$REPO_ROOT/test/openclaw-bot-chat" && npm run ci)
    PATH="$(dirname -- "$go_bin"):$PATH" GOCACHE="${GOCACHE:-$REPO_ROOT/backend/.cache/go-build}" GOMODCACHE="${GOMODCACHE:-$REPO_ROOT/backend/.cache/go-mod}" node "$REPO_ROOT/test/personal-agent-evals/run.cjs"
    ;;
  *) echo 'Usage: scripts/test-env.sh [up|install|down|restart|status|logs [service]|smoke|check]' >&2; exit 2 ;;
esac
