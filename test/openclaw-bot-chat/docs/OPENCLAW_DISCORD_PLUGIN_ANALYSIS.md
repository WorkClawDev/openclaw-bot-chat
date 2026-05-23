# OpenClaw Discord 插件架构分析

更新时间：2026-04-10

## 1. 多通道（Multi-Account）实现

OpenClaw Discord 插件支持配置多个 Discord 账号，实现多通道隔离。

### 1.1 账号配置结构

```typescript
// DiscordConfig
{
  accounts?: Record<string, DiscordAccountConfig>;  // 多账号配置
  defaultAccount?: string;                          // 默认账号
}

// DiscordAccountConfig 关键字段
{
  name?: string;              // 账号显示名
  token?: SecretInput;        // Bot Token
  enabled?: boolean;          // 是否启用
  capabilities?: string[];     // 能力标签
}
```

### 1.2 账号解析函数

```typescript
// 列出所有账号 ID
listDiscordAccountIds(cfg: OpenClawConfig): string[]

// 获取默认账号
resolveDefaultDiscordAccountId(cfg: OpenClawConfig): string

// 解析账号配置
resolveDiscordAccount(params: {
  cfg: OpenClawConfig;
  accountId?: string | null;
}): ResolvedDiscordAccount

// 列出所有启用的账号
listEnabledDiscordAccounts(cfg: OpenClawConfig): ResolvedDiscordAccount[]
```

### 1.3 多账号隔离机制

- 每个账号有独立的 token、配置、状态
- 通过 `accountId` 隔离不同账号的消息和动作
- 支持按账号启用/禁用

## 2. 权限审批（Permission Approval）模型

### 2.1 动作门控（Action Gate）

```typescript
// 创建动作门控函数
createDiscordActionGate(params: {
  cfg: OpenClawConfig;
  accountId?: string | null;
}): (key: keyof DiscordActionConfig, defaultValue?: boolean) => boolean
```

### 2.2 动作配置（DiscordActionConfig）

```typescript
{
  reactions?: boolean;        // 反应
  stickers?: boolean;         // 贴纸
  polls?: boolean;           // 投票
  permissions?: boolean;      // 权限查询
  messages?: boolean;        // 消息
  threads?: boolean;         // 线程
  pins?: boolean;            // 固定
  search?: boolean;          // 搜索
  memberInfo?: boolean;      // 成员信息
  roleInfo?: boolean;        // 角色信息
  roles?: boolean;           // 角色管理
  channelInfo?: boolean;     // 频道信息
  voiceStatus?: boolean;     // 语音状态
  events?: boolean;          // 事件
  moderation?: boolean;       // 审核
  emojiUploads?: boolean;    // 表情上传
  stickerUploads?: boolean;   // 贴纸上传
  channels?: boolean;        // 频道管理
  presence?: boolean;        // 在线状态
}
```

### 2.3 权限检查函数

```typescript
// 获取用户Guild权限
fetchMemberGuildPermissionsDiscord(
  guildId: string,
  userId: string,
  opts?: DiscordReactOpts
): Promise<bigint | null>

// 检查是否有任意权限
hasAnyGuildPermissionDiscord(
  guildId: string,
  userId: string,
  requiredPermissions: bigint[],
  opts?: DiscordReactOpts
): Promise<boolean>

// 检查是否拥有所有权限
hasAllGuildPermissionsDiscord(
  guildId: string,
  userId: string,
  requiredPermissions: bigint[],
  opts?: DiscordReactOpts
): Promise<boolean>

// 获取频道权限
fetchChannelPermissionsDiscord(
  channelId: string,
  opts?: DiscordReactOpts
): Promise<DiscordPermissionsSummary>
```

### 2.4 DM 策略（DmPolicy）

```typescript
// DM 访问策略
{
  enabled?: boolean;           // 是否启用 DM
  policy?: DmPolicy;           // 策略类型
  allowFrom?: string[];        // 允许列表（ID 或名称）
  groupEnabled?: boolean;      // 是否允许群组 DM
  groupChannels?: string[];    // 群组 DM 频道白名单
}
```

## 3. 频道/Guild 隔离

### 3.1 Guild 配置

```typescript
// 按 Guild（服务器）配置
guilds?: Record<string, DiscordGuildEntry>

// DiscordGuildEntry
{
  slug?: string;                    // Guild 别名
  requireMention?: boolean;          // 是否需要 @bot
  ignoreOtherMentions?: boolean;     // 忽略其他提及
  tools?: GroupToolPolicyConfig;     // 工具策略
  toolsBySender?: ...;              // 按发送者配置工具
  reactionNotifications?: 'off'|'own'|'all'|'allowlist';
  users?: string[];                 // 用户白名单
  roles?: string[];                 // 角色白名单
  channels?: Record<string, DiscordGuildChannelConfig>;  // 频道配置
}
```

### 3.2 频道配置

```typescript
DiscordGuildChannelConfig {
  allow?: boolean;                  // 是否允许
  requireMention?: boolean;          // 是否需要提及
  ignoreOtherMentions?: boolean;    // 忽略其他提及
  tools?: GroupToolPolicyConfig;     // 工具策略覆盖
  skills?: string[];                // 技能白名单
  enabled?: boolean;                // 是否启用
  users?: string[];                 // 用户白名单
  roles?: string[];                 // 角色白名单
  systemPrompt?: string;            // 系统提示
  autoThread?: boolean;             // 自动创建线程
}
```

## 4. 执行审批（Exec Approval）

```typescript
DiscordExecApprovalConfig {
  enabled?: boolean;                // 启用审批转发
  approvers?: string[];             // 审批者用户 ID
  agentFilter?: string[];            // 限定的 Agent ID
  sessionFilter?: string[];          // 限定的 Session 模式
  cleanupAfterResolve?: boolean;     // 审批后清理
  target?: 'dm' | 'channel' | 'both';  // 审批发送目标
}
```

## 5. 关键设计模式

### 5.1 配置继承链
```
DiscordConfig (base)
  → DiscordAccountConfig (per-account)
    → DiscordGuildEntry (per-guild)
      → DiscordGuildChannelConfig (per-channel)
```

### 5.2 权限检查时机
1. **入站时**：检查用户/角色是否在白名单
2. **动作时**：检查 `DiscordActionConfig` 是否启用
3. **出站时**：检查 Bot 是否有权限发送

### 5.3 白名单匹配模式
- **ID 匹配**（默认）：精确匹配用户/角色 ID
- **名称匹配**（dangerouslyAllowNameMatching）：支持用户名/别名

## 6. 可借鉴设计

### 6.1 多 Bot/通道隔离
```typescript
// 我们的插件可以这样设计
{
  bots: {
    bot1: { accessKey: 'xxx', enabled: true },
    bot2: { accessKey: 'yyy', enabled: false }
  },
  defaultBot: 'bot1'
}
```

### 6.2 动作权限门控
```typescript
// 按动作类型开关
const actions = {
  sendMessage: true,
  sendImage: false,
  typing: true
}
```

### 6.3 白名单机制
```typescript
// 用户/频道白名单
{
  allowFrom: ['user1', 'user2'],
  channels: ['channel1', 'channel2']
}
```

## 7. 文件位置

OpenClaw Discord 插件源码：
```
/home/admin/.npm-global/lib/node_modules/openclaw/dist/plugin-sdk/extensions/discord/
```

关键文件：
- `src/accounts.d.ts` - 账号解析
- `src/send.permissions.d.ts` - 权限检查
- `src/targets.d.ts` - 目标解析
- `src/runtime-api.d.ts` - 运行时 API
