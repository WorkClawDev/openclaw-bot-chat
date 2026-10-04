# 项目运行验收记录 · 2026-10-04

验收基线为最新 `master` 的 `a1f8925`，加本次修复。验收期间合入的 Cloud Agent 安装脚本已实际执行成功；该上游提交未改动业务代码。当前 Linux 环境已跑通 Web、Go API、PostgreSQL、Redis、EMQX、私有 S3、正式个人助手 worker 和真实本地模型。完整 iOS、生产模型质量及 72 小时验收仍未完成。

## 当前入口

| 用途 | 环境内地址 | 凭据文件（Git 忽略） |
| --- | --- | --- |
| 聊天集成环境：Echo、真实模型 worker、MCP | `http://127.0.0.1:3000` | `run/test-env/account.json` |
| 独立生产镜像：非 root worker、真实模型 | `http://127.0.0.1:13000` | `run/project-acceptance/dedicated-account.json` |
| 独立后端就绪检查 | `http://127.0.0.1:18080/health/ready` | 无 |

独立环境使用 `personal-agent` Compose project；普通测试环境使用 `openclaw-bot-chat-test`。真实模型为经 SHA-256 校验的 Qwen2.5-7B-Instruct Q4_K_M，通过 llama.cpp b11382 的 OpenAI 兼容接口运行。模型、账户、日志和截图均位于忽略目录，未加入源码。

## 已通过的实际检查

| 范围 | 结果与边界 |
| --- | --- |
| 构建与启动 | 后端、Next.js standalone 前端、Node 24 worker 镜像实际构建；空数据库启动与整套停止后重新启动通过 |
| 浏览器 | 登录、私聊、群聊、刷新历史、图片与语音、手机尺寸、个人助手、记忆和计划操作通过；生产页连接容器 worker 获得实际回复 |
| 首条消息 | 保持已有 MQTT 连接，新建 Bot/群组后不刷新页面即可发送，数据库确认消息已保存；提供 `scripts/test-env.sh browser` 回归入口 |
| 生产媒体 | 浏览器跨端口直接上传私有 S3，PUT 200、GET 200/206；图片渲染、音频解码和刷新后读取通过 |
| 实际模型 | 推理、SSE 事件、provider 返回的 token 用量写入 PostgreSQL；受约束 CSV 读取和收入计算通过 |
| 文件与任务 | 模型按明确数据创建真实 XLSX，实际上传、下载，核对产品行、金额及 SHA-256 后由测试账户接受任务；容器 worker 的 Markdown 交付同时生成 Document |
| 审批与补充 | 覆盖文件前保持原内容；批准后写入与批准参数一致的字节；补充信息后继续原 run；拒绝对二进制表格的文本修改 |
| 记忆、计划、恢复 | PostgreSQL 记忆增删与重启后读取；计划生成一个 Task 并完成审核；模型执行中取消；SIGKILL 后恢复离线消息，重复投递只产生一个 run |
| MCP | 官方 `@modelcontextprotocol/server-filesystem` 实际 stdio 发现和模型读取调用；路径及能力约束生效 |
| Broker | EMQX 实际拒绝错误密码、错误 client ID、跨用户主题和已撤销 key；观察 300 秒后连接过期且旧凭据不能重连 |
| OpenClaw 扩展 | 扩展真实连接 EMQX 收发消息，凭据续期重连后再次收发成功；未运行完整 OpenClaw 宿主中的模型调度 |
| 数据库恢复 | 实际 pg_dump、恢复到新库、重放 6 个 SQL；8 张业务表的 107 行完整 JSON 与源库一致 |
| Schema | 109 个 Agent 列定义、11 个约束一致；迁移保留现有 31 个索引并新增 7 个普通查询索引。AutoMigrate 与显式 SQL 的索引集合并不完全相同 |
| 对象存储恢复 | 停服快照恢复到独立卷和独立 S3 进程；使用有效签名下载样本，77 字节文件 SHA-256 与持久记录一致 |

Go 全量测试通过；Agent CI 38/38、扩展测试 58/58 和 check/build 通过；40 个确定性场景通过。正式 live runner 的 40 个场景尚未逐项验收，不能把这些确定性结果计为真实服务 40/40。

## 本次修复

- 空的工具核对列表返回 `[]`，避免个人助手页面调用 `null.map`。
- 新 Bot 没有历史时，owner 获得精确私聊权限；创建 Bot/群组后，前端先刷新短期 MQTT 凭据再打开会话。
- EMQX 补齐启动配置，并为后端持久消费者设置独立私有身份，解除启动时 HTTP 回调的循环依赖。
- 修正非 root 镜像文件权限、受限 umask 下的 secret 权限、worker 卷初始化顺序和真实 readiness 检查。
- worker 显式 MQTT TCP 配置优先于 bootstrap 中的浏览器地址；内部 S3/服务请求加入 NO_PROXY，保留外部代理配置。
- 禁用的 Shell 不再展示给模型；模型返回 `finish_reason=length` 等未完成结果时，不执行其中的工具调用。
- 前端镜像使用 Next.js standalone，构建目录排除运行数据；提供代理 CA 与 SeaweedFS S3 的可选 Compose 配置。
- 长期采集支持使用受保护的账户文件在 JWT 过期后重新登录。

## 尚未通过或未执行

- 当前没有 macOS/Xcode/iOS 设备环境，未复验最新 iOS 构建或真机流程。
- 72 小时持续采集已启动，但尚未达到 72 小时。部署调试阶段的采样和最终稳定窗口分别保留，不能合并成连续通过记录。
- 本地小模型不满足通用任务质量保证：3B 模型曾算错 CSV；7B 在自由表格任务中曾写入占位数据，也曾直接声称完成而没有调用工具。这些结果均保留，未接受错误成果。通过的是有实际产物核对的受约束任务。
- 指定 MinIO 镜像无法获取，旧官方二进制下载返回 410；实际 S3 验收使用 SeaweedFS 4.48。未声称 MinIO 本身通过。
- 未测试付费模型服务、远端 MCP、完整 OpenClaw 宿主、启用 Docker Shell runner、生产并发和 p95 性能。

## 重复运行

普通聊天环境：

```sh
./scripts/test-env.sh status
./scripts/test-env.sh smoke
./scripts/test-env.sh browser
./scripts/test-env.sh check
```

本工作区的独立环境使用单独冷启动数据库卷。重启时保留这个本地 override，避免切换到另一数据卷：

```sh
docker --host=unix:///var/run/docker.sock compose \
  --env-file deploy/personal-agent/.env \
  -f deploy/personal-agent/compose.yaml \
  -f deploy/personal-agent/compose.seaweedfs.yaml \
  -f run/project-acceptance/runtime.override.json \
  up -d --no-build --wait frontend worker
```

新环境的构建、模型配置和可选代理 CA 见 [运行手册](PERSONAL_AGENT_OPERATIONS.md)。当前本地模型进程应保持运行；状态目录为 `run/project-acceptance/models`，启动脚本为忽略目录中的 `start-runtime.py`。

查看最终稳定窗口：

```sh
PERSONAL_AGENT_STABILITY_LOG="$PWD/run/project-acceptance/stability-final.jsonl" \
  node scripts/personal-agent-stability.cjs --analyze
```

验收明细、成功/失败样例、浏览器截图、备份和恢复记录在 `run/project-acceptance/`。其中 `results.json`、`production-browser.json`、`production-media.json`、`restore-validation.json`、`objectstore-restore-validation.json` 和 `summary.json` 用于复核；这些运行资料不包含在 Git 提交中。
