# OpenClaw 通信插件开发调研与落地说明

> 适用目录：`plugins/openclaw-bot-chat`

## 1. 通信插件的核心职责

一个可接入 OpenClaw 的通信插件，最小闭环一般包括：

1. **连接编排**：从后端 bootstrap 拉取 broker/topic/会话信息。
2. **消息接入**：订阅 MQTT topic，接收业务消息并归一化。
3. **消息路由**：识别 DM/群组/频道上下文，按会话维度串行处理。
4. **Agent 调用**：把消息转换为 OpenClaw 请求，调用模型/handler。
5. **消息回写**：将回复重新发布到 broker 对应 topic。
6. **断线补偿**：按 checkpoint（`seq` / `message_id`）补拉历史消息。
7. **权限审批**：在默认权限拒绝时触发审批接口/审批 handler，再决定是否放行。

---

## 2. 当前实现涉及的关键接口与用途

## 2.1 配置层接口

- `loadConfig()`（`src/config.ts`）
  - 用途：加载插件总配置、bot 列表、通信与审批参数。
- `PluginConfig`
  - 新增审批相关字段：
    - `permissionApprovalEnabled`
    - `permissionApprovalUrl`
    - `permissionApprovalHandler`
    - `permissionApprovalTimeoutMs`
    - `permissionDeniedReply`

## 2.2 通信接入接口

- `BotChatHttpClient.bootstrap()`（`src/client/http.ts`）
  - 用途：拉取 broker/client_id/subscriptions/publish_topics/history。
- `BotChatMqttClient.connect/subscribe/publish`（`src/client/mqtt.ts`）
  - 用途：建立 MQTT 连接、订阅消息、发布回复。
- `BootstrapResponse`（`src/types/index.ts`）
  - 用途：统一描述 bootstrap 返回的运行时连接信息。

## 2.3 路由与消息转换接口

- `normalizeBotChatMessage()`（`src/router/message.ts`）
  - 用途：兼容多种输入 payload，归一化为 `BotChatMessage`。
- `routeIncomingMessage()`
  - 用途：计算动作类型（action）、频道上下文（channel）和权限检查结果（permission）。
- `toOpenClawRequest()`
  - 用途：把业务消息转换为 agent 输入结构。
- `toBotChatOutgoingMessage()` + `toRealtimePublishPayload()`
  - 用途：把 agent 输出转换为 broker 发布帧。

## 2.4 权限相关接口

- `checkPermission()`（`src/types/permissions.ts`）
  - 用途：基于 bot/action/user/channel/groupPolicy 做静态权限判定。
- `PermissionApprovalRequest`（`src/types/index.ts`）
  - 用途：当静态权限拒绝时，提交审批上下文（消息、频道、原因）。
- `PermissionApprovalDecision`
  - 用途：审批结果：
    - `approved=true`：继续执行通信处理；
    - `approved=false`：拒绝处理，可附带通知文案。
- `PermissionApprover`
  - 用途：定义审批扩展点，支持本地 handler 或 HTTP 审批服务。

## 2.5 运行时编排接口

- `OpenClawBotRuntime` / `ManagedBotRuntime`（`src/runtime/bot.ts`）
  - 用途：串起 bootstrap、MQTT、消息消费、agent 调用、checkpoint、审批放行。
- `resolvePermissionApproval()`（新增）
  - 用途：在权限拒绝时调用 `PermissionApprover.approve()` 做二次审批。
- `publishPermissionDeniedNotice()`（新增）
  - 用途：审批拒绝时向原会话发送提示文案（可配置）。

---

## 3. 已生成的可接入通信插件能力（基于当前结构）

当前插件已具备可直接接入 OpenClaw 的两类能力：

1. **通信能力**
   - backend bootstrap + MQTT 订阅/发布 + 历史补偿；
   - 多 bot、多会话、去重与串行队列处理；
   - 可接本地 handler 或 HTTP agent。

2. **权限审批能力（新增）**
   - 静态权限由 `checkPermission()` 快速判定；
   - 被拒绝后可走 `permissionApprovalHandler` 或 `permissionApprovalUrl`；
   - 审批通过则继续调用 agent；
   - 审批拒绝可自动回复 `permissionDeniedReply` 或审批结果中的 `notify_message`。

---

## 4. 配置示例

参考 `config.example.json`：

- `permissionApprovalEnabled: true`
- `permissionApprovalHandler: "./examples/permission-approver.cjs"`
- `permissionApprovalTimeoutMs: 8000`
- `permissionDeniedReply: "当前会话暂无调用权限，请联系管理员审批。"`

审批 handler 示例见：`examples/permission-approver.cjs`。
