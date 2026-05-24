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
- MQTT publish topics that BotChat can persist:
  - DM: `chat/dm/user/<userId>/bot/<botId>`
  - Group: `chat/group/<groupId>`

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
