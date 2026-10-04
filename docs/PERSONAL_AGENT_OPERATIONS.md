# 个人助手运行与验收手册

本分支实际源码在 `test/openclaw-bot-chat`，不是旧 `plugins` 路径。日常入口是 Web `/assistant`、iOS 设置中的「个人助手」及现有 Task 页面。用户私聊会创建持久 run；Task 派发、计划 occurrence 使用同一 executor。成功结果进入待审核，用户接受才完成。群聊和其他用户消息不会驱动个人助手执行工具。

## 当前证据

2026-10-04 已在 Linux 实际构建并运行独立容器，验证 PostgreSQL、Redis、EMQX、私有 S3、生产 Web 和非 root worker。真实本地模型完成推理、工具调用、文件交付、任务审核、审批、补充信息、计划、取消和进程崩溃恢复；官方 filesystem MCP 通过实际 stdio 调用。Go 全量测试、38 项 Agent 测试、58 项扩展测试、40 项确定性场景及生产前端构建通过。详情、模型质量失败样例和证据路径见 [完整项目验收记录](PROJECT_ACCEPTANCE.md)。

数据库备份恢复、6 个迁移重放和独立对象存储恢复已实际校验。正式 40 场景 live runner 仍未逐项验收；72 小时采集尚未达到要求时长。当前 Linux 无法复验最新 iOS 代码；2026-10-03 的模拟器记录属于历史证据，见 [实施进度](PERSONAL_AGENT_PROGRESS.md)。

## 隔离启动

所有命令在仓库根目录执行。使用 Node ≥22，本次主机和 worker 验证为 Node 24，前端使用 Node 22 镜像。

```sh
node --version
test -f deploy/personal-agent/.env || cp deploy/personal-agent/.env.example deploy/personal-agent/.env
node scripts/personal-agent-prepare.cjs
```

编辑被忽略的 `.env`，设置模型 API base URL 和模型名称。prepare 只创建本任务随机秘密和空 bot/model key 文件，已有文件不覆盖，秘密值不输出。`.runtime` 父目录为0700；被 Docker 挂载的秘密文件为0644，允许特定容器内非 root 进程读取，主机其他账户无法穿过父目录。不要把目录权限放宽、启用 shell tracing 或提交运行文件。run持久记录workspace_id；未显式配置时从state目录及roots派生，恢复要求同一workspace，防止悄悄切换到其他目录。专用Compose显式设置personal-agent-workspace。输入资料放入 `.runtime/input`，它以只读方式挂载；worker 状态和输出使用独立 named volumes，由短生命周期初始化容器仅对这两个卷设定 UID1000 的所有权。

先启动基础服务和 Web，使用隔离账户创建自己的 bot，从界面生成 bot key。将其填入 `.runtime/bot-key`，模型密钥填入 `.runtime/model-key`，不要把密钥放进命令参数或 Git。没有配置这些值时 worker 会拒绝启动。

```sh
docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent up --build -d frontend
docker compose --env-file deploy/personal-agent/.env -f deploy/personal-agent/compose.yaml -p personal-agent up --build -d worker
```

本次环境无法获取固定版本 MinIO 镜像，官方旧二进制下载返回 410。可选用真实 SeaweedFS S3：先运行 `node scripts/test-environment/install-storage.mjs` 下载并校验固定版本，再给上述 Compose 命令添加 `-f deploy/personal-agent/compose.seaweedfs.yaml`。S3 仍使用私有签名认证。切换 S3 实现时使用独立数据卷。

带 HTTPS 代理的开发环境可添加 `-f deploy/personal-agent/compose.proxy.yaml`，以 BuildKit secret 及只读挂载提供公共 CA bundle；`PERSONAL_AGENT_CA_FILE` 可指定路径。构建保留 TLS 校验和已有代理设置。启动包装脚本只把本地服务地址加入 NO_PROXY，避免内部 S3 请求经外部代理。

本地 CPU 模型可通过 `host.docker.internal` 访问主机服务，并在 `.env` 调整 `OPENAI_COMPAT_TIMEOUT_MS`、`OPENAI_COMPAT_MCP_TOTAL_BUDGET_MS`、`OPENAI_COMPAT_MAX_TOKENS`、`OPENAI_COMPAT_STREAM_USAGE` 和 `OPENAI_COMPAT_SYSTEM_PROMPT`。本次分别使用 240000、600000、512、true 及逐次调用工具的提示；默认 45 秒工具预算可能在 CPU 模型首轮推理期间耗尽。

专用 project 固定为 `personal-agent`。端口仅绑定主机 loopback：Web13000、API18080、MQTT1885、WS8085、对象存储19000；数据库、Redis、broker dashboard 不向主机发布。不得将同名数据库或卷指向生产。旧根目录 Compose 使用不同 broker 配置，本分支新短期凭据必须配套 HTTP 认证/授权，不能混用旧共享账户的 broker。

这个 Compose 是单机隔离验收配置，`APP_MODE=debug` 且手机号认证关闭。远端日常部署还需配置 HTTPS/WSS、外部可解析的 storage public endpoint、模型和存储服务、备份及真实验收。iOS 真机无法使用主机127.0.0.1；需要明确设置可达服务地址及对应 JWT、broker WS 和 storage public URL。

