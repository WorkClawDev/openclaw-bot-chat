# 自有 MQTTS 与权限管理

默认 Broker 是 [ChangerR/mqtts](https://github.com/ChangerR/mqtts)。此处 MQTTS
指你的 C++ 项目；原生监听是 TCP/WS，公网 TLS/WSS 由入口代理终止。
聊天数据继续存储在 PostgreSQL，Redis 保存短期 MQTT 身份。

## 两个项目的边界

MQTTS 是独立的通用 Broker：独立源码、构建、测试和版本发布，不读取本项目的
数据库，不理解 user/admin、Agent、群聊或聊天 JSON。HTTP provider 是可选的
通用扩展，也可使用它自己的 SQLite/Redis provider。聊天项目通过 MQTT 和
[HTTP 授权契约 v1](https://github.com/ChangerR/mqtts/blob/codex/openclaw-auth/docs/http-auth.md)
接入；所有业务权限、发送者识别与适配代码由本项目维护。

首次连接和新权限仍需后端授权；已有授权由 Broker 的本地有界缓存处理，消息
热路径不查询 HTTP、Redis 或聊天数据库。两个项目无需共享源码、数据库或发布
流程。后端故障时，缓存授权可以用到原会话到期，且从上次成功授权起不超过
5 分钟；故障不会续期。新连接、新权限或过期授权仍被拒绝。

## 使用独立构建的镜像

本仓库不再检出或编译 MQTTS 源码，也不要求两个仓库为同级目录。设置
`MQTTS_IMAGE` 为已构建并验证的镜像标签或 registry digest。Broker 仓库的 CI
提供 `mqtts-image-<source-sha>-linux-amd64` 工件，版本标签的 Release 提供相同
运行镜像；下载后按以下方式装载：

```sh
# 在下载目录执行，先核对 metadata.json 中的 source_revision。
sha256sum -c SHA256SUMS
docker load --input mqtts-image.tar.gz
# 使用 metadata.json 的 image 值，也可自行 retag/push 到私有 registry。
```

镜像需要支持 HTTP 契约 v1 的 `publish_payload: base64` 及可选缓存扩展。当前 PR 验收版本记录
在 `broker/mqtts/compatibility.json`，CI 直接下载那次独立构建的镜像工件，不编译
C++。工件保留90天；长期部署使用独立 Release 下载或固定 registry digest。
`MQTTS_TEST_IMAGE` 仓库变量/手动工作流输入可以指定要测试的已发布镜像。
MQTTS 新版本先经过本项目兼容性验证，再显式升级部署的镜像引用。

根目录 Compose 需要独立随机 `BROKER_SECURITY_CALLBACK_TOKEN`、`MQTT_PASSWORD`
和 `JWT_SECRET`（至少32字符），放在忽略的 `.env`，同时设置 `MQTTS_IMAGE`。
不要把密码写入 MQTT URL。`MQTT_USERNAME`、`MQTT_CLIENT_ID` 是后端持久消费者
身份；bootstrap 返回各客户端独立随机会话，不能把后端密码填入 Web 或 Agent。

```sh
# broker profile 只启动预构建镜像；--build 仅构建本项目服务。
docker compose --profile broker up --build -d
```

根 Compose 使用 `broker/mqtts/mqtts.yaml`；个人助手 Compose 使用
`deploy/personal-agent/mqtts.yaml`，从 `/run/secrets/broker-token` 读取回调 token。
`node scripts/personal-agent-prepare.cjs` 生成本项目的秘密。测试脚本
`scripts/test-env.sh up` 默认启动选定的预构建镜像；不会编译 Broker。
旧 EMQX 配置文件仅保留供迁移参考。

## 连接单独部署的 Broker

在独立 MQTTS 部署中配置 HTTP provider，将认证/授权 URL 指向可达的聊天后端
私网地址，并让两侧使用相同 callback token。本项目提供的 YAML 是消费方接入
示例，外部 Broker 应按自己的部署地址调整。无需把后端放进 Broker 的 Compose。

聊天项目 `.env` 设置 `MQTT_BROKER`、`MQTT_TCP_PUBLIC_URL`、`MQTT_WS_PUBLIC_URL`
以及上述后端与回调凭据，然后**不启用 broker profile**：

```sh
docker compose up --build -d
```

此时不会创建本地 MQTTS 容器。后端先启动 HTTP，再异步连接 Broker；
`/health/ready` 仅在 DB、Redis、MQTT 持久订阅均可用时成功。Broker 端口健康
不等于应用已经就绪。个人助手 worker 还需设置 `MQTT_WORKER_URL` 为 worker
可达的 TCP/TLS 地址。公网入口和证书配置见下文。

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

## MQTT 权限、缓存与撤权

Broker 的 HTTP provider 使用同一个私密 token 访问
`/internal/broker/authentication`、`/internal/broker/authorization`、
`/internal/broker/cache-version`。
回调不应暴露到公网入口；不能在日志中输出请求体/密码。连接绑定 username、
client ID、owner、Agent Key、到期时间以及订阅/发布范围。

MQTTS 在发布、订阅、**每次投递**时检查本地授权。缓存绑定每次 CONNECT 产生的
独立会话、username/client ID、操作和 Topic。移出群聊、禁用 Agent、撤销 Key
或封禁账号后，成功的权限变更接口更新应用 Redis 内的随机权限版本。Broker
通过 HTTP 每250 ms轮询该版本，变化后清除缓存；在途旧响应不能恢复旧授权。
撤权传播需要轮询间隔加网络/服务处理时间，并非跨进程的原子操作；隔离集成测试
要求2秒内收敛。已交付到客户端的数据不会被追回。
密码过期后连接可能仍然存在，但读写被拒绝；Web/worker 应续期并重新连接。

本项目配置10秒新鲜期、最长300秒授权租约、16384条分片 LRU。新鲜命中不访问
HTTP；过新鲜期的命中立即返回，同时合并为一个后台刷新。显式拒绝清除旧授权；
后端/Redis/数据库故障返回503，保留原租约，不推迟到期时间。拒绝最多缓存1秒。
CONNECT 始终验证密码；跨连接不复用登录结果。4个独立 HTTP 工作者复用连接，
队列最多64个请求、16 MiB请求体，500 ms超时，熔断与重试冷却1秒；慢回调不会
阻塞 MQTT 事件线程。权限版本轮询使用单独工作者。

接入示例配置2个 MQTT 事件线程，每个连接使用独立协程，每个事件线程另有4个
发送协程。HTTP 授权线程与它们分开。冷投递授权尚未返回时，任务暂时让出发送
队列，其他客户端可以继续收消息；同一客户端的消息按提交顺序发送。等待中的
任务计入每个发送协程1000条的上限，完成时重新检查会话到期和授权版本。队列
饱和、慢 socket 或大范围缓存失效仍可能增加延迟，新权限超时/过载会被拒绝。
并发回归与可复现压测脚本由独立 Broker 仓库维护，见上述契约文档的并发章节；
聊天项目只选择通过兼容性验证的 Broker 版本。

权限变更通知失败会在 Redis 恢复后重试。它不是事务性 outbox；手工改数据库、
进程在提交后通知前退出等情况依靠下一次后台授权刷新发现，服务故障时仍受5分钟
上限约束。新增权限变更路由需接入失效中间件。缓存维持的是已授权 MQTT 传输，
不代表后端故障时历史查询、API 或消息持久化仍然可用。

保持后端 `BROKER_SECURITY_REQUIRE_MESSAGE_IDENTITY=true`，接入配置启用通用
`publish_payload: base64`，`max_payload_bytes: 1048576`。MQTTS 将原始 MQTT payload
编码为 Base64 放入回调的 `payload`，并标注 `payload_encoding: "base64"`。Broker
不理解业务字段；后端解码、识别 `chat/` 消息，并检查发送者与 CONNECT 身份
一致，拒绝冲突的 topic/conversation/sender 字段。普通用户不能借群聊发布权限
冒充别人。业务事件消息也由后端决定处理方式。

解码前后都有长度限制，缺少 payload、非法编码/JSON、超限内容在严格模式下
被拒绝。回调会携带完整消息内容，必须走受保护的私网或 HTTPS，且不记录请求体。
Base64 增加约1/3体积；只在未命中或刷新时构造回调，消息仍由 Broker 直接投递。
消费方配置 `publish_cache_ignored_fields: '["id","timestamp","content"]'`：这些字段
不参与当前权限判断。其他字段（包括 from、sender、topic/conversation、未知字段
和大小写别名）全部保留在摘要中，避免同一 Topic 下改写发送者命中旧授权。
重复 JSON 键、非法 JSON 和深层嵌套退回完整字节摘要。将来权限若依赖内容、ID
或时间，必须同步移除对应的忽略项。通用 Broker 默认按完整 payload 取摘要，
没有硬编码任何聊天字段。
旧 `message_identity_prefix`/`message` 投影契约已移除，应先在隔离环境同步升级
消费方适配和接入配置。MQTTS 会拒绝不认识的 provider 配置，避免静默降级。

私有存储下，旧 `/assets/image/:id`、`/assets/audio/:id` 公开重定向不能再替消息
附件续签。下载地址通过已授权的消息历史获取。仅附件所有者主动选作自己、
自己 Agent 或群聊头像的图片可以公开重定向；其他账号复制附件 URL 到头像
字段不能使它公开。已签发链接在其过期前仍然有效。

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
远端 Broker 需满足这里的通用认证/授权契约；无需安装聊天项目源码。

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
MQTTS_TEST_STATE_DIR=run/mqtts-permissions \
MQTTS_TEST_ADMIN_CLI=/absolute/path/to/admin-user \
node scripts/test-environment/mqtts-permissions.mjs
```

该验收脚本创建临时账号，验证真实 WebSocket/TCP 双向收发与落库、越权访问、
伪造发送者、移出群聊后的已有订阅、封禁后的 JWT/refresh/Agent Key 和并发
管理员降权。不要针对生产库运行。Broker 自带的 Python 集成测试另外覆盖
MQTT 3.1.1/5、错误密码/client ID、异常回调、过期身份和不完整配置启动失败。
截图和实际账号仅保存在忽略的 `run/`，不提交 Git。

CI 还运行 `scripts/test-environment/mqtts-cache-outage.mjs`：显式指定隔离后端的
`MQTTS_TEST_BACKEND_PID` 和 `MQTTS_TEST_BACKEND_EXECUTABLE`，校验进程身份后
短暂暂停它，等待超过10秒新鲜期，验证200条 WebSocket/TCP 双向消息完整送达，
同时拒绝新连接。脚本在退出时恢复后端，并有额外恢复看门狗。该测试使用上一步
生成的临时账号，故障报告仅包含通过状态与延迟，不上传账号/秘密。
