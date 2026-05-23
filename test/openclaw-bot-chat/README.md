# openclaw-bot-chat plugin

OpenClaw 侧 bot runtime 插件，采用 broker-first 模式：

- 通过 backend 的 `bot-runtime/bootstrap` 获取 broker 连接信息、topic 与历史补偿参数
- 通过 MQTT TCP 直接订阅/发布业务消息
- 通过 backend 历史接口进行断线补偿

不再使用 backend WebSocket，不再使用 HTTP realtime send/heartbeat。

## 运行模式

1. 使用 `X-Bot-Key` 调 backend bootstrap
2. 连接 broker TCP
3. 订阅 bootstrap 下发的 topic
4. 收到消息后调用 OpenClaw agent
5. 将回复直接 publish 到 broker
6. 重连后按 `after_seq` 补拉历史

## 快速启动（测试）

在仓库根目录：

```bash
cp ./scripts/test-agent.env.example ./scripts/test-agent.env
./scripts/test-agent.sh start
```

关键环境变量：

- `BOT_CHAT_BACKEND_URL`
- `BOT_CHAT_BOT_KEY`
- `BOT_CHAT_BOT_ID`（部分场景可选）
- `BOT_CHAT_MQTT_TCP_URL`（可选 override）
- `OPENAI_COMPAT_BASE_URL`
- `OPENAI_COMPAT_API_KEY`
- `OPENAI_COMPAT_MODEL`
- `OPENAI_COMPAT_HISTORY_TURNS`：每个会话保留的历史轮数，默认 `8`
- `OPENAI_COMPAT_MCP_CONFIG`：指向 MCP JSON 配置文件
- `OPENAI_COMPAT_MCP_SERVERS_JSON`：直接以内联 JSON 提供 `mcpServers`
- `OPENAI_COMPAT_MCP_MAX_TOOL_ROUNDS`：单次请求最多工具轮数，默认 `6`
- `OPENAI_COMPAT_MCP_TOOL_TIMEOUT_MS`：单个 MCP 工具调用超时，默认 `20000`
- `OPENAI_COMPAT_MCP_MAX_PARALLEL`：单轮并行工具调用数量，默认 `4`
- `OPENAI_COMPAT_MCP_TOOL_RESULT_MAX_CHARS`：工具结果最大字符数，默认 `8000`
- `OPENAI_COMPAT_MCP_ALLOWED_TOOLS`：工具名白名单正则（可选）
- `OPENAI_COMPAT_MCP_BLOCKED_TOOLS`：工具名黑名单正则（可选）
- `OPENAI_COMPAT_MCP_INCLUDE_SERVER_PREFIX`：工具名是否附加 server 前缀，默认 `true`
- `OPENAI_COMPAT_MCP_MAX_TOOLS_PER_REQUEST`：单次请求可执行的 MCP 工具调用上限，默认 `12`
- `OPENAI_COMPAT_MCP_TOTAL_BUDGET_MS`：单次请求总工具预算时长，默认 `45000`
- `OPENAI_COMPAT_MAX_RETRIES`：模型请求重试次数（仅 429/5xx/网络错误），默认 `2`
- `OPENAI_COMPAT_RETRY_BACKOFF_MS`：重试退避基准毫秒，默认 `1200`
- `OPENAI_COMPAT_MEMORY_MAX_NOTES`：每个 session 最多保存便签数量，默认 `24`
- `OPENAI_COMPAT_TOOL_EDIT_ENABLED`：是否允许 MCP 工具执行文件编辑/命令执行类能力，默认 `false`
- `OPENAI_COMPAT_TOOL_EDIT_ALLOWED_ROOTS`：允许编辑的根目录列表（逗号分隔，建议强制配置）
- `OPENAI_COMPAT_FILESYSTEM_ENABLED`：是否启用内置本地文件系统/编码工具，默认 `true`
- `OPENAI_COMPAT_FS_ALLOWED_READ_ROOTS`：允许读取的根目录列表（逗号分隔，空表示不限制）
- `OPENAI_COMPAT_FS_ALLOWED_WRITE_ROOTS`：允许写入的根目录列表（逗号分隔，空表示不限制）
- `OPENAI_COMPAT_FS_MAX_READ_BYTES`：单次读文件最大字节数，默认 `262144`
- `OPENAI_COMPAT_FS_MAX_WRITE_BYTES`：单次写文件最大字节数，默认 `262144`
- `OPENAI_COMPAT_FS_ALLOW_HIDDEN`：是否允许访问隐藏路径（`.git`/`.env` 等），默认 `false`
- `OPENAI_COMPAT_FS_RG_MAX_MATCHES`：`local__code_search_rg` 最大匹配条数，默认 `300`
- `OPENAI_COMPAT_FS_RG_MAX_BYTES`：`local__code_search_rg` 结果缓冲上限字节，默认 `262144`
- `OPENAI_COMPAT_BASH_ENABLED`：是否启用内置 `local__bash_exec`，默认 `false`
- `OPENAI_COMPAT_BASH_ALLOWED_ROOTS`：bash 执行时允许的 `cwd` 根目录（逗号分隔，空表示不限制）
- `OPENAI_COMPAT_BASH_TIMEOUT_MS`：bash 执行超时毫秒，默认 `20000`
- `OPENAI_COMPAT_BASH_MAX_OUTPUT_CHARS`：bash 输出截断上限字符，默认 `12000`
- `OPENCLAW_PERMISSION_APPROVAL_ENABLED`：是否启用权限审批（默认 `false`）
- `OPENCLAW_PERMISSION_APPROVAL_HANDLER`：本地审批 handler 路径（优先）
- `OPENCLAW_PERMISSION_APPROVAL_URL`：审批 HTTP 接口地址
- `OPENCLAW_PERMISSION_APPROVAL_TIMEOUT_MS`：审批超时毫秒（默认 `8000`）
- `OPENCLAW_PERMISSION_DENIED_REPLY`：审批拒绝时回复文案（可选）

