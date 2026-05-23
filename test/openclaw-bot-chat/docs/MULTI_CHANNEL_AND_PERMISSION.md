# Discord 插件源码研究：多通道与权限审批

研究时间：2026-04-10

目标：分析 BetterDiscord、Vencord、discord.js 与 Discord 官方 API 中，多通道运行与权限审批的实现机制，并提炼可借鉴设计模式。

## 结论先行

最重要的结论有两条：

1. BetterDiscord / Vencord 这类“客户端改造插件”并没有 Discord Bot 那种完整的权限声明与审批链路。它们更像运行在 Discord 客户端内部的扩展层，默认继承当前登录用户在客户端能看到的大部分上下文。
2. 真正成熟的“多通道 + 权限审批”模型主要在 Discord API / discord.js 这一侧。它的核心不是插件清单，而是 `guildId` / `channelId` / `threadId` 上下文、权限 bitfield、channel overwrite、OAuth2 安装授权、应用命令权限以及 privileged intents。

因此，如果要给 `openclaw-bot-chat` 设计“多通道”和“权限审批”，应该：

- 多通道参考 discord.js 的上下文路由和按 scope 隔离状态。
- 权限审批参考 Discord API 的分层授权模型。
- 不要照搬 BetterDiscord / Vencord 的信任模型，因为它们基本没有细粒度运行时审批。

## 一、对比总览

| 维度 | BetterDiscord | Vencord | discord.js / Discord API |
| --- | --- | --- | --- |
| 运行位置 | Discord 客户端内 | Discord 客户端内 | 独立 Bot / App 进程 |
| 多通道感知 | 通过客户端 store 感知当前 guild/channel | 通过 store、消息事件、上下文菜单参数感知 | 事件天然携带 `guildId` / `channelId` / `context` |
| 多通道隔离 | 插件自己做状态分片 | 插件自己做状态分片 | 框架层和数据模型天然按 guild/channel/thread 分层 |
| 权限声明 | 无正式 manifest 权限字段 | 无正式 `permissions` 字段 | OAuth2、命令权限、权限 bitfield、privileged intents |
| 权限审批 | 主要靠发布规范，不是运行时审批 | 主要靠仓库/构建信任，不是运行时审批 | 安装审批 + 管理员配置 + 运行时检查 |
| 高风险能力 | 平台规范禁止一部分行为，但不是沙箱 | `native.ts` 可直接用 Node API | 高风险权限和 privileged intents 有显式开关/审批 |

## 二、BetterDiscord

### 2.1 多通道实现

BetterDiscord 的插件模型本身没有“为每个频道单独起一个插件实例”的概念。插件是单实例挂在客户端里的，感知不同服务器/频道主要靠两种机制：

1. 导航切换回调
2. Discord 内部 Flux store

官方文档在插件结构里提供了 `onSwitch` 可选函数，语义就是“每次用户切换视图时调用”，包括切换服务器或频道。这说明 BetterDiscord 的通道切换不是通过多实例，而是通过单实例插件监听客户端导航变化。

另外，BetterDiscord 官方类型把常用 store 直接列出来了：

- `GuildStore`
- `SelectedGuildStore`
- `ChannelStore`
- `SelectedChannelStore`
- `MessageStore`

源码层面，`BdApi.Webpack.getStore(name)` 会从 Discord 内部 webpack 模块中拿到对应 store。也就是说，多通道感知的核心不是 BetterDiscord 自己维护 channel runtime，而是“借壳” Discord 客户端已有的全局状态树。

### 2.2 状态隔离与消息路由

BetterDiscord 没有内建的 per-channel state container。插件如果要隔离多个服务器/频道的状态，通常只能自己按 key 管理，例如：

- `guildId -> state`
- `channelId -> state`
- `guildId:channelId -> state`

消息路由也不是插件框架统一派发的“多通道总线”，而是插件自行：

1. 从 `SelectedChannelStore` 读取当前 channel
2. 从 `MessageStore` / `ChannelStore` 读取消息与频道实体
3. 用 patch、observer 或其他 UI 钩子把逻辑挂到当前视图

这是一种“读客户端当前上下文”的模式，不是服务端意义上的消息总线。

### 2.3 权限审批模型

BetterDiscord 的插件 meta 字段只有名称、作者、版本、源码链接等信息，没有权限声明字段。插件主体只要求实现 `start()` / `stop()`，可选实现 `getSettingsPanel()`、`observer()`、`onSwitch()`。

