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

`npm --prefix frontend run test:chat` runs the Agent workspace browser contracts
against the running frontend (port 3000 by default). They use isolated HTTP/MQTT
fixtures to check a 500-message virtual timeline, streaming and reading-position
preservation, approvals, run actions, downloads, Agent isolation, mobile layout,
dark mode, reduced motion, and IME composition. These fixtures do not replace the
live broker/persistence checks above. Set `CHAT_UI_URL` to test another running
frontend. After `npm --prefix frontend run build`, `CHAT_UI_START=1 npm --prefix
frontend run test:chat` can start its own production server on port 13002.
Screenshots, traces, and the JSON report are written to `run/agent-chat-ui/` and
are excluded from Git. CI also runs this suite and uploads its evidence.

`CHAT_UI_URL=http://127.0.0.1:13002 npm --prefix frontend run test:chat:performance`
runs the larger rendering benchmark against an existing production build. Use
`CHAT_UI_START=1` instead to start the frontend's own production server after
`npm --prefix frontend run build`. The suite covers 1,000 / 5,000 / 10,000-message
histories with prose, code, tables, and delayed images; desktop native wheel
input; 390px mobile touch gestures with 4x CPU throttling; group conversations;
100 incoming MQTT messages while reading history; and growing streaming output.
Touch input uses CDP touch-start/move/end sequences and checks actual scroll
distance so a browser that ignores a gesture cannot silently pass the benchmark.

Frame p50/p95/p99, maximum frame intervals, tasks over 50ms, rendered message
counts, empty viewport samples, and reading-anchor movement are saved under
`run/agent-chat-performance/`. Playwright trace recording is disabled during
timing measurements. CI repeats the desktop 10,000-message and streaming cases;
timing values are reported rather than assigned a universal device-independent
FPS threshold. The functional gates require real scroll movement, bounded DOM,
no empty viewport samples, and less than 4px anchor movement during incoming
messages. These headless Chromium measurements do not benchmark server-side
history pagination or replace physical-device Safari/Android testing.
For diagnosis, `CHAT_PERF_PROFILE=1` also saves a Chromium CPU profile for the
native scrolling cases; keep profiled timings separate from normal measurements.

The independent production-container and real-model acceptance results are in
[the project acceptance report](../../docs/PROJECT_ACCEPTANCE.md).

Before the first run, `TEST_PUBLIC_URL` and `TEST_WEB_PORT` can select an origin
and bind port. To change them later, update `.env.test`, including
`MQTT_WS_PUBLIC_URL` and `STORAGE_S3_PUBLIC_ENDPOINT`, then restart the test stack.
`GO_BIN`, `GOCACHE`, and `GOMODCACHE` can select an installed Go toolchain and caches.
Image locations can be overridden using the `TEST_*_IMAGE` entries in `.env.test`.
