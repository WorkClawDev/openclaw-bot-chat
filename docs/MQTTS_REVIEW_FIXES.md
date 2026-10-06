# Review 修复与验证记录

Broker PR：[ChangerR/mqtts#17](https://github.com/ChangerR/mqtts/pull/17)。聊天项目 PR：[WorkClawDev/openclaw-bot-chat#25](https://github.com/WorkClawDev/openclaw-bot-chat/pull/25)。

26 条 review 意见均有对应实现或明确的安全/兼容性处置。修改按问题分开提交；此前已经完成的两项实现补做了回归验证。Broker 代码版本为 `2c3e159028b2a115bb335b271beae98026353b6e`，独立 [CI](https://github.com/ChangerR/mqtts/actions/runs/37305258747) 的 native、authorization、container 均通过。聊天项目只使用 Protobuf 契约及锁定的独立镜像。

| Review | 处理结果 | 实现提交 |
| --- | --- | --- |
| [#4182580150](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580150) | 检查点失败不再污染追加写入 | [dc33686](https://github.com/ChangerR/mqtts/commit/dc3368610d970513a1b00f737fcedce0e61af405) |
| [#4182580162](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580162) | 检查点暂停与心跳记录有界 | [dc33686](https://github.com/ChangerR/mqtts/commit/dc3368610d970513a1b00f737fcedce0e61af405) |
| [#4182580152](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580152) | 授权服务故障与明确拒绝分开处理 | [2a9b666](https://github.com/ChangerR/mqtts/commit/2a9b66661d2fe62636166f80e70259821908074a) |
| [#4176660681](https://github.com/ChangerR/mqtts/pull/17#discussion_r4176660681) | 认证身份有效期检查 | [2a9b666](https://github.com/ChangerR/mqtts/commit/2a9b66661d2fe62636166f80e70259821908074a) |
| [#4176660685](https://github.com/ChangerR/mqtts/pull/17#discussion_r4176660685) | HTTP 授权 URL 严格解析 | [2a9b666](https://github.com/ChangerR/mqtts/commit/2a9b66661d2fe62636166f80e70259821908074a) |
| [#4182580147](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580147) | 重连先接管会话，再恢复 QoS 0 订阅 | [7a4f987](https://github.com/ChangerR/mqtts/commit/7a4f987bc9666cf68f32afd0b1f79d53c67a1318) |
| [#4182580153](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580153) | 慢 socket 发送超时与清理取消 | [8575d7a](https://github.com/ChangerR/mqtts/commit/8575d7a37dd4a11ad5271edc9fdb9dab54296829) |
| [#4176699176](https://github.com/WorkClawDev/openclaw-bot-chat/pull/25#discussion_r4176699176) | 管理员只提交实际修改的字段 | [c17a584](https://github.com/WorkClawDev/openclaw-bot-chat/commit/c17a5842b0bb7c99d4336969012b319cec738b2a) |
| [#4182580160](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580160) | 坏消息、超大消息和明确拒绝不阻塞后续投递 | [e9a6168](https://github.com/ChangerR/mqtts/commit/e9a616873bc17e96762164c6c077f06fec849736) |
| [#4182583063](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182583063) | 过期的在途消息保留 Packet ID | [1040250](https://github.com/ChangerR/mqtts/commit/104025044b9b105e2d5b32d052f6d3f98110d3b2) |
| [#4182583050](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182583050) | 零有效期与预取有效期一致 | [1040250](https://github.com/ChangerR/mqtts/commit/104025044b9b105e2d5b32d052f6d3f98110d3b2) |
| [#4176699181](https://github.com/WorkClawDev/openclaw-bot-chat/pull/25#discussion_r4176699181) | 停用与恢复账号不再复活旧 JWT/refresh | [4ba31d1](https://github.com/WorkClawDev/openclaw-bot-chat/commit/4ba31d18ea00a099150c47c49cb713f9e2f79086) |
| [#4182583065](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182583065) | 持久会话与实时路径不混用 Packet ID | [ee5d54f](https://github.com/ChangerR/mqtts/commit/ee5d54f4f11cc0b5b2a3526d21b5f9c7c535dcb5) |
| [#4176699183](https://github.com/WorkClawDev/openclaw-bot-chat/pull/25#discussion_r4176699183) | 先检查访问权限再计分页数量 | [4e593b6](https://github.com/WorkClawDev/openclaw-bot-chat/commit/4e593b6a3645d27797c6f51f524f9def3998428d) |
| [#4182583076](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182583076) | 重订阅失败保留原过滤器和 QoS | [d4975c4](https://github.com/ChangerR/mqtts/commit/d4975c41a575f7b022792c5f2edd0b7336b2d8c3) |
| [#4182580146](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580146) | 活消息压缩，不固定占用整个旧日志段 | [f63fc7f](https://github.com/ChangerR/mqtts/commit/f63fc7f71f239ee40ab0e699dc31624aeb34f952) |
| [#4182580151](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580151) | 增量订阅索引与有界过期清理 | [c2dd463](https://github.com/ChangerR/mqtts/commit/c2dd4635852cd9cb5b13ee02d562675e67860507) |
| [#4182583086](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182583086) | 按身份分区失效授权缓存 | [3078667](https://github.com/ChangerR/mqtts/commit/3078667a67e076313fcabfdc6f83aa6fd6612a85) |
| [#4182580149](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580149) | 持久化与实时路径一致排除发布者自身 | [68f39f0](https://github.com/ChangerR/mqtts/commit/68f39f0ba1b99b58d2d1c130b604b48b3969c6e9) |
| [#4182583073](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182583073) | 使用认证主体绑定所有权，拒绝码准确 | [41c8cc1](https://github.com/ChangerR/mqtts/commit/41c8cc1b6bc7aaf50a216a9e79d172bd9e86367d) |
| [#4182580173](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580173) | 完整损坏帧保留并拒启，不推测已提交边界 | [89a0c6c](https://github.com/ChangerR/mqtts/commit/89a0c6c7ca1ad9a1df1e9bbb702b6abdff7627c6) |
| [#4176660683](https://github.com/ChangerR/mqtts/pull/17#discussion_r4176660683) | WebSocket 返回 MQTT 5 负向发布回执 | [041ba06](https://github.com/ChangerR/mqtts/commit/041ba0662688a43416cb6ca72c12af40da8181ea) |
| [#4182573116](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182573116) | 消费者配额、负向 PUBACK 与可选缺口隔离 | [ee0b222](https://github.com/ChangerR/mqtts/commit/ee0b2223e4a22314a7896980c4e63dd8b190cd82) |
| [#4182580175](https://github.com/ChangerR/mqtts/pull/17#discussion_r4182580175) | 明确持久模式的 QoS 2 不兼容边界 | [2c3e159](https://github.com/ChangerR/mqtts/commit/2c3e159028b2a115bb335b271beae98026353b6e) |
| [#4176660688](https://github.com/ChangerR/mqtts/pull/17#discussion_r4176660688) | 远程授权 I/O 使用有界线程池 | [4464e41](https://github.com/ChangerR/mqtts/commit/4464e41e2557e17ed6a2683a105da6bdca07a8bf) |
| [#4176699170](https://github.com/WorkClawDev/openclaw-bot-chat/pull/25#discussion_r4176699170) | 拒绝 SUBACK 后重新连接并订阅 | [c715dd9](https://github.com/WorkClawDev/openclaw-bot-chat/commit/c715dd923c5a6fc8b6101404933b38951462c083) |

## 实际边界

- 默认 `overflow_policy: reject` 保留完整投递：队列满时返回配额错误，相关主题需要背压。Broker 的 `isolate` 是显式启用的策略，会记录新消息缺口并保留旧积压。聊天落库消费者没有独立缺口恢复源，因此没有启用隔离。单个消费者默认 10,000 条 / 32 MiB，需按目标流量和停机时间配置。
- 完整坏帧可能包含已确认消息，不能因它位于文件末尾就删除。保留数据、拒绝启动并进行明确的离线恢复；不完整尾帧仍可自动修复。
- 持久模式支持 QoS 1，未实现持久 QoS 2。磁盘契约为 4；格式 2/3 可升级，但回退需停服备份。没有跨节点日志复制或故障切换保证。

## 验证

- 本机原生全量 62/62 CTest 通过；授权模块 `go test -race ./...` 通过；独立 CI 同时验证镜像启动、授权压力、并发和 fan-in。
- 聊天后端 `go test ./...`、前端生产构建通过。真实 Paho 连接在首次 SUBACK 被拒绝后自动重连，新的订阅成功后才报告就绪，并在持久接收后发 PUBACK。
- 撤权回归测试重复 20 次通过。CI 发现测试用 SQLite 连接与异步审计写入的锁冲突，已在测试夹具中使用单连接；真实 PostgreSQL 的并发管理员更新验收仍单独执行。
- 12 种 Compose 配置组合通过独立部署检查；锁定镜像的 SHA-256、源码版本、存储契约和 Protobuf 摘要均已核验。
- 真实 PostgreSQL/Redis、独立 authz、Broker、API、message-ingest 环境升级后：浏览器协议与 Agent 双向消息、用户/管理员权限、群成员撤权、Agent 密钥撤销、账号停用恢复、旧 JWT/refresh 永久失效、新登录均通过。
- 200 条消息在消费者及 Broker SIGKILL 后按序落库；API 暂停时仍落库 101 条并跨过消费者策略续租；数据库阻塞及消费者 SIGKILL 后恢复 200 条；重复投递不新增行、不复活已删历史，坏业务消息进入死信队列。
- API 与 authz 分别暂停后，缓存授权均继续工作并跨过 freshness 时间。authz 不可用时新连接被拒绝；暂停 API 不阻断独立 authz 的认证。该测试没有延长原始会话或五分钟授权上限。

## 最新 Broker 延迟测量

共享 4 vCPU / 16 GiB Linux 主机，workspace overlayfs，回环 TCP（未启用 TLS），4 KiB QoS 1，刷盘后确认，500 发布者和 500 持久消费者。每个固定速率阶段持续 30 秒；两轮均保留，不选择性删除长尾较差的一轮。延迟从发布开始计至消费者收到完整消息；不是 PostgreSQL 提交延迟。

| 场景 | 首轮接收 P95 / P99 | 复测接收 P95 / P99 |
| --- | --- | --- |
| 1,000 条/秒；每轮 30,000 条 | 4.13 / 6.48 ms | 3.86 / 5.59 ms |
| 3,000 条/秒；每轮 90,000 条 | 363.16 / 466.52 ms | 7.99 / 20.76 ms |
| 窗口 4 饱和；每轮 64,000 条 | 217.31 / 280.19 ms | 233.30 / 385.86 ms |

所有尝试的消息均完成实际投递和内容/序列检查。饱和吞吐首轮 7,465 条/秒、复测 6,748 条/秒。首轮 3,000 条/秒阶段的客户端事件循环延迟 P99 达 217.6 ms，复测为 8.7 ms；测试机另有常驻服务，观测到较高内存使用量。当前数据不足以把该波动归因于 Broker 某一段代码，也不足以承诺生产 P99。1,000 条/秒两轮 P99 为 6.48 / 5.59 ms；3,000 条/秒两轮差异必须纳入容量判断。

真实应用的 WebSocket↔TCP 顺序 QoS 1 验收，健康 P95 约 49.9–50.6 ms，暂停依赖后约 50.6–51.8 ms；这是不同负载，不能用回环 TCP 的低延迟替代它。PostgreSQL 落库时长不包含在这些消息接收指标中。

原始数据：[首轮](performance/mqtts-review-latency.json)、[复测](performance/mqtts-review-latency-repeat.json)。重现命令见 Broker 的 `unittest/durable_latency.py`；指定 workspace 下的 `TMPDIR`，不要将 tmpfs 数据误当成实际磁盘性能。

## 聊天界面复测

生产构建下 12/12 功能测试、7/7 性能场景通过，包括 1,000 / 5,000 / 10,000 条消息、群聊、移动视口与 4 倍 CPU 降速、流式 Agent 输出。测试未观测到空白帧，常规滚动场景最多渲染的消息节点少于 60，向上阅读时保持锚点，回到最新位置正常。帧时间原始数据保留在 [滚动报告](performance/chat-review-scroll.json)，不能把“功能断言通过”解释为所有设备始终 60 FPS。

10,000 条消息的桌面滚动帧时间 P95/P99 为 16.7/16.8 ms；移动视口、4 倍 CPU 降速下滚动为 16.8/33.4 ms，连续收消息为 49.9/50.1 ms。后一个场景仍有明显掉帧空间，不能声称弱设备上的收消息过程始终丝滑。

真实 Chromium 页面已验证登录、MQTT 发布、PostgreSQL 落库、刷新后的历史、管理员账号检索，未出现浏览器运行时错误。