这意味着：

- 没有类似浏览器扩展 `permissions` 的声明式清单
- 没有内置“首次启用时逐项审批权限”的流程
- 没有框架级 runtime permission check

BetterDiscord 的“安全边界”主要靠发布规范，而不是运行时沙箱。官方 Guidelines 明确禁止：

- 访问私密信息
- 移除安全特性
- 无用户同意采集数据
- 新插件使用 `child_process`

但这些是审核/分发规则，不是 host 在执行插件时做的能力裁剪。

### 2.4 可提炼代码模式

- 导航事件驱动：`onSwitch()` 只在上下文变化时刷新，而不是全局轮询。
- Store 发现模式：通过 `BdApi.Webpack.getStore()` 绑定 Discord 内部 store，而不是重复维护一套 guild/channel 数据模型。
- 单实例 + 自行分片：宿主只给一个插件进程，插件作者自己按 `guildId/channelId` 隔离状态。

## 三、Vencord

### 3.1 多通道实现

Vencord 比 BetterDiscord 更系统化，但本质仍是“客户端内插件”。

它在 `src/webpack/common/stores.ts` 中显式暴露了 Discord store：

- `GuildStore`
- `SelectedGuildStore`
- `ChannelStore`
- `SelectedChannelStore`
- `MessageStore`
- `PermissionStore`
- `GuildChannelStore`

这说明它的多通道感知同样建立在 Discord 客户端现有状态之上。

除此之外，Vencord 还把“通道上下文”直接塞进 API：

- `MessageEvents` 的 pre-send / pre-edit listener 直接收到 `channelId`
- `ContextMenu` patch callback 会收到 `guild`、`channel`、`message`、`user` 等参数
- Commands API 执行命令时会拿到 `ctx.channel.id`

这比 BetterDiscord 更方便，因为它把“当前操作落在哪个 channel/guild”直接作为 API 入参暴露给插件。

### 3.2 状态隔离与消息路由

Vencord 仍然没有“一个频道一个插件 runtime”的宿主模型。插件是全局注册的，隔离方式还是作者自己做分片。

不过 Vencord 提供了更明确的路由切入点：

- `flux` 事件订阅
- `commands`
- `contextMenus`
- `onBeforeMessageSend`
- `onBeforeMessageEdit`
- `onMessageClick`

这些 API 的共同特点是：宿主负责把事件送到插件，但 scope 识别由事件上下文本身提供。插件侧最合理的做法仍是按 `guildId/channelId/threadId` 或消息对象 ID 做状态隔离。

### 3.3 权限审批模型

Vencord 的 `definePlugin()` / `PluginDef` 接口里有：

- `name`
- `description`
- `authors`
- `commands`
- `settings`
- `flux`
- `contextMenus`
- `patches`

但没有 `permissions` 字段。

另外，Vencord 文档明确区分了：

- `index.ts` 运行在 browser，可用浏览器 API
- `native.ts` 运行在 Node.js，可用 `fs`、`child_process` 等 Node API

基于这些源码和文档，我的判断是：

- Vencord 也没有终端用户可见的细粒度 runtime permission approval 流程
- 它的安全假设是“你信任这份插件代码/构建产物”
- 真正的风险边界在 browser 与 native 的运行位置差异，而不是按能力动态审批

这里要强调：这是根据 `PluginDef`、插件文档与 API 形态做出的推断，不是 Vencord 文档里直接写出的制度说明。

### 3.4 可提炼代码模式

- 上下文显式化：事件 API 直接传 `channelId` / `message` / `guild`，减少插件重复查询 store。
- 能力分层：browser-side UI/patch 能力和 native-side Node 能力分开文件。
- 宿主 API 聚合：commands、message hooks、context menu patch 统一进入插件定义，便于治理。

## 四、discord.js 与官方 Discord API

这部分才是“多通道和权限审批”最成熟、最值得借鉴的来源。

### 4.1 多通道实现

#### 4.1.1 事件天然带 scope

在 discord.js 的 `MessageCreateAction.handle(data)` 中，消息事件首先按 `data.channel_id` 以及可选的 `data.guild_id` 解析 channel，然后把 message 加进对应 channel 的消息缓存，再发出 `messageCreate` 事件。

这说明消息路由的第一原则是：

- 先 resolve `channel_id`
- 再把消息归属到该 channel 的 manager/cache
- 最后把具备 scope 信息的实体对象交给上层逻辑

