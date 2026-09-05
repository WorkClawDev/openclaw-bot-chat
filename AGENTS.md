# Repository Guidelines

## Project Structure & Module Organization

This is a broker-first chat system. `backend/` is the Go API service: entrypoint in `cmd/server/`, domain code in `internal/`, helpers in `pkg/`, and SQL in `migrations/`. `frontend/` is the Next.js app, with routes in `src/app/`, UI in `src/components/`, and API/MQTT helpers in `src/lib/`. `plugins/openclaw-bot-chat/` is the Node.js/TypeScript runtime plugin. `extensions/openclaw-bot-chat/` contains the OpenClaw extension and contract tests. `broker/`, `deploy/`, `docs/`, and `scripts/` hold broker config, nginx/deployment files, docs, and automation. iOS code is under `clawchat-ios/`.

## Build, Test, and Development Commands

- `docker compose up --build -d`: starts PostgreSQL, Redis, EMQX, backend, and frontend.
- `docker compose up --build -d frontend`: rebuilds and restarts only the production frontend container after frontend code changes; this also runs `npm run build` inside Docker.
- `./scripts/dev-up.sh`: starts the local backend stack and seeds a test account.
- `./scripts/dev-front.sh`: runs the frontend with Next.js HMR.
- `./scripts/dev-logs.sh`, `./scripts/dev-ps.sh`, `./scripts/dev-down.sh`: inspect or stop the dev environment.
- `cd backend && go test ./...`: runs Go unit tests.
- `cd frontend && npm run build`: type-checks and builds the Next.js app.
- `cd plugins/openclaw-bot-chat && npm run check && npm run build`: validates and compiles the plugin.
- `cd extensions/openclaw-bot-chat && npm test`: runs Node test-runner contract/runtime tests.

## Coding Style & Naming Conventions

Use `gofmt` for Go and keep backend packages organized by responsibility: `handler`, `service`, `repository`, `model`, `middleware`, and `mqtt`. TypeScript uses strict settings; prefer explicit types at public boundaries. Keep React components in PascalCase files such as `MessageBubble.tsx`; hooks and utilities stay camelCase. Preserve the broker-first MQTT architecture: frontend uses MQTT over WebSocket, plugins use MQTT TCP, and backend handles auth, bootstrap, persistence, and history.

## Testing Guidelines

Place Go tests beside code as `*_test.go`; see `backend/internal/service/message_service_test.go`. Extension tests use `tests/*.test.mjs` with Node's built-in test runner. Add focused tests for ACL, bootstrap, message persistence, and contract changes. For frontend changes, run `cd frontend && npm run build` when Node/npm are available locally; otherwise run `docker compose up --build -d frontend` from the repo root and confirm the frontend container restarts cleanly. After a frontend rebuild, verify `http://127.0.0.1:3000` or the deployed nginx route responds before testing UI behavior.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects, for example `Keep generated screenshots out of the repo`. Follow that style and keep commits scoped. Pull requests should describe behavior changes, list verification commands, link issues, and include screenshots for visible frontend or iOS changes. Note configuration, migration, broker ACL, or environment-variable impact explicitly.

## Security & Configuration Tips

Start from `scripts/dev.env.example`, `scripts/test-agent.env.example`, or component `config.example.json` files. Do not commit real bot keys, JWT secrets, database passwords, broker credentials, generated screenshots, or local runtime config files.

## Local Test Accounts

Do not commit usernames, passwords, access tokens, refresh tokens, bot keys, or deployment-specific user IDs. Use local seed scripts or the ignored `AGENTS.local.md` file to obtain disposable test credentials when needed.

## Cursor Cloud specific instructions

Cloud Agent `install` must use `./scripts/cloud-agent-install.sh` (or equivalent subshells / absolute paths). Do not use a multi-line script of relative `cd backend`, `cd frontend`, and `cd extensions/...` commands: those run in one shell, so the first `cd` makes later directories look missing. The install script only downloads Go modules and Node dependencies; keep Docker Compose / `./scripts/dev-up.sh` in `start` or a named terminal, not `install`.