辅助命令：

```bash
./scripts/test-agent.sh check
./scripts/test-agent.sh print-config
```

调试指令：

- `/meta`：查看当前请求 metadata
- `/reset`：清空当前 session 的内存上下文
- `/help`：查看 handler 内置调试指令
- `/tools`：查看当前加载到模型侧的工具列表（本地工具 + MCP 工具）
- `/memory`：查看当前 session 的记忆便签
- `/memory + 文本`：添加记忆便签
- `/memory clear`：清空记忆便签

MCP 说明：

- 默认 `openai-compatible-handler.cjs` 同时支持“内置本地工具 runtime”与可选 MCP runtime
- 它会先加载内置本地工具，再按配置启动 stdio MCP server，并统一映射成 OpenAI-compatible `tools`
- 模型返回 tool calls 后，handler 会自动调用 MCP 工具并继续对话轮询
- handler 结构已拆分为模块（`examples/openai-handler/*.cjs`）：
  - `utils.cjs`：通用环境变量/JSON/错误处理工具
  - `session-state.cjs`：会话历史与记忆管理
  - `model-client.cjs`：OpenAI-compatible 请求与重试逻辑
  - `mcp-runtime.cjs`：MCP runtime 初始化、工具过滤与预算执行
- 对“写文件/执行命令”类工具增加权限门控：
  - 默认拒绝（`OPENAI_COMPAT_TOOL_EDIT_ENABLED=false`）
  - 可通过 `OPENAI_COMPAT_TOOL_EDIT_ALLOWED_ROOTS` 限制可写目录范围
- 内置本地工具（无需 MCP server，与 MCP 解耦）：
  - `local__fs_read_text` / `local__fs_read_base64`
  - `local__fs_write_text` / `local__fs_write_base64`
  - `local__fs_list_dir`
  - `local__code_search_rg`（基于 ripgrep 定位代码）
  - `local__fs_replace_text`（文本替换式编辑）
  - `local__bash_exec`（受 `OPENAI_COMPAT_BASH_*` 限制）
  - `local__text_encode` / `local__text_decode`
  - 通过 `OPENAI_COMPAT_FS_ALLOWED_READ_ROOTS` 与 `OPENAI_COMPAT_FS_ALLOWED_WRITE_ROOTS` 控制访问范围

权限审批说明：

- 先执行插件内静态权限校验（`channels/users/groupPolicy/actions`）
- 静态校验拒绝时，可配置审批扩展（二选一）：
  - `OPENCLAW_PERMISSION_APPROVAL_HANDLER`
  - `OPENCLAW_PERMISSION_APPROVAL_URL`
- 审批通过：继续执行消息处理并调用 agent
- 审批拒绝：跳过 agent，并可自动回复拒绝说明

## Broker 可替换性

插件不依赖 EMQX 私有协议，只要求 broker 支持：

- MQTT TCP
- 连接认证
- topic publish/subscribe ACL

业务消息 payload 不带 `auth`。