交互事件也是同样思路。`BaseInteraction` 在构造时直接保存：

- `channelId`
- `guildId`
- `appPermissions`
- `memberPermissions`
- `context`

所以 discord.js 的多通道不是“插件自行猜测当前频道”，而是协议 payload 一开始就把 scope 带进来。

#### 4.1.2 数据结构天然分层

discord.js 的核心实体天然按 Discord 域模型分层：

- `client.guilds`
- `guild.channels`
- `channel.messages`
- `interaction.channelId`
- `message.guildId`

这种分层让“跨多个服务器/频道运行”变成一个普通建模问题，而不是插件技巧。

#### 4.1.3 状态隔离

discord.js 的惯用隔离 key 是：

- `guildId`
- `channelId`
- `threadId`
- `commandId`
- `userId`

如果你的 bot 在 1000 个 guild 中运行，你不会“切换当前频道”，而是每个事件都携带自己的 scope。框架通过 cache manager 和实体关系把这些 scope 组织起来。

### 4.2 权限审批模型

Discord 的权限模型是分层的，不是一次性开关。

#### 4.2.1 安装时授权

官方 OAuth2 文档说明，bot 被加入 guild 时，管理员会授予一组 bot permissions。这个动作本质上就是第一次审批。

特点：

- 授权对象是 app / bot
- 审批人是 guild 管理员
- 审批结果是 guild 级别权限 bitfield

#### 4.2.2 命令声明时授权边界

应用命令支持：

- `default_member_permissions`
- `integration_types`
- `contexts`

其中：

- `default_member_permissions` 决定默认需要哪些 guild 权限才能看到或执行命令
- `integration_types` 决定命令可以安装到 guild 还是 user
- `contexts` 决定命令能出现在哪些交互面：guild、bot DM、私聊

这相当于“声明式入口权限”。

一个很重要的细节是：把 `default_member_permissions` 设为 `"0"`，等于默认全禁，只给管理员或后续显式 overwrite 的对象放行。

#### 4.2.3 管理员二次审批

官方 Application Commands 文档说明，命令权限可以对最多 100 个 user / role / channel 做 allow/deny，并且：

- 只能用 Bearer token 更新
- 需要具备足够权限的真实用户来授权
- 客户端里也有 Server Settings > Integrations > Manage 的可视化入口

这就是第二层审批：不仅 bot 被装进服务器了，具体命令还能再按 role/user/channel 缩小。

#### 4.2.4 运行时权限检查

真正执行时，还要过 bitfield 和 overwrite 计算。

`GuildChannel.permissionsFor(memberOrRole)` 的实现逻辑是：

1. 先求 guild 级 base permissions
2. 如果 owner 或 `Administrator`，直接得到全部权限
3. 再按顺序应用 overwrite：
   - `@everyone`
   - 角色 overwrite
   - 成员 overwrite

这和官方权限文档给出的计算顺序一致。

`PermissionsBitField.has()` / `any()` 也把 `Administrator` 作为特殊短路条件处理。这就是高风险权限的“超级开关”。

#### 4.2.5 高风险权限与特殊审批

Discord 还有一层不是 guild/channel overwrite，而是平台级审批：

- `GUILD_MEMBERS`
- `GUILD_PRESENCES`
- `MESSAGE_CONTENT`

这些 privileged intents 必须先在 Developer Portal 启用；已验证的大型应用还需要额外审批。若未配置却在 Identify 时请求，会被 Gateway 以 `4014` 关闭。

这是一种典型的“高风险能力单独审批”设计。

### 4.3 可提炼代码模式

- 事件 envelope：事件对象天然带 `guildId`、`channelId`、`memberPermissions`、`appPermissions`。
- 分层授权：安装授权、命令默认权限、命令覆盖规则、运行时 channel overwrite、平台级 privileged intents。
- 超级权限短路：`Administrator` 不再走普通逐项判断。
- 命令可见性即权限：没权限的命令直接不出现在 picker，而不是执行时报错。
- 权限数据与消息数据同路传输：interaction payload 里直接包含 app/member 权限，避免业务层重复查库。

## 五、针对研究目标的直接回答

### 5.1 插件如何在多个服务器/频道中运行和管理

#### BetterDiscord / Vencord

- 宿主通常只运行一个插件实例。
- 插件通过 Discord 内部 store、消息事件、上下文菜单参数感知当前或目标 guild/channel。
- 状态隔离不是宿主自动完成，而是插件自己按 `guildId/channelId` 建 map。

