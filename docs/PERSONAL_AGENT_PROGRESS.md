# 个人工作助手实施进度

工作区：`/Users/changerding/.codex/worktrees/personal-agent/openclaw-bot-chat`。分支：`codex/personal-agent`。基线：`5328044`。原工作区仅作只读对照。

| 批次 | 状态 | 内容与证据 |
| --- | --- | --- |
| A | 自动测试通过 | 启动路径统一到 test；Node 22 预检；实例锁及限定 stop；配置输出脱敏；doctor；独立 npm test 和 CI。移除已跟踪具名配置，历史可能保留凭据；真实密钥轮换尚未执行。 |
| B | 未开始 | 工具策略、路径安全、审批、隔离、取消 |
| C | 未开始 | 持久上下文、inbox/outbox、分页、恢复 |
| D | 未开始 | 持续执行、run 租约、输入和审核 |
| E | 未开始 | 附件和可下载成果 |
| F | 未开始 | 记忆和计划任务 |
| G | 未开始 | 事件和 Web/iOS 体验 |
| H | 未开始 | 运行保障、评测及真实验收 |

真实模型、MCP、broker、设备与 72 小时验收尚未执行。不得把确定性测试替身报告为真实服务验收。

## 批次 A 验证

独立 worktree `npm ci` 成功，Node 24.4.0；`npm run check`、`npm test`（4 项默认 CJS/HTTP/持久状态/doctor 行为测试）通过；扩展 `npm ci && npm test`（57 项）通过；`bash -n` 和 `git diff --check` 通过。未启动用户服务，未使用真实密钥。当前提交包含任务书和实施计划。

基线不存在原工作区新增 broker ACL 实现；后续不能依赖该未提交能力。下一批 B：默认拒绝、真实路径、安全 runner、统一工具执行和取消。

## Batch B

Implemented shared schema and capabilities, deny-by-default roots, symlink and hidden path refusal, O_NOFOLLOW, bounded asynchronous processes and Docker-only shell. MCP needs explicit per-tool policy and receives minimal environment. JWT owner decisions persist in agent_approvals, scoped to run/tool/parameter hash with expiry. Web /assistant supports approve and deny.

Agent ci: 9 tests passed. Go full suite passed, including approval ownership, changed parameters and expiry. Frontend clean install and build passed. Docker daemon unavailable: actual container isolation remains unverified; shell stays disabled. Auto-resume after approval continues in batch C.
