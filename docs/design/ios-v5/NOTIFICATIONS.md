# V5 聊天通知实现与验收

产品仍是多机器人聊天。通知设置应控制当前安装的机器人消息提醒；普通文本、图片、音频和文件使用同一通知入口，点击后读取原始对话。用户正在阅读的聊天不应再弹前台提醒。

## 服务端实现

- `GET /api/v1/push/status`：已认证客户端查询当前服务是否配置 APNs。
- `PUT /api/v1/push/devices/:installation_uuid`：注册当前设备。JSON 字段为 `token`、`environment`（sandbox/production）、`language`（en/zh）；账户从 JWT 取得，客户端不能指定接收人。
- `DELETE /api/v1/push/devices/:installation_uuid`：关闭当前账户对此安装的推送，幂等；不能关闭其他账户的注册。
- 设备令牌或所属账户改变时换 revision。旧通知仍绑定原接收人和 revision，不会跟随设备转到另一个账户。30 天未续期的注册不再投递。
- 消息与待发送记录在同一 PostgreSQL 事务内提交。MQTT 重投不会重复创建消息和通知；任何队列写入失败都会回滚该消息插入。
- 只对来自有效机器人的消息排队。单聊仅发给路径中的人类接收人；群聊包括群主和有效人类成员。机器人之间的消息不会通知它们的所有者。
- 发送前重新核对用户、机器人、群和成员状态；离群、机器人移除、设备关闭、账户切换、消息删除后的待发记录会取消。
- worker 使用可回收租约和旧租约写入保护，发送超时 15 秒、租约 60 秒。临时错误按 15 秒起的指数退避重试，最多 12 次；待发记录 24 小时过期。终态记录保留 7 天。
- APNs 使用 HTTP/2、ES256 签名和缓存的 provider JWT。设备失效会停止后续发送；令牌更新后，旧 APNs 失效响应不能关闭新令牌。
- 通知载荷只含通用中英文提醒及账户/对话/消息路由标识，不含聊天正文、机器人名称、文件 URL 或凭据。令牌不返回 API、注册 SQL 不记录令牌，传输错误也不暴露 APNs URL。
- `accepted` 仅表示 APNs 已接受请求。网络重试保持相同 APNs ID 和 collapse ID，但 Apple 侧展示与数据库提交无法形成一个事务，不能据此承诺实机严格一次展示。

## iOS 接入

- `ChatPushAppDelegate` 接收系统权限、设备令牌和通知点击回调；项目配置 iOS/macOS 推送 entitlement 及签名环境。实际发布仍需要有效签名和对应 provisioning profile。
- `ChatPushNotifications` 把权限、系统注册与服务器确认分开。只有注册 API 明确确认后才显示“已开启”；服务器未配置、权限拒绝、注册失败、撤销待确认都有独立状态。
- 注册、令牌更新和撤销串行执行，旧账户/旧令牌的迟到响应不能覆盖新状态。关闭、注销、更换服务地址会撤销原服务器订阅；失败只持久化用户和服务器路由，下次匹配登录使用新凭据重试，不持久化退出账户的 JWT。
- 通知点击先核对当前账户，再通过服务端历史权限与机器人/群资料接口解析目标。载荷中的任意 URL、名称和非规范会话路径不能直接用于导航。
- 通知聊天在当前原生页面或 sheet 上方打开，返回时恢复原页面。无法访问的聊天使用最上层原生控制器显示错误，关闭错误不会销毁原设置页或草稿。冷启动到达的点击可等待认证；账户改变会取消旧导航并清除旧错误。
- 前台正在阅读的同一聊天不展示提醒。可见聊天由页面实例持有，旧页面消失不会清除新页面的可见状态。

## 配置与发布边界

默认 `PUSH_ENABLED=false`。未配置的服务器返回 `available:false`，注册接口返回 503，不能把系统权限授权显示为推送已就绪。

启用需要 `PUSH_TEAM_ID`、`PUSH_KEY_ID`、`PUSH_TOPIC` 和 `PUSH_PRIVATE_KEY_PATH`。topic 必须与实际签名 App 的 Bundle ID 对应；private key 以只读挂载的 `.p8` 文件提供。当前默认 topic 为 `site.changer.clawchat`。不要把私钥、设备令牌或真实账号写进仓库。启动配置错误会明确失败。

新增 `push_devices`、`push_deliveries` 两张表，通过现有启动 AutoMigrate 或 `backend/migrations/20261004_chat_push.sql` 安装。关闭 feature flag 会停止新通知排队和发送，不修改既有聊天记录。没有执行生产迁移或部署。

## 验收边界与后续工作

服务端和 iOS 接入代码已经补充。验收仍按证据分别记录，不能由代码存在推断端到端完成：