#### discord.js / Discord API

- 每个网关事件天然带 channel/guild scope。
- channel、guild、thread 是一等模型，消息路由由 framework 根据 payload id 完成。
- 多通道不是“切换上下文”，而是“每个事件自带上下文”。

### 5.2 频道/服务器间的状态隔离

最成熟的做法是：

- 不维护全局“当前通道状态”
- 一律按复合 key 维护状态，例如 `guildId:channelId:threadId`
- 队列、checkpoint、session、rate limit、dedupe 都按 scope 分桶

这与当前 `openclaw-bot-chat` 已有实现很接近。你的插件已经：

- 用 `dialog_id -> session_id` 做会话映射
- 用 `dialogQueues` 做每个 dialog 的串行处理
- 用 `CheckpointStore` 做每个 dialog 的恢复点

这本质上已经是在做 per-scope 隔离，只是 scope 现在是 `dialog_id`，不是 Discord 的 `guildId/channelId/threadId` 三元组。

### 5.3 消息路由到不同通道的机制

推荐按下面层次路由：

1. 传输层带上明确 scope id
2. 先 resolve 目标 scope
3. 再进入该 scope 对应的队列或状态桶
4. 最后在业务层执行回复、补偿、checkpoint 更新

discord.js 的 `MessageCreateAction` 就是典型示例：先 resolve channel，再把消息挂进 channel message manager，最后发事件。

## 六、可借鉴的设计模式

下面这些模式适合直接借给 `openclaw-bot-chat`。

### 6.1 用“上下文对象”代替散落参数

建议所有入站消息先变成统一 envelope：

```ts
interface ExecutionContext {
  installationId: string;
  guildId?: string;
  channelId: string;
  threadId?: string;
  actorId: string;
  actorType: "user" | "bot" | "admin";
  appPermissions: bigint;
  actorPermissions: bigint;
  riskLevel: "low" | "medium" | "high";
}
```

这就是把 discord.js `BaseInteraction` 的思路移植过来。

### 6.2 状态一律按 scope key 分桶

不要只存一个全局 session / checkpoint。建议统一形成：

- `scopeKey -> session`
- `scopeKey -> checkpoint`
- `scopeKey -> dedupe cache`
- `scopeKey -> in-flight queue`

如果后续要支持多服务器/多频道，`scopeKey` 至少要包含：

- 平台或安装实例
- guild 或 server
- channel
- thread

### 6.3 权限做成“三段式”

不要只做一次布尔判断，建议拆成三层：

1. capability declaration
2. admin approval
3. runtime object check

例如：

- 声明层：插件声明自己可能用到 `read_messages`、`send_messages`、`manage_channels`、`execute_agent_tool`
- 审批层：管理员按 workspace/channel 批准这些能力
- 运行层：每次执行前再检查当前 scope 是否允许

这相当于把 Discord 的：

- OAuth2 安装授权
- command permissions
- channel overwrite

压缩成适合你自己系统的三层模型。

### 6.4 高风险能力单独审批

建议把这些能力列为高风险：

- 读跨频道历史消息
- 跨频道发消息
- 管理频道或成员
- 调用本地 shell 或文件系统
- 访问外部网络
- 代表用户执行 destructive action

高风险能力应额外要求：

- 默认关闭
- 独立审批
- 审批留痕
- 运行时二次确认或 policy check

这对应 Discord 的 privileged intents 思路。

### 6.5 “看不见命令”优于“执行时报错”

Discord 命令模型有一个很好的产品设计：没有权限的命令直接不出现。

可借鉴做法：

- 在 UI 或命令列表阶段就过滤未授权动作
- 不要把所有命令都展示出来再在执行时拒绝

这样用户体验和安全性都更好。

### 6.6 审批对象要能落到 channel 级

如果审批只做到“整个机器人能不能做 X”，很快就不够用。至少要支持：

- 全局默认策略
- workspace 或 server 级覆盖
- channel 级覆盖
- 可选的 user 或 role 级覆盖

这是 Discord command permissions 最值得借鉴的粒度。

## 七、对当前 `openclaw-bot-chat` 的具体建议

结合你当前源码，我建议：

1. 保留现有 `dialogQueues`、`SessionManager`、`CheckpointStore` 的 per-dialog 模式。
2. 如果未来接入 Discord 风格多通道，把 `dialog_id` 升级成结构化 scope，而不是继续塞纯字符串。
3. 新增插件自己的 capability manifest，不要依赖宿主“天然信任插件”。
4. capability approval 存储建议做成：
   - `installation -> defaults`
   - `workspace/server -> overrides`
   - `channel -> overrides`