## MQTT 身份和权限

客户端 bootstrap 不再收到后端的共享 MQTT 账户，而是与 owner/bot/clientID/订阅和发布范围绑定的随机密码。Redis只保存密码 hash 和短期会话，业务 run/记忆/消息仍在 PostgreSQL。HTTP callbacks 检查身份、bot key 活跃/过期、主题范围及实际会话权限；回调 token 缺失、Redis故障、身份撤销或请求异常均显式 deny。只有已认证的 broker 能调用 callbacks。后端持久消费者只获准订阅 `chat/#`，通知只能发布指定命名空间。

会话有效期默认300秒，限制为60–300秒，EMQX `expire_at` 到期断开。worker 提前续期，Web 定时刷新，iOS断开后重新 bootstrap。authz cache关闭。撤销立即阻止新的认证/发布/订阅；**已建立订阅的读权限需要等待短期会话断开，最长5分钟**，并未实现 dashboard API 的即时踢连接。个人执行入口另外绑定真实 MQTT transport topic，仅 owner 私聊可以发起工具，不能依赖 payload 自称 owner。

配置新增 `BROKER_SECURITY_CALLBACK_TOKEN`（≥32字符）和 `BROKER_SECURITY_SESSION_TTL_SECONDS`；后端 `MQTT_PASSWORD` 同样≥32字符，release 配置缺失会拒绝启动。emqx-start 从独立 secrets 注入 callback、dashboard密码和 node cookie，并为私有持久消费者初始化独立身份，解除 HTTP 回调与后端启动的循环依赖。HTTP authn 的 `expire_at` 使用 EMQX5.8.5，[官方 HTTP 认证说明](https://docs.emqx.com/en/emqx/latest/guides/access-control/authn/http.html)；主题认证返回格式参照[官方 HTTP 授权说明](https://docs.emqx.com/en/emqx/latest/guides/access-control/authz/http.html)。本次实际验证身份绑定、跨用户拒绝、撤销、300 秒到期断连和扩展续期后的收发。

## 工具、文件与不确定结果

输入/输出 roots 空时拒绝，符号链接、隐藏凭据和越界路径拒绝。Shell默认关闭；开启必须提供 Docker隔离runner，没有隔离能力不能降级主机 Shell。专用 worker 镜像未挂载 Docker socket，默认不提供 Shell。MCP需要明确工具能力、参数schema、幂等声明和路径绑定；read/write 工具缺少 paths 不暴露，MCP exec 不暴露。远端查询用 network 能力并按参数审批。审批由用户完成，绑定run/工具/参数hash，15分钟过期。

`/tools` 可以查本地工具和各 MCP 服务健康；单服务连接失败降级，初始化超时受限；连接故障30秒后在没有工具调用时重建，取消关闭相关client，正常退出显式关闭子进程。MCP测试是本机实际stdio协议，远端服务取消支持需单独核对。

外部非幂等调用在崩溃/超时时不盲目重试。在两端「不确定操作核对」先查询真实外部结果并填写证据：已执行可记录实际结果；确认未执行才允许重新准备。完成核对后用run卡片「保存并继续」。不能填写猜测或将模型自述当作核对。

文件仅支持TXT/Markdown/CSV/可提取文本PDF/DOCX/XLSX，最多8MiB；扫描件要求OCR。解析worker有内存/时间/压缩比限制及空环境，它是资源边界，**不是独立OS沙箱**。专用容器降低主机暴露面，但解析器漏洞与文件路径检查和使用之间的竞争仍需生产隔离验收。所有文件交付来自真实字节，存储SHA256、owner、版本和run/task来源；文本结果同步现有Document。worker通过授权backend读取私有文件字节，S3签名使用内部host，避免容器去访问浏览器的127.0.0.1。客户端下载仍使用短期私有URL。

对象上传无法与PostgreSQL事务原子提交；失败时可能有孤立blob。不得直接删除bucket或扫描时顺手清理。先将对象key清单与assets/artifacts的引用核对，保留至少7天观察窗口，导出dry-run列表后人工确认。当前没有自动孤立blob删除服务。

## 健康、事件、用量与诊断

- `/health`：HTTP进程存活。`/health/ready`：实际数据库、Redis及backend MQTT连接；缺一返回503。
- `/api/v1/agent/health`：JWT owner限定run状态数、过期租约、未投递inbox、待发通知、待核对工具及真实步骤累计；不包含凭据和对话正文。
- worker `/state/health.json`：启动成功、当前MQTT连接及心跳时间。镜像检查实际ready且90秒内有心跳。它不验证模型服务能成功完成工作。
- run events保留真实queued/model_request/assistant_delta/model_response/tool意图与结果等。event seq单调；通知按QoS1确认持久outbox，客户端重新获取授权历史并按seq去重。
- provider返回的token用量记录在model_response事件；未提供时界面明确「模型用量未知」，不推算成真实账单。设置 `OPENAI_COMPAT_STREAM_USAGE=true` 请求兼容服务的usage；不支持时保持false。
- model_response的duration_ms/first_delta_ms来自实际时钟；queued事件表示持久接收。接收/排队时延与模型首字时延分开统计，当前未完成真实p95性能验收。预算按实际model/tool步骤记录，默认80步；触限持久暂停，用户恢复可追加80步。

日志默认关闭body调试，MCP stderr不直接透传。排查命令限定project：`docker compose ... -p personal-agent ps`、`logs --tail=200 backend worker`。不要把完整环境、配置、模型key或JWT贴到报告。

## 迁移、备份、恢复和回滚

新增6个增量SQL：approvals → journal → runs → artifacts → memory_schedules → event_outbox。依赖顺序不能按文件名排序。复用Task状态、Document与assets，未替换现有业务表。backend现有启动AutoMigrate仍会建表；发布前必须在PostgreSQL副本核对列、索引、FK和增量SQL。SQLite自动测试不能替代这个验证。

```sh
sh scripts/personal-agent-backup.sh backup /private/tmp/personal-agent-before-change.dump
sh scripts/personal-agent-backup.sh restore-new /private/tmp/personal-agent-before-change.dump
# 使用restore输出的新DB名；绝不对active DB运行此脚本。
sh scripts/personal-agent-migrations.sh personal_agent_restore_YYYYMMDD_HHMMSS
```

备份文件0700目录/0600文件、需加密和恢复校验。数据库备份不包含objectstore；同时对专用assets卷做一致性快照并抽样比对SHA256，否则恢复后的下载会失败。worker状态/输出卷另外保存，业务durable记录在DB。工具脚本拒绝覆盖已存在的备份，restore始终创建新DB，migration脚本只接受restore命名空间。本次已比较恢复库 8 张业务表的完整 JSON 内容，并验证停服快照恢复到独立 S3 卷后的签名下载和文件 SHA256。

回滚使用已验证版本镜像或git提交，保留新增表/记录，不执行drop/down migration；先暂停worker和scheduler再恢复旧版本。旧worker不理解新run租约与审批，不能与新worker同时消费同bot。broker也须与相应bootstrap协议配套，不能切回共享凭据再宣称权限保留。恢复失败前保留原DB与blob快照，不覆盖活跃数据库。

## 40场景评测及72小时运行

```sh
node test/personal-agent-evals/run.cjs
node test/personal-agent-evals/live.cjs
```

scenarios.json包含40个个人工作/故障场景、中文真实任务和对应确定性行为测试。确定性runner实际执行Node与Go，按真实测试结果生成passed/failed/not_run；真实服务默认40 not_run。显式配置 `PERSONAL_AGENT_LIVE_TESTS=1`、隔离API/owner token/bot ID后，`live.cjs --dispatch` 只派发可自动执行的普通任务；结果到awaiting_review仍不自动通过。其余安全、取消、重启和设备场景需按条件演练；核对实际产物/记录后，用`record-live.cjs PA-XX passed|failed EVIDENCE --confirmed`写入人审证据hash。不会自动批准工具或接受Task。

```sh
# 使用受保护的账户 JSON 文件，可在 JWT 过期后重新登录。
export PERSONAL_AGENT_AUTH_FILE=/absolute/path/to/ignored-account.json
node scripts/personal-agent-stability.cjs
node scripts/personal-agent-stability.cjs --analyze
```

每30秒采集实际readiness、owner诊断和worker心跳，日志默认`/tmp/personal-agent-stability.jsonl`。账户文件包含 username/password，权限设为0600；也可沿用 `PERSONAL_AGENT_OWNER_TOKEN`，但没有账户文件时过期 token 无法续期。采集器固定使用本地 Docker daemon。实际覆盖≥72小时、无>90秒采集缺口且每样本成功才判定availability passed；不足时长是not_run。可用性采集不代表模型质量、所有40功能场景或真机通过。不要只启动脚本就报告72小时通过。

## 发布前待验收及集成边界

独立worker、Web、iOS与OpenClaw扩展均实现短期凭证刷新/重连；扩展的58项测试及本次实际EMQX首轮收发、续期重连后的再次收发通过。完整 OpenClaw 宿主中的模型调度仍需宿主环境验收，不能由扩展桥接测试代替。

尚待生产模型质量和付费服务账单核对、远端MCP、真实外部副作用的不确定结果核对、多 worker 生产并发、隔离 Shell runner、p95 性能、iOS真机及72小时验收。本地 CPU 模型可以完成受约束任务，但自由任务中出现过计算和文件内容错误；任务成功状态不能代替成果审核。当前验收不包含生产凭据轮换、Git历史治理或发布。

与其他工作区的改动集成时，应逐项比较路由、bootstrap、MQTT配置、assets、Task保护、iOS项目与前端package锁，不直接整体覆盖目录。broker ACL应选定统一协议并合并撤销语义；不能并列启用旧共享身份与新HTTP身份后宣称完成权限验证。已知读订阅撤销最多5分钟窗口、文件解析OS隔离及孤立blob清理限制需在发布决策中保留。
