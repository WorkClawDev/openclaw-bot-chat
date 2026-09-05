---
name: bot-chat
description: "BotChat ops via the message tool (channel=bot-chat)."
metadata:
  {
    "openclaw":
      {
        "emoji": "💬",
        "requires": { "config": ["channels.bot-chat.backendUrl", "channels.bot-chat.botKey"] },
      },
  }
allowed-tools: ["message"]
---

# BotChat (Via `message`)

Use the `message` tool. No provider-specific `bot-chat` tool is exposed to the agent.

- Always: `channel: "bot-chat"`.
- Prefer explicit targets. Empty `allowFrom` denies inbound senders until pairing adds an id. `allowFrom: ["*"]` is the open policy.
- Multi-account is currently a single default account.

## Targets

| Target | Meaning |
| --- | --- |
| `dm:<userId>` / `user:<userId>` | Direct MQTT topic `chat/dm/user/<userId>/bot/<botId>` |
| `group:<groupId>` | Group topic `chat/group/<groupId>` |
| `channel:<conversationId>` | Raw conversation id |

## Media

- Inbound images/audio arrive as attachments with `download_url`.
- Outbound media uses `MEDIA:<path-or-url>` or `VOICE:<path-or-url>` lines, or the message tool media fields.
- Local files are imported through BotChat `/api/v1/bot-runtime/assets/{image\|audio}/import`.

## Tasks

BotChat polls `/api/v1/bot-runtime/tasks/queue` when the host supplies `channelRuntime.runTask`.

- `context.progress(progress, note)` posts progress.
- `context.createTask(payload)` creates a child task.
- Return a string or object result; thrown errors mark the task failed.

Optional runtime knob: `channels.bot-chat.taskPollingIntervalMs` (minimum 1000).
