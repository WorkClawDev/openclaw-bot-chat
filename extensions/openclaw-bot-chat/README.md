# OpenClaw BotChat Extension

OpenClaw channel extension for bridging OpenClaw to BotChat through the BotChat backend and MQTT broker.

## Install

```bash
npm install @workclawdev/extension-bot-chat
```

This publishes under the WorkClawDev namespace. The npm scope is written as lowercase `@workclawdev` because npm package names must be lowercase.

The package prints a non-secret QR code during install when lifecycle script output is shown by npm. The same QR can be shown again at any time:

```bash
npx @workclawdev/extension-bot-chat
```

Set `OPENCLAW_BOTCHAT_SKIP_POSTINSTALL_QR=1` to suppress install-time QR output.

## iOS Binding QR

The install/setup QR never includes `BOT_CHAT_BOT_KEY` or other secrets.

By default it encodes:

```text
openclaw://extensions/install?package=@workclawdev%2Fextension-bot-chat&channel=bot-chat
```

For a deployment-specific iOS binding URL, provide one of these before running install or setup:

```bash
OPENCLAW_BOTCHAT_BIND_URL="https://clawchat.example.com/openclaw/bind?token=..." npx @workclawdev/extension-bot-chat
```

or:

```bash
BOT_CHAT_BACKEND_URL="https://clawchat.example.com" \
BOT_CHAT_BIND_TOKEN="ocbb_replace_with_one_time_binding_token" \
npx @workclawdev/extension-bot-chat
```

The token form is preferred. Create it from the BotChat API:

```text
POST /api/v1/bots/<bot UUID>/bindings
```

The response includes a short-lived `bind_url` and `token`. iOS consumes the token with:

```text
POST /api/v1/bot-bindings/confirm
```

Legacy bot id QR codes are still recognized for compatibility:

```bash
BOT_CHAT_BACKEND_URL="https://clawchat.example.com" \
BOT_CHAT_BOT_ID="replace_with_bot_uuid" \
npx @workclawdev/extension-bot-chat
```

The second form generates:

```text
https://clawchat.example.com/openclaw/bind?package=@workclawdev/extension-bot-chat&channel=bot-chat&botId=<bot UUID>
```

## Configuration

Minimal OpenClaw channel config:

```json
{
  "channels": {
    "bot-chat": {
      "backendUrl": "http://127.0.0.1:8080",
      "botKey": "ocbk_replace_with_one_time_bot_key",
      "botId": "replace_with_bot_uuid"
    }
  }
}
```

Recommended config for local development:

```json
{
  "channels": {
    "bot-chat": {
      "backendUrl": "http://127.0.0.1:8080",
      "botKey": "ocbk_replace_with_one_time_bot_key",
      "botId": "replace_with_bot_uuid",
      "mqttTcpUrl": "mqtt://127.0.0.1:1883",
      "defaultTo": "group:replace_with_group_uuid",
      "allowFrom": ["*"],
      "stateDir": "./data",
      "historyCatchupLimit": 100
    }
  }
}
```

`allowFrom` is a pairing allowlist:

- omitted or `[]` denies inbound senders (pending pairing). System `control/bot-chat/*` topics still pass.
- `["*"]` is the explicit open policy.
- one or more user ids allow only those senders.

Flag-driven setup:

```bash
openclaw channels add --channel bot-chat --backend-url http://127.0.0.1:8080 --bot-key ocbk_... --bot-id <uuid>
openclaw channels add --channel bot-chat --use-env
```

`--use-env` reads `BOT_CHAT_BACKEND_URL`, `BOT_CHAT_BOT_KEY`, `BOT_CHAT_BOT_ID`, `BOT_CHAT_MQTT_TCP_URL`, and `BOT_CHAT_MQTT_WS_URL`. Validation still requires `backendUrl` and `botKey`.

`botKey` can also be an OpenClaw secret reference:

```json
{
  "source": "env",
  "provider": "default",
  "id": "BOT_CHAT_BOT_KEY"
}
```

## BotChat Runtime Contract

The extension uses the BotChat bot-runtime contract:

- `GET /api/v1/bot-runtime/bootstrap` with `X-Bot-Key`
- `GET /api/v1/bot-runtime/messages/<conversation_id>?limit=<n>&after_seq=<seq>` with `X-Bot-Key`
- `GET /api/v1/bot-runtime/tasks/queue` with `X-Bot-Key`; older backends can still be read through `GET /api/v1/bot-runtime/tasks`
- `POST /api/v1/bot-runtime/tasks` with `X-Bot-Key`
- `POST /api/v1/bot-runtime/tasks/<task_id>/{claim|progress|result|fail}` with `X-Bot-Key`; `result` falls back to legacy `complete` when unavailable
- MQTT publish topics that BotChat can persist:
  - DM: `chat/dm/user/<userId>/bot/<botId>`
  - Group: `chat/group/<groupId>`

Task assignment does not execute a task by itself. A running bot process must consume the task runtime API and post progress, result, or failure. The extension polls runnable tasks from `/tasks/queue` when the OpenClaw host supplies `channelRuntime.runTask` or `channelRuntime.tasks.runTask`; without that hook it leaves task state unchanged instead of claiming work it cannot execute. For compatibility it falls back to the older task list endpoint when `/tasks/queue` is unavailable.

`runTask(task, context)` receives a task plus helpers:

- `context.progress(progress, note)` or `context.progress(note, progress)` posts progress updates.
- `context.createTask(payload)` posts `POST /api/v1/bot-runtime/tasks`, so a runtime can create child tasks. The helper automatically adds the current task as `parent_task_id` unless the payload overrides it.

When `runTask` returns an object, the extension posts it as `result` to `/bot-runtime/tasks/<task_id>/result` together with `latest_status_note`. Fields such as `summary`, `output`, `artifacts`, and `metadata` are preserved. Thrown errors are reported to `/fail` with both `latest_status_note` and a structured `error` object.

## Target Mapping

| OpenClaw target | BotChat publish topic |
| --- | --- |
| `dm:<userId>` / `user:<userId>` | `chat/dm/user/<userId>/bot/<botId>` |
| `group:<groupId>` | `chat/group/<groupId>` |
| `channel:<conversationId>` | `<conversationId>` |
| raw target | `channel:<raw>` |

## Development

```bash
npm run check
npm test
npm run build
npm pack --dry-run
```
