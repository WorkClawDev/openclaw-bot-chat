# 个人工作助手实施进度

工作区：`/Users/changerding/.codex/worktrees/personal-agent/openclaw-bot-chat`。分支：`codex/personal-agent`。基线：`5328044`。原工作区仅作只读对照。

| 批次 | 状态 | 内容与证据 |
| --- | --- | --- |
| A | 自动测试通过 | 启动路径统一到 test；Node 22 预检；实例锁及限定 stop；配置输出脱敏；doctor；独立 npm test 和 CI。移除已跟踪具名配置，历史可能保留凭据；真实密钥轮换尚未执行。 |
| B | 自动测试通过 | 工具策略、路径安全、审批、隔离、取消 |
| C | 自动测试通过 | 持久上下文、inbox/outbox、分页、恢复 |
| D | 自动测试通过 | 持续执行、run 租约、输入和审核 |
| E | 自动测试通过 | 附件和可下载成果 |
| F | 自动测试通过 | 记忆和计划任务 |
| G | 自动测试和两端 UI 通过 | 事件和 Web/iOS 体验 |
| H | 自动测试与两端 UI 通过，真实运行验收待执行 | 专用镜像/Compose/秘密引用、MQTT身份、诊断/用量、核对恢复、备份迁移/评测/72h工具 |

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

Agent full suite: 24 tests passed before the added table case; the 4 parser cases passed; the added table test initially used a noncanonical macOS temporary path and failed the intended path policy. The fixture was corrected to its real path in F and retested (25 total cases). Go full suite passed including ownership/version and format refusal; frontend production build and iOS simulator build passed. npm audit reports zero vulnerabilities after patch upgrades and uuid override. Tests use real format bytes and deterministic HTTP/SQLite; live object-store uploads, provider CORS and cross-device downloads remain unverified. Storage writes can leave unreferenced objects after a database rollback; operational cleanup is covered in H.

## Batch F

Structured confirmed memories now have owner/bot/scope/source records, explicit command or UI saves, edit/delete/export, and persistent revision namespaces. Deletes remove derived contexts; revision changes prevent running workers from making old context retrievable again. Memory remains user reference data, with no vector database or implicit model confirmation. Schedules support once/daily/weekly, IANA timezone, local-time validation including DST gaps, pause/resume/cancel, missed-once or skip, and unique durable occurrences. A backend scheduler creates the existing assigned Task and TaskEvent in the same occurrence transaction; multiple restarts or schedulers cannot duplicate it. Results keep the Task review lifecycle. Both clients manage memory and schedules and show the latest task failure in-app; native push/email notifications are not implemented.

Agent full suite: 26 passed, including durable provider commands and deletion. Go full suite passed plus confirmed-only/ownership/reopen/context invalidation, missed-once dedup, pause, skip, and 23-hour DST day behavior. Frontend production and iOS simulator builds passed. The E workbook fixture now uses canonical macOS temporary paths and passes. Live scheduler on PostgreSQL, real worker scheduled completion, native-device notifications and model recall remain pending acceptance.

## Batch G

Model SSE consumption preserves split UTF-8 and complete tool arguments, persists actual assistant text, refuses truncated streams, bounds response size and obeys cancellation. Ordered run events drive step cards and current text. Backend event notices use a persisted outbox and QoS 1; only acknowledged notices are marked delivered, with replay-safe seq on Web/iOS and authenticated paged history fallback. Both clients show questions, approval arguments/expiry, budgets, errors, stop/resume, artifacts and Task review routes. Task resume now synchronizes the business Task to claimed; success notes no longer appear as errors. SwiftUI row buttons use explicit borderless style so one action cannot trigger another button in the same row.

Agent: 29 cases passed. Go full suite passed, including event-notice restart/ack. Actual Chrome UI: 2/2 passed, covering approval, input, event dedup, downloaded real fixture bytes, memory management and schedule pause/resume/cancel. Actual iPhone 17 Pro simulator (iOS 26.4), dedicated PersonalAgent-Acceptance: 1/1 UI test passed after independent fixture-port separation and button-style repair. Screenshot attachments were exported from the successful xcresult and visually inspected. Screenshots and results live under /private/tmp/personal-agent-* and are ignored, not committed. Frontend production build passed. These are actual client interactions against deterministic HTTP fixtures, not live model/EMQX/PostgreSQL/device acceptance; real broker event delivery and latency remain unverified.


