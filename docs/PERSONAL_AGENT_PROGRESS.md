# 个人工作助手实施进度

工作区：`/Users/changerding/.codex/worktrees/personal-agent/openclaw-bot-chat`。分支：`codex/personal-agent`。基线：`5328044`。原工作区仅作只读对照。

| 批次 | 状态 | 内容与证据 |
| --- | --- | --- |
| A | 自动测试通过 | 启动路径统一到 test；Node 22 预检；实例锁及限定 stop；配置输出脱敏；doctor；独立 npm test 和 CI。移除已跟踪具名配置，历史可能保留凭据；真实密钥轮换尚未执行。 |
| B | 自动测试通过 | 工具策略、路径安全、审批、隔离、取消 |
| C | 自动测试通过 | 持久上下文、inbox/outbox、分页、恢复 |
| D | 自动测试通过 | 持续执行、run 租约、输入和审核 |
| E | 自动测试通过 | 附件和可下载成果 |
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

## Batch C

PostgreSQL now owns durable inbox/outbox, context and tool intent/results. Worker no longer merges remote newest sequence into processed checkpoints. Explicit after_seq=0 retrieves oldest pending messages, pagination advances through all batches. Reply IDs are stable, persisted responses are republished without calling the model. Default CJS stores conversation/memory and exact tool transcript through authenticated backend callbacks, resumes after approval, and refuses uncertain non-idempotent side effects. Compression preserves tool pairs and treats historical/file/memory material as user reference data. Global worker gate limits concurrent work and bounded queues; shutdown aborts and drains.

Agent ci: 17 tests passed, including 501-message paging, 100 duplicate deliveries, saved-outbox publish failure, handler restart with memory and approval, tool uncertainty, context grouping, and queue bounds. Go full suite passed, including duplicate durable records and bot-isolated context. Test fixtures are deterministic local HTTP and SQLite, not live MQTT/PostgreSQL/model acceptance. Two worker execution fencing follows in D; until that is complete only one worker may run per bot.

## Batch D

AgentRun now owns task/chat execution via the same worker executor. Claims use a database row lock, expiring lease and monotonic fencing; journal writes lock the same run before mutation. Heartbeats stop cancelled or stale workers. Tool/model events count real steps against the persisted budget, finite slices save and continue, budget exhaustion pauses, questions/approval release the lease, and authenticated users supply input or cancel. Existing Task APIs reject unfenced writes once managed by a run. Task results and inbox/outbox receipts commit atomically with run completion; task success enters awaiting_review and only user acceptance completes it. Web /assistant and iOS Settings > Personal assistant expose states, questions, approval details, stop and resume.

Agent ci: 20 tests passed; Go full suite passed, including concurrent claim winner, replacement fencing, waiting lease release, cancellation preventing new tools, ordered events and actual Task acceptance. Frontend production build passed. iOS generic simulator build passed (independent DerivedData, no signing); live simulator is available after normal permission escalation, real UI acceptance follows in G. Deterministic HTTP/SQLite tests do not establish live EMQX/PostgreSQL/model/72h acceptance.

## Batch E

Private file assets support TXT, Markdown, CSV, text PDF, DOCX and XLSX up to 8 MiB. Backend verifies signatures, UTF-8 and stored SHA256; owner-scoped downloads never accept arbitrary external file URLs. Parsing runs in a bounded worker with empty environment, 15-second termination, archive size/ratio/entry caps, PDF page/text caps and explicit OCR-required errors. This worker is a resource boundary, not an OS sandbox; production parser containment remains a live acceptance requirement. Tables produce actual CSV/XLSX files; delivery uploads real bytes to the existing asset store, records run/task/hash/version, and creates Documents for text output. Asset, Document and artifact journal mutations share the fenced transaction. Web and iOS send attachments, show errors and retrieve persisted artifacts; docs open through existing Document views.

Agent full suite: 24 tests passed before the added table case; all 5 E parser/table tests passed separately (25 total cases). Go full suite passed including ownership/version and format refusal; frontend production build and iOS simulator build passed. npm audit reports zero vulnerabilities after patch upgrades and uuid override. Tests use real format bytes and deterministic HTTP/SQLite; live object-store uploads, provider CORS and cross-device downloads remain unverified. Storage writes can leave unreferenced objects after a database rollback; operational cleanup is covered in H.
