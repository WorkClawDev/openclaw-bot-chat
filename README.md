# OpenClaw Bot Chat

OpenClaw Bot Chat is a broker-first realtime chat system for OpenClaw bots.

The repository contains:

- `backend/`: Go API service for authentication, business data, realtime bootstrap, message history, and MQTT message persistence.
- `frontend/`: Next.js chat UI that connects directly to the MQTT broker over WebSocket.
- `test/openclaw-bot-chat/`: OpenClaw bot runtime plugin / test agent that connects directly to the MQTT broker over TCP.

## Architecture

Realtime traffic goes through the MQTT broker, not through the backend:

- `frontend -> MQTT over WebSocket -> broker`
- `plugin/testagent -> MQTT TCP -> broker`

The backend does not act as a realtime relay. It does not expose `/api/v1/ws`, and it does not provide HTTP realtime send or heartbeat endpoints.

The backend is responsible for:

- User and bot authentication.
- Business data for bots, groups, assets, messages, and conversations.
- `GET /api/v1/realtime/bootstrap` for user clients.
- `GET /api/v1/bot-runtime/bootstrap` for bot runtime clients.
- Message history and reconnect catch-up queries.
- Consuming MQTT business topics and persisting messages.

## Broker Requirements

The default Docker Compose setup uses EMQX, but the application is not tied to EMQX. Any MQTT broker can be used if it supports:

- MQTT TCP and MQTT over WebSocket.
- Connection authentication, such as username/password or an equivalent mechanism.
- Topic publish/subscribe ACLs.

Business message payloads do not include an `auth` field. In production, authentication and ACL enforcement should be handled by the broker.

Current broker integration TODO:

- `TODO(broker-acl)`: integrate dynamic authentication and dynamic ACL provisioning for your own broker. The current Compose setup is intended to make the broker-first flow runnable locally.

## Quick Start With Docker Compose

Start the core stack:

```bash
docker compose up --build -d
docker compose ps
```

This starts:

- PostgreSQL
- Redis
- EMQX
- Backend
- Frontend

Optionally start the test agent after providing the required bot key and model environment variables:

```bash
./scripts/test-agent.sh start
```

Common local ports:

- Frontend: `3000`
- Backend: `8080`
- MQTT TCP: `1883`
- MQTT WebSocket: `8083` with path `/mqtt`
- EMQX Dashboard: `18083`

## Local Test Environment

```bash
./scripts/test-env.sh up
```

This starts an independent test stack with a browser gateway, MQTT, PostgreSQL,
Redis, S3 test storage, and an Echo Test Bot. Open `http://127.0.0.1:3000` and use
the credentials saved in the ignored `run/test-env/account.json`.

See [test environment commands and configuration](scripts/test-environment/README.md).

## Configuration

Important environment variables:

- `NEXT_PUBLIC_API_URL`: backend URL used by the frontend.
- `MQTT_USERNAME` / `MQTT_PASSWORD`: broker credentials returned by backend bootstrap endpoints.
- `MQTT_TCP_PUBLIC_URL`: broker TCP URL returned to the plugin / test agent.
- `MQTT_WS_PUBLIC_URL`: broker WebSocket URL returned to the frontend.
- `JWT_SECRET`: JWT signing secret. Replace it in production.
- `DATABASE_PASSWORD`: PostgreSQL password. Replace it in production.

The backend also reads `backend/config.yaml`, with environment variables overriding config values in Docker Compose.

## Running Components Manually

Backend:

```bash
cd backend
go mod tidy
go run ./cmd/server
```

Frontend:

```bash
cd frontend
npm install
npm run dev
```

Test agent / plugin:

```bash
cp ./scripts/test-agent.env.example ./scripts/test-agent.env
./scripts/test-agent.sh start
```

Useful test-agent commands:

```bash
./scripts/test-agent.sh check
./scripts/test-agent.sh print-config
```

## Documentation

- API reference: `docs/API.md`
- Backend setup and configuration: `backend/README.md`
- Plugin / test-agent usage: `test/openclaw-bot-chat/README.md`



## Personal work assistant

The standalone agent source is `test/openclaw-bot-chat`. Web `/assistant` and iOS Settings → Personal assistant manage execution, scoped tool approvals, verified-result reconciliation, files, confirmed memory and schedules. Use the dedicated isolated Compose project for the new scoped MQTT identity protocol.

See [operations and acceptance](docs/PERSONAL_AGENT_OPERATIONS.md), [batch evidence](docs/PERSONAL_AGENT_PROGRESS.md), and [40-scenario evaluations](test/personal-agent-evals/scenarios.json). Real model/broker/PostgreSQL/storage/device/72-hour acceptance remains distinct from the passing deterministic and client UI tests.