5. 每次执行 agent 或 tool 前，把当前消息先归一化为 `ExecutionContext`，统一做权限检查。
6. 对“跨频道读写”、“外部网络”、“本地执行”做 privileged capability，默认关闭。

## 八、关键代码模式索引

### BetterDiscord

- 插件结构与 `start()` / `stop()` / `onSwitch()`：BetterDiscord Plugin Structure
- store 名单：`src/betterdiscord/types/discord/modules.d.ts`
- store 获取：`src/betterdiscord/api/webpack.ts` 的 `getStore(name)`

### Vencord

- 插件定义：`src/utils/types.ts` 的 `definePlugin()` / `PluginDef`
- store 暴露：`src/webpack/common/stores.ts`
- 消息钩子：`src/api/MessageEvents.ts`
- 命令上下文：`src/api/Commands/index.ts`
- 上下文菜单：`src/api/ContextMenu.ts`

### discord.js

- 消息按 `channel_id` 路由：`packages/discord.js/src/client/actions/MessageCreate.js`
- interaction 上下文对象：`packages/discord.js/src/structures/BaseInteraction.js`
- channel 权限计算：`packages/discord.js/src/structures/GuildChannel.js`
- permission bitfield：`packages/discord.js/src/util/PermissionsBitField.js`
- 命令默认权限与 contexts：`packages/discord.js/src/structures/ApplicationCommand.js`
- 命令审批管理：`packages/discord.js/src/managers/ApplicationCommandPermissionsManager.js`

## 九、最终判断

如果研究目标是“给自己的插件设计多通道和权限审批”，那么优先级应该是：

1. Discord API / discord.js
2. Vencord
3. BetterDiscord

原因很简单：

- BetterDiscord / Vencord 更擅长“如何挂在 Discord 客户端内部拿上下文”
- Discord API / discord.js 才真正解决了“多租户、多频道、分层权限、管理员审批、高风险能力治理”

所以真正可复用的架构答案，大部分在 discord.js 和官方 API，不在客户端改造插件本身。

## 参考来源

### BetterDiscord

- https://docs.betterdiscord.app/plugins/introduction/structure
- https://docs.betterdiscord.app/api/webpack
- https://docs.betterdiscord.app/api/types/CommonlyUsedStores
- https://docs.betterdiscord.app/plugins/introduction/guidelines.html
- https://raw.githubusercontent.com/BetterDiscord/BetterDiscord/main/src/betterdiscord/types/discord/modules.d.ts
- https://raw.githubusercontent.com/BetterDiscord/BetterDiscord/main/src/betterdiscord/api/webpack.ts

### Vencord

- https://docs.vencord.dev/plugins/
- https://raw.githubusercontent.com/Vendicated/Vencord/main/src/utils/types.ts
- https://raw.githubusercontent.com/Vendicated/Vencord/main/src/webpack/common/stores.ts
- https://raw.githubusercontent.com/Vendicated/Vencord/main/src/api/MessageEvents.ts
- https://raw.githubusercontent.com/Vendicated/Vencord/main/src/api/Commands/index.ts
- https://raw.githubusercontent.com/Vendicated/Vencord/main/src/api/ContextMenu.ts

### discord.js / Discord API

- https://raw.githubusercontent.com/discordjs/discord.js/main/packages/discord.js/src/client/actions/MessageCreate.js
- https://raw.githubusercontent.com/discordjs/discord.js/main/packages/discord.js/src/structures/BaseInteraction.js
- https://raw.githubusercontent.com/discordjs/discord.js/main/packages/discord.js/src/structures/GuildChannel.js
- https://raw.githubusercontent.com/discordjs/discord.js/main/packages/discord.js/src/util/PermissionsBitField.js
- https://raw.githubusercontent.com/discordjs/discord.js/main/packages/discord.js/src/structures/ApplicationCommand.js
- https://raw.githubusercontent.com/discordjs/discord.js/main/packages/discord.js/src/managers/ApplicationCommandPermissionsManager.js
- https://docs.discord.com/developers/platform/oauth2-and-permissions
- https://docs.discord.com/developers/topics/permissions
- https://docs.discord.com/developers/interactions/application-commands
- https://docs.discord.com/developers/events/gateway