## Batch H

Implemented dedicated Node24 and non-root Go images, scoped Compose project/loopback ports, read-only worker/backend roots, minimum volumes/environment/capabilities, mounted secrets, real readiness and owner diagnostics. MQTT bootstrap now mints random owner/bot/client-bound credentials, Redis hash-only session records, fail-closed HTTP authentication/authorization, current identity/key/conversation checks, 60–300s expiry and client renewal. Personal execution additionally binds transport topic and owner DM, rejecting group/non-owner spoofing before custody. Revoked existing read subscriptions disconnect at expiry (maximum5min), not instant kick.

Crashed cancelled leases finalize and fence correctly; business Task cancellation is durable and denies new fenced tools before heartbeat, terminal reviewed results cannot be cancelled through the run API, and bot memory writes use the run fence. Failed Task resume remains synchronized. Non-idempotent uncertainty has both-client evidence reconciliation before a verified result or explicitly verified retry, with owner/run-state checks and audit events. MCP uses real bounded stdio lifecycle, partial-service degradation, per-tool paths/capabilities, reconnect, cancellation closure and shutdown cleanup; exec MCP is disabled. Workspace identity is persisted in runs, derived contexts include workspace, and different-workspace workers refuse custody instead of silently migrating execution. Private file bytes traverse authenticated backend using internal S3 signing, with hash verification. Model SSE usage/first-delta/duration are persisted only when observed; clients state unknown usage otherwise. Worker heartbeat reflects actual MQTT connection.

Security audit required Next.js15.5.27 and PostCSS8.5.28; production frontend and agent npm audit show0 vulnerabilities. Six high development dependency advisories (Tailwind3/braces graph) remain in development scope (braces advisory unresolved by compatible Tailwind3; production image prunes dev dependencies). Chrome on upgraded Next.js:3/3 UI passed. Dedicated iPhone17Pro/iOS26.4 Simulator:2/2 UI passed; final generic simulator build passed. Agent ci:34/34 passed, including actual SDK stdio child/MCP recovery and private-byte/usage cases. Go full suite passed, including broker binding/expiry/revocation/fail-closed/wildcard, crashed cancellation, owner diagnostics, reconciliation and internal/public S3 signing. Extension:57/57 passed. Deterministic40-scenario runner:40 passed,0failed,0not_run; real-service40not_run. UI remains real client execution against HTTP fixtures, not real model/broker/PostgreSQL/objectstore.

Compose config --quiet and shell/Node syntax validation passed; Docker daemon info returnedHTTP500, so actual image builds/startup, PostgreSQL migration replay and backup/restore remain unverified. Provided scoped backup/new-DB restore/migration scripts,40Chinese live scenarios with evidence recording, and72h collector/analyzer which currently reports0samples/not_run. No paid model/key use, user/production service changes, remote push/PR/release or credential rotation occurred. See PERSONAL_AGENT_OPERATIONS.md for commands and acceptance boundaries.

## Local batch commits

A39652be; B95eea6f; Ca431c77; D90d83d4; E8d6a255; F9cef00e; G56d2946. H commit is the commit containing this entry (identify with git log); no remote push. Original uncommitted edits remain outside this worktree.

## Compatibility follow-up after H

Final cross-runtime inspection found the legacy OpenClaw extension reusing the initial MQTT password indefinitely. It now refreshes scoped bootstrap credentials before expiry, validates the same bot and a fresh identity/expiry, reconnects with updated CONNECT credentials, replaces subscription scopes, and disables MQTT automatic stale resubscriptions. Stop clears the timer and aborts in-flight bootstrap; bootstrap requests have a25-second deadline. CI now runs extension type-check and build as well as tests. Extension check/build passed;58/58 tests passed, including actual local TCP MQTT CONNECT/SUBSCRIBE packets and aborting a pending HTTP renewal on stop (30-second behavior test). This is real MQTT wire behavior against a test server, not EMQX callback/revocation acceptance.
