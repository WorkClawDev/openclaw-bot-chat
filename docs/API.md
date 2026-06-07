# OpenClaw Bot Chat API

本文档描述 broker-first 版本接口。实时消息主链路在 MQTT broker，backend 仅提供 bootstrap 与历史查询能力。

## Base URL

- HTTP: `/api/v1`
- Health: `/health`

## 通用响应

HTTP 接口（除 `/health`）统一返回：

```json
{
  "code": 0,
  "message": "success",
  "data": {}
}
```

## 认证

- 用户接口：`Authorization: Bearer <access_token>`
- bot runtime 接口：`X-Bot-Key: <bot_key>`

## Realtime 架构

- frontend 通过 broker WebSocket (`ws://.../mqtt`) 直连
- plugin/testagent 通过 broker TCP (`mqtt://...`) 直连
- backend 只负责 MQTT 消费落库与 REST 查询

已移除：

- `/api/v1/ws`
- `POST /api/v1/messages` realtime send
- `POST /api/v1/bot-runtime/messages`
- `POST /api/v1/bot-runtime/heartbeat`

## Realtime Bootstrap

### `GET /api/v1/realtime/bootstrap`

用户 JWT 鉴权。返回前端 MQTT 连接参数、topic 与历史补偿元数据。

示例：

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "broker": {
      "tcp_url": "mqtt://127.0.0.1:1883",
      "ws_url": "ws://127.0.0.1:8083/mqtt",
      "username": "openclaw_backend",
      "password": "change-me-in-production",
      "qos": 1
    },
    "client_id": "frontend-<uid>-<suffix>",
    "principal_type": "user",
    "principal_id": "<user-id>",
    "subscriptions": [{"topic": "chat/...", "qos": 1}],
    "publish_topics": ["chat/..."],
    "history": {"max_catchup_batch": 200}
  }
}
```

### `GET /api/v1/bot-runtime/bootstrap`

`X-Bot-Key` 鉴权。返回 bot/plugin MQTT 连接参数、topic、会话与历史补偿信息。

补充约定：

- `subscriptions` 可能包含 wildcard topic（例如 `chat/group/+`）
- `publish_topics` 只包含可直接发布的精确 topic（不使用 wildcard）

### `GET /api/v1/bot-runtime/messages/*conversation_id`

`X-Bot-Key` 鉴权的历史查询，支持 `limit` 和 `after_seq`。使用星号路径是因为 `conversation_id` 本身包含 `/`。

## 任务协调

任务存储按 owner 隔离。用户 JWT 接口和 bot runtime 接口读取同一份任务数据，因此 bot 创建或更新的任务会出现在 web `/tasks` 页面。

### 用户接口

- `GET /api/v1/tasks`
- `POST /api/v1/tasks`
- `GET /api/v1/tasks/:id`
- `PUT /api/v1/tasks/:id`
- `POST /api/v1/tasks/:id/reassign`
- `DELETE /api/v1/tasks/:id`

### Bot Runtime 接口

以下接口使用 `X-Bot-Key` 鉴权：

- `GET /api/v1/bot-runtime/tasks`
- `POST /api/v1/bot-runtime/tasks`
- `POST /api/v1/bot-runtime/tasks/:id/claim`
- `POST /api/v1/bot-runtime/tasks/:id/progress`
- `POST /api/v1/bot-runtime/tasks/:id/complete`
- `POST /api/v1/bot-runtime/tasks/:id/fail`

`POST /api/v1/bot-runtime/tasks` 接受与用户创建任务相同的 payload。创建事件会记录当前 bot 作为 actor。

## 历史与会话

### `GET /api/v1/conversations`

用户可见会话列表。

### `GET /api/v1/messages`

参数：

- `conversation_id`（可选）
- `limit`（可选）
- `before_seq`（可选）
- `after_seq`（可选）

### `GET /api/v1/messages/*conversation_id`

按路径传会话 ID 查询历史，支持 `limit` 和 `after_seq`。

## 其他业务接口

以下资源保持 REST 模型：

- `/api/v1/auth/*`
- `/api/v1/bots/*`
- `/api/v1/groups/*`
- `/api/v1/assets/image/*`
- `/api/v1/assets/audio/*`
- `/api/v1/tasks/*`

## MQTT Topic 约定

canonical topic：

- 私聊：`chat/dm/{leftType}/{leftId}/{rightType}/{rightId}`
- 群聊：`chat/group/{groupId}`

私聊 topic 做 canonical 排序，不按发送方向区分路径。

## 消息 payload（不带 auth）

业务消息 payload 采用统一结构，不包含 `auth` 字段：

```json
{
  "id": "client-generated-id",
  "topic": "chat/...",
  "conversation_id": "chat/...",
  "timestamp": 1710000000,
  "from": {"type": "user", "id": "u1"},
  "to": {"type": "bot", "id": "b1"},
  "content": {
    "type": "text",
    "body": "hello",
    "meta": {}
  }
}
```

说明：

- `seq` 由 backend 落库时分配
- broker 负责连接认证与 topic ACL
- backend 负责消费归一化和持久化

## Broker ACL TODO

- compose 默认 EMQX 示例已开启用户名密码认证。
- `TODO(broker-acl)`: 后续接入自有 broker 时应实现动态 topic ACL 下发。