1. 单元测试覆盖注册确认、权限/服务器失败、令牌更新、撤销/账户竞态、冷启动待认证、失效目标和前台过滤。
2. `push-settings-final.xcresult` 的 72 项 Swift 测试与两个原生 UI 场景通过：拒绝后前后台切换保留原因、未配置服务不显示已就绪并支持重试/关闭。`push-native-content.xcresult` 通过原生允许权限、后台 simctl 通知点击、先鉴权再解析目标、加载历史正文、无错误弹窗和返回设置页；耗时 36.1 秒。此时没有真正 APNs 设备令牌，设置页保持连接失败而非伪造成功。
3. 手机新增 `push-matrix-group.xcresult`、`push-matrix-cold.xcresult` 和 `push-error-preserved.xcresult` 通过：群聊先鉴权再解析/读历史；真正终止 App 后通过系统通知恢复账户并打开正文；权限撤销显示错误，关闭后仍在原设置页。冷启动使用 Debug 下仅限 localhost 的初次端点持久化，系统重新启动时不依赖 XCTest 启动参数。`push-navigation-units.xcresult` 当前 72 项 Swift 回归通过。`push-ipad-group.xcresult` 和 `push-ipad-forbidden.xcresult` 通过 iPad 真实设置工作区中的群聊通知/返回、权限撤销/错误关闭，分别 38.3 秒和 34.0 秒。`push-ipad-cold-final.xcresult` 进一步通过 iPad 真正终止 App 后的原生通知点击、账户恢复、历史正文与返回首页（1 项实际测试，0 失败/跳过）。各消息类型与账号切换的完整原生通知矩阵仍需补齐。
4. 正确签名的实机和 Apple APNs 实际投递仍未验证，不能用本地 HTTP/2 provider 测试或 simctl 注入代替。

服务端测试通过后也不能把整条通知链路标记为已完成。完整 V5 目标还包括先前验收矩阵中未完成的其他功能和实机滚动性能。

历史失败保留：`push-matrix-forbidden.xcresult` 暴露根视图 SwiftUI alert 会关闭原设置 sheet，现已改为最上层 UIKit alert 并由 `push-error-preserved.xcresult` 复验通过；`push-ios-initial.xcresult` 单元测试通过但 UI runner 的 AX 启动失败；`push-settings-ui.xcresult` 系统中文按钮定位失败；`push-settings-verified.xcresult` 发现权限拒绝原因被前台同步覆盖；`push-native-navigation.xcresult` 因 fixture 账号不匹配而未打开聊天。`push-native-matched.xcresult` 的导航断言通过，但视觉复查发现 fixture 缺失历史路径造成错误弹窗，不作为完整内容验收；最终由 `push-native-content.xcresult` 补足。

## 测试命令

`cd backend && go test ./...` 运行常规测试；未设置数据库环境时 PostgreSQL 专项会明确 skip。启用现有隔离测试栈的 postgres 服务后，在仓库根目录运行 `python3 scripts/test-environment/test-ios-push.py`，从忽略的 `.env.test` 读取测试数据库凭据，运行全部 Go 测试和真实 PostgreSQL 专项。专项为每个用例创建并清理独立 schema，不改其他测试业务数据。APNs provider 使用临时本地 TLS HTTP/2 测试端点，不向 Apple 或真实设备发送。

iOS 本机 UI：运行 `node scripts/test-environment/ios-push-fixture.cjs`，Debug `build-for-testing` 后在专用 ClawChat 模拟器运行 `PushNotificationsV5UITests` 的设置场景。通知点击场景需单独运行，先仅卸载该专用模拟器的测试 App 重置权限，再执行 `python3 scripts/test-environment/ios-push-navigation-test.py --device <ClawChat模拟器UUID> --xctestrun <Debug测试计划路径> --output <新的结果文件前缀>`。可用 `--scenario settings|group|forbidden|cold|media|account` 分别指定场景，每个需要权限的场景之前重装专用模拟器 App。驱动通过 fixture readiness 事件逐条注入通知（每个事件只注入一次），绕过系统代理访问 loopback；不能把它用于真实设备投递验收。

协议参考：[Apple APNs 请求](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)、[令牌认证](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)、[响应处理](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)。


新增原生矩阵用例（验收结果以对应 xcresult 为准）：`media` 连续注入图片、音频、文件三条系统通知，打开后分别检查图片预览、实际 AVPlayer 播放和文件正文，并回到原设置页；`account` 经真实登录界面退出 A、登录 fixture 账号 B，确认延迟的 A 通知不会发起聊天请求，随后 B 通知使用 B 身份读取历史。这些用例复用正式 App 导航、认证和消息视图，但服务端是本机受控 fixture，不代表真实 APNs 或模型执行。通知内容不增加媒体 URL 或正文，只按现有用户/对话/消息标识路由。
