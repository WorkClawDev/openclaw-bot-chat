# Local test environment

Run on Linux x86_64 from the repository root with Docker Compose v2, Node.js 22+,
npm, Go 1.25+, curl, and tar:

```bash
./scripts/test-env.sh up
./scripts/test-env.sh status
./scripts/test-env.sh smoke
./scripts/test-env.sh browser
./scripts/test-env.sh check
./scripts/test-env.sh logs echo-bot
./scripts/test-env.sh down
```

The default browser URL is `http://127.0.0.1:3000`. The gateway serves the Next.js UI,
API, MQTT WebSocket, and signed media URLs from this one origin. Forward port 3000
when using a remote workspace. The backend is also available at port 8080; MQTT
TCP is at 1883, MQTT WebSocket at 8083, and the EMQX dashboard at 18083.

`up` generates the ignored `.env.test` with random credentials, installs locked
Node dependencies, builds the backend, waits for healthy services, and creates a
disposable account, **Echo Test Bot**, **Test Chat**, a document, and a task.
Login credentials and the generated bot key are saved in the ignored
`run/test-env/account.json`; the script does not print their values.

Echo Test Bot repeats text, images, and audio in direct and group chat. It runs
without a model API key and supports UI and transport testing. SeaweedFS 4.48
provides S3-compatible test object storage with generated keys and signature
verification. The startup script downloads its official release binary, verifies
the pinned SHA-256 digest, and caches it in `run/test-env/seaweedfs`.
The broker validates browser and Bot sessions with the backend's scoped identity
protocol. A separate private persistence identity can connect while the API starts.
Use the production broker and storage provider separately for deployment testing.

The PostgreSQL, Redis, broker, and storage data use named Docker volumes.
`down` stops this test project and preserves its data. `up` can be repeated;
it reuses account and fixture IDs and restarts the app with the current code.
`check` runs Go tests, extension tests/build, frontend type checks, test-agent
tests/type checks, and the deterministic personal-agent evaluations.
The main production Compose file is independent of this test project.

`browser` uses the frontend's Playwright dependency and a local Chromium browser
to verify login, the first message to a newly created bot and group without a
reload, actual message persistence, and the assistant page. It creates disposable
fixtures under the test account. Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` when
Chromium is not at `/usr/bin/chromium`, or install Playwright's Chromium using
`cd frontend && npx playwright install chromium`. Screenshots remain under the
ignored test state directory.

The independent production-container and real-model acceptance results are in
[the project acceptance report](../../docs/PROJECT_ACCEPTANCE.md).

Before the first run, `TEST_PUBLIC_URL` and `TEST_WEB_PORT` can select an origin
and bind port. To change them later, update `.env.test`, including
`MQTT_WS_PUBLIC_URL` and `STORAGE_S3_PUBLIC_ENDPOINT`, then restart the test stack.
`GO_BIN`, `GOCACHE`, and `GOMODCACHE` can select an installed Go toolchain and caches.
Image locations can be overridden using the `TEST_*_IMAGE` entries in `.env.test`.
