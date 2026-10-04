# 自有 MQTTS 与权限管理

默认 Broker 是 [ChangerR/mqtts](https://github.com/ChangerR/mqtts)。此处 MQTTS
指你的 C++ 项目；原生监听是 TCP/WS，公网 TLS/WSS 由入口代理终止。
聊天数据继续存储在 PostgreSQL，Redis 保存短期 MQTT 身份。

## 配套部署

递归克隆两个仓库为同级目录。MQTTS 必须包含本次 HTTP auth provider、TCP/WS
认证和投递权限检查，旧 main 不具备这些能力。合并配套 PR 后再使用默认分支；
验收期间使用 `codex/openclaw-auth`。可以用绝对路径 `MQTTS_SOURCE_DIR` 覆盖。

```sh
git clone --recurse-submodules https://github.com/ChangerR/mqtts.git ../mqtts
# 配套 PR 合并前，在 ../mqtts 检出 codex/openclaw-auth。
```

根目录 Compose 要求独立随机 `BROKER_SECURITY_CALLBACK_TOKEN`、`MQTT_PASSWORD`
和 `JWT_SECRET`（至少32字符），放在忽略的 `.env`。不要把密码写入 MQTT URL。
`MQTT_USERNAME`、`MQTT_CLIENT_ID` 是后端持久消费者身份；bootstrap 返回的是
各客户端独立随机会话，不能把后端密码填入 Web 或 Agent。

`docker compose up --build -d` 使用 `broker/mqtts/mqtts.yaml`；专用个人助手
Compose 使用 `deploy/personal-agent/mqtts.yaml`，从 `/run/secrets/broker-token`
读取回调 token。`node scripts/personal-agent-prepare.cjs` 生成所需秘密。
`scripts/test-env.sh up` 也默认使用 MQTTS。旧 EMQX 配置文件仅保留供迁移参考。

后端先启动 HTTP，再异步连接 Broker；MQTTS 启动不要求回调已经在线，但回调
失败时拒绝客户端。`/health/ready` 仅在 DB、Redis、MQTT 持久订阅均可用时成功。
Compose 的 Broker 健康检查只验证监听端口，应用就绪应检查后端 ready。

## 角色与资源范围

| 操作 | 普通用户 | 管理员 |
| --- | --- | --- |
| 自己的 Agent、Key、私聊 | 允许 | 相同规则 |
| 其他人的私有 Agent / 对话 | 拒绝 | 同样拒绝 |
| 群信息、成员、历史、实时消息 | 当前成员/群主 | 相同规则 |
| 添加普通群成员 | 群主/群管理员 | 相同规则 |
| 添加群管理员、移除其他管理员 | 群主 | 相同规则 |
| 移除群主、注入 owner 角色 | 拒绝 | 拒绝 |
| 查看账号、修改用户角色/状态 | 拒绝 | `/admin/users` |

平台管理员和群管理员是不同角色。管理员不能自行降权或停用自己；由另一位
管理员操作。事务锁及重新检查操作者身份避免并发降权留下零个有效管理员。
所有角色/状态变更写入审计日志。账号管理员入口不提供读取他人消息的后门。

现有账号、新注册和手机号注册都默认为 `user`，注册/Profile 请求不能提升权限。
在生产数据库副本演练后应用 `backend/migrations/20261004_user_roles.sql`；它可以
重复执行，增加默认值和角色约束。启动 AutoMigrate 会添加列，但发布仍应执行 SQL。
首位管理员通过拥有数据库凭据的运维命令提升一个**已有活跃账号**：

```sh
# 本机：backend 目录，使用与服务相同的数据库环境。
go run ./cmd/admin-user -username <existing-account>
# 根 Compose 镜像包含 /app/admin-user。
docker compose exec backend /app/admin-user -username <existing-account>
# 个人助手 Compose 需经 secret wrapper 载入数据库密码。
docker compose -f deploy/personal-agent/compose.yaml exec backend \
  /bin/sh /app/secret-env.sh /app/admin-user -username <existing-account>
```

接口：`GET /api/v1/admin/users?page=1&page_size=20&search=...` 和
`PUT /api/v1/admin/users/:id/access`（`role: user|admin`、`status: 0|1|2`，
分别为停用/活跃/封禁）。每次请求都读取当前账号角色和状态；不依赖旧 JWT 的角色。

## MQTT 权限与即时撤权

Broker 的 HTTP provider 使用同一个私密 token 访问
`/internal/broker/authentication`、`/internal/broker/authorization`。
回调不应暴露到公网入口；不能在日志中输出请求体/密码。连接绑定 username、
client ID、owner、Agent Key、到期时间以及订阅/发布范围。

MQTTS 在发布、订阅、**每次投递**时检查权限。移出群聊、禁用 Agent、撤销 Key
或封禁账号后，既有连接也不能继续越权收发。已交付到客户端的数据不会被追回。
密码过期后连接可能仍然存在，但读写被拒绝；Web/worker 应续期并重新连接。
后端、Redis 或授权回调不可用时拒绝访问；没有匿名降级或 HTTP ACL 缓存。

保持后端 `BROKER_SECURITY_REQUIRE_MESSAGE_IDENTITY=true` 和 Broker
`message_identity_prefix: "chat/"` 配套。Broker 从真实 MQTT payload 提取发送者，
后端检查其与 CONNECT 身份一致，并拒绝冲突的 topic/conversation/sender 字段。
普通用户不能借群聊发布权限冒充另一个用户或 Agent。

## 公网 TLS 与已有 Broker

用 TLS 代理将公网 `mqtts://broker.example:8883` 与
`wss://chat.example/mqtt` 转到私网 MQTTS 1883，保留 WebSocket Upgrade。
`MQTT_TCP_PUBLIC_URL` / `MQTT_WS_PUBLIC_URL` 必须是客户端可解析、可达的地址，
证书须匹配主机名；原生明文端口只在私网或 loopback 开放。
服务器间也使用 TLS 时设置 `MQTT_BROKER=mqtts://...`。

后端可选：`MQTT_TLS_CA_FILE`（自定义 CA）、`MQTT_TLS_CERT_FILE` 与
`MQTT_TLS_KEY_FILE`（客户端证书，必须成对）、`MQTT_TLS_SERVER_NAME`（验证主机名）。
对应证书以只读文件挂载，Compose 自定义 override 需传递这些变量。
不支持跳过证书验证。浏览器 WSS 使用浏览器信任库，不能靠后端 CA 配置绕过。
自建 Broker 若已在远端运行，也需升级同样的 HTTP provider 和回调配置。

## 迁移与验证

先备份 PostgreSQL 并在独立副本应用角色迁移。启动独立 MQTTS/后端验证 ready，
再切换运行环境的 Broker URL 和公开 WS/TCP 地址并重连客户端。旧会话密码
不保证跨 Broker 复用，应重新 bootstrap。MQTTS 不迁移 EMQX 内存中的 retained
消息/离线队列；应用的持久聊天历史仍从 PostgreSQL catch-up 获取。
新旧消费者不能同时处理同一条实时流。保留旧 Broker/数据库快照作为回滚依据。
从旧 Compose 切换时，先用旧配置停止该 project 的 EMQX 容器，再启动新配置，
避免它继续占用同一 TCP/WS 端口；不要使用 `down -v` 删除数据卷。测试栈从旧版
重新执行 `scripts/test-env.sh up` 前也需先停止其旧 EMQX 容器。

```sh
cd backend && go test ./...
# 仓库根目录
npm --prefix frontend run build
CHAT_UI_START=1 npm --prefix frontend run test:chat
# 独立栈，环境中的 DB/Redis 配置必须指向验收库。
MQTTS_TEST_API_URL=http://127.0.0.1:18081 \
MQTTS_TEST_ADMIN_CLI=/absolute/path/to/admin-user \
node scripts/test-environment/mqtts-permissions.mjs
```

该验收脚本创建临时账号，验证真实 WebSocket/TCP 双向收发与落库、越权访问、
伪造发送者、移出群聊后的已有订阅、封禁后的 JWT/refresh/Agent Key 和并发
管理员降权。不要针对生产库运行。Broker 自带的 Python 集成测试另外覆盖
MQTT 3.1.1/5、错误密码/client ID、异常回调、过期身份和不完整配置启动失败。
截图和实际账号仅保存在忽略的 `run/`，不提交 Git。
