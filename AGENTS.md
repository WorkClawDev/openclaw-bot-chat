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

### Docker in Cloud Agent VMs

Docker is not preinstalled. Start the daemon once per VM session before Compose:

```bash
sudo dockerd > /tmp/dockerd.log 2>&1 &
sleep 3
sudo docker compose version
```

Use `sudo docker compose` unless your user is in the `docker` group. Storage driver `fuse-overlayfs` is required in this environment (see Docker install notes in the platform docs).

### Recommended full-stack startup (localhost)

From the repo root, set public URLs so the built frontend and bootstrap responses match local ports, then start the stack:

```bash
export NEXT_PUBLIC_API_URL=http://127.0.0.1:8080
export MQTT_WS_PUBLIC_URL=ws://127.0.0.1:8083/mqtt
export MQTT_TCP_PUBLIC_URL=mqtt://127.0.0.1:1883
sudo -E docker compose up --build -d
```

- UI: `http://127.0.0.1:3000`
- API health: `curl http://127.0.0.1:8080/health`
- MQTT WebSocket: `ws://127.0.0.1:8083/mqtt`

`./scripts/dev-up.sh` seeds `tester` / `test123456` but defaults `NEXT_PUBLIC_API_URL` and `MQTT_WS_PUBLIC_URL` to the bundled Nginx domain (`test.iotdevices.site`). In Cloud VMs without that proxy, prefer the Compose flow above or override those variables in `scripts/dev.env` to localhost before running `dev-up.sh` + `./scripts/dev-front.sh`.

### Lint / test shortcuts

| Area | Command |
|------|---------|
| Backend | `cd backend && go test ./...` |
| Frontend typecheck/build | `cd frontend && npm run build` |
| Extension contracts | `cd extensions/openclaw-bot-chat && npm test` |

`npm run lint` in `frontend/` may prompt for interactive ESLint setup if no config exists; use `npm run build` for CI-style validation instead.

The OpenClaw runtime plugin lives under `extensions/openclaw-bot-chat/` (and sample config under `test/openclaw-bot-chat/`); there is no top-level `plugins/` directory in this repo.

### Bot test agent

README mentions `docker compose --profile testagent`, but the current `docker-compose.yml` has no such profile. Use `cp scripts/test-agent.env.example scripts/test-agent.env` and `./scripts/test-agent.sh start` after the backend and EMQX are up.
