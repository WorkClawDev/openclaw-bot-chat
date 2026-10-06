import SwiftUI

private struct AssistantRun: Codable, Identifiable {
 let id: String
 let task_id: String?
 let status: String
 let cancel_requested: Bool
 let steps: Int
 let max_steps: Int
 let error: String?
 let result: AssistantResult?
}
private struct AssistantEvent:Codable,Identifiable {let id:String;let seq:Int64;let type:String;let data:[String:AnyCodable]}
private struct AssistantArtifact:Codable,Identifiable {let id:String;let file_name:String;let version:Int;let document_id:String?}
private struct AssistantResult: Codable { let content: String? }
private struct AssistantApproval: Codable, Identifiable {
 let id: String
 let run_id: String
 let tool: String
 let status: String
 let arguments: [String:AnyCodable]?
 let parameter_hash: String
 let expires_at: Date
}
private struct UncertainAssistantTool:Codable,Identifiable {let id:String;let run_id:String;let tool:String}
private struct AssistantActionResult: Codable { let status: String }
struct AssistantView: View {
 @Environment(\.openURL) private var openURL
 @State private var events:[String:[AssistantEvent]]=[:]
 @State private var artifacts:[String:[AssistantArtifact]]=[:]
 @State private var runs: [AssistantRun] = []
 @State private var approvals: [AssistantApproval] = []
 @State private var inputs: [String:String] = [:]
 @State private var error: String?
 @State private var uncertain:[UncertainAssistantTool]=[]
 @State private var evidence:[String:String]=[:]
 @State private var isReloading=false
 @AppStorage(AppLanguageMode.storageKey) private var languageModeRawValue = AppLanguageMode.english.rawValue

 var body: some View {
    let _ = languageModeRawValue
    List {
        if let error {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("assistant.error")
        }
        NavigationLink(L10n.t("记忆与计划", "Memory and schedules")) { AssistantManagementView() }
            .accessibilityIdentifier("assistant.management")
        if !uncertain.isEmpty {
            Section(L10n.t("需要核对", "Needs verification")) {
                ForEach(uncertain) { call in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.t("需要核对：", "Verify: ") + call.tool).font(.headline)
                        Text(L10n.t("先查询外部服务的实际结果，再记录证据；核对后恢复工作。", "Check the result with the external service, record the evidence, then resume."))
                            .font(.subheadline).foregroundStyle(Color.rcmsTextSecondary)
                        TextField(L10n.t("核对证据", "Verification evidence"), text: Binding(get: { evidence[call.id] ?? "" }, set: { evidence[call.id] = $0 }))
                        Button(L10n.t("确认已执行并记录结果", "Confirm completed and record result")) { Task { await reconcile(call.id, "completed") } }
                            .disabled((evidence[call.id] ?? "").count < 3)
                        Button(L10n.t("确认未执行，允许重试", "Confirm not applied and allow retry")) { Task { await reconcile(call.id, "not_applied") } }
                            .disabled((evidence[call.id] ?? "").count < 3)
                    }.padding(.vertical, 8)
                }
            }
        }
        Section(L10n.t("工作记录", "Work")) {
            if runs.isEmpty {
                Text(L10n.t("暂无工作", "No work yet")).foregroundStyle(Color.rcmsTextSecondary)
            }
            ForEach(runs) { run in runRow(run) }
        }
        if !approvals.isEmpty {
            Section(L10n.t("操作授权", "Approvals")) {
                ForEach(approvals) { approval in approvalRow(approval) }
            }
        }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.rcmsBackground)
    .tint(Color.rcmsAccent)
    .buttonStyle(.borderless)
    .navigationTitle(L10n.t("执行与授权", "Activity and approvals"))
    .navigationBarTitleDisplayMode(.inline)
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("agentUpdate"))) { _ in Task { await reload() } }
    .refreshable { await reload() }
    .task {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(5))
        }
    }
 }

 private func runRow(_ run: AssistantRun) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(run.task_id == nil ? L10n.t("会话工作", "Conversation work") : L10n.t("派发任务", "Assigned task"))
            .font(.headline)
        Text("\(run.cancel_requested ? L10n.t("正在停止", "Stopping") : statusLabel(run.status)) · \(run.steps)/\(run.max_steps) " + L10n.t("步", "steps"))
            .font(.subheadline).foregroundStyle(Color.rcmsTextSecondary)
        if run.status == "running", let delta = events[run.id]?.last(where: { $0.type == "assistant_delta" })?.data["text"]?.value as? String {
            Text(delta).textSelection(.enabled).accessibilityIdentifier("assistant.stream")
        }
        if let message = run.error, !message.isEmpty { Text(message).foregroundStyle(.red) }
        if let result = run.result?.content { Text(result).textSelection(.enabled) }
        ForEach(artifacts[run.id] ?? []) { file in
            Button(L10n.t("下载 ", "Download ") + file.file_name + " · " + L10n.t("版本 ", "Version ") + String(file.version)) {
                Task { await download(file.id) }
            }
            if let raw = file.document_id, let document = UUID(uuidString: raw) {
                NavigationLink(L10n.t("查看文档", "View document")) { DocumentDetailView(documentID: document) }
            }
        }
        if ["waiting_input", "paused", "failed"].contains(run.status) {
            TextField(L10n.t("补充信息", "Additional information"), text: Binding(get: { inputs[run.id] ?? "" }, set: { inputs[run.id] = $0 }))
            Button(L10n.t("保存并继续", "Save and continue")) { Task { await action(run.id, "resume") } }
                .disabled(run.status == "waiting_input" && (inputs[run.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("assistant.resume")
        }
        if ["queued", "running", "waiting_input", "waiting_approval", "paused"].contains(run.status) {
            Button(L10n.t("停止", "Stop"), role: .destructive) { Task { await action(run.id, "cancel") } }
        }
        DisclosureGroup(L10n.t("执行步骤与用量", "Steps and usage")) {
            Text(usageLabel(run.id)).font(.caption).foregroundStyle(Color.rcmsTextSecondary)
            ForEach((events[run.id] ?? []).filter { $0.type != "assistant_delta" }) { event in
                Text("#\(event.seq) · \(event.type)" + ((event.data["tool"]?.value as? String).map { " · " + $0 } ?? ""))
                    .font(.caption).textSelection(.enabled)
            }
        }.font(.subheadline)
    }.padding(.vertical, 8)
 }

 private func approvalRow(_ approval: AssistantApproval) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(operationTitle(approval.tool)).font(.headline)
        Text(approvalStatusLabel(approval.status == "pending" && approval.expires_at <= Date() ? "expired" : approval.status)).font(.subheadline).foregroundStyle(Color.rcmsTextSecondary)
        if let arguments = approval.arguments,
           let data = try? JSONEncoder().encode(arguments),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rcmsSurfaceMuted, in: RoundedRectangle(cornerRadius: 10))
        }
        if approval.status == "pending", approval.expires_at > Date() {
            HStack(spacing: 24) {
                Button(L10n.t("批准本次操作", "Approve this operation")) { Task { await decide(approval.id, true) } }
                Button(L10n.t("拒绝", "Deny"), role: .destructive) { Task { await decide(approval.id, false) } }
            }
        }
        DisclosureGroup(L10n.t("技术详情", "Technical details")) {
            Text(L10n.t("工具：", "Tool: ") + approval.tool)
            Text(L10n.t("任务：", "Run: ") + approval.run_id)
            Text(L10n.t("参数指纹：", "Parameter fingerprint: ") + approval.parameter_hash)
        }.font(.caption).textSelection(.enabled)
    }.padding(.vertical, 8)
 }

 private func usageLabel(_ id: String) -> String {
    let responses = (events[id] ?? []).filter { $0.type == "model_response" }
    let values = responses.compactMap { ($0.data["usage"]?.value as? [String: Any])?["total_tokens"] as? Int }
    guard !values.isEmpty else { return L10n.t("模型用量未知", "Model usage unavailable") }
    return L10n.t("模型已报告 ", "Reported model usage: ") + String(values.reduce(0, +)) + " tokens" + (values.count < responses.count ? L10n.t("，部分用量未知", "; some usage unavailable") : "")
 }

 private func statusLabel(_ status: String) -> String {
    switch status {
    case "queued": return L10n.t("排队中", "Queued")
    case "running": return L10n.t("正在工作", "Working")
    case "waiting_input": return L10n.t("需要补充信息", "More information needed")
    case "waiting_approval": return L10n.t("等待授权", "Waiting for approval")
    case "paused": return L10n.t("已暂停", "Paused")
    case "succeeded": return L10n.t("成果已交付", "Completed")
    case "failed": return L10n.t("执行失败", "Failed")
    case "cancelled": return L10n.t("已停止", "Stopped")
    default: return status
    }
 }

 private func approvalStatusLabel(_ status: String) -> String {
    switch status {
    case "pending": return L10n.t("待确认", "Awaiting confirmation")
    case "approved": return L10n.t("已批准", "Approved")
    case "denied": return L10n.t("已拒绝", "Denied")
    case "expired": return L10n.t("已过期", "Expired")
    default: return status
    }
 }
 private func operationTitle(_ tool: String) -> String {
    switch tool {
    case "local__fs_replace_text": return L10n.t("修改文件内容", "Edit file contents")
    case "local__fs_write": return L10n.t("写入文件", "Write a file")
    default: return tool
    }
 }
 @MainActor private func loadEvents(_ id:String)async throws {
  var cursor=events[id]?.last?.seq ?? 0
  while true { let page:[AssistantEvent]=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(id)/events?after_seq=\(cursor)");if page.isEmpty { break };var unique=Dictionary(uniqueKeysWithValues:(events[id] ?? []).map{($0.seq,$0)});for event in page{unique[event.seq]=event};events[id]=unique.values.sorted{$0.seq<$1.seq};cursor=page.last!.seq;if page.count<200{break} }
 }
 @MainActor private func download(_ id:String) async {
  do { let asset:Asset = try await APIClient.shared.requestValue("/api/v1/agent/artifacts/\(id)/download");if let raw=asset.downloadURL,let url=URL(string:raw) { openURL(url) } } catch { self.error=error.localizedDescription }
 }
 @MainActor private func reload() async {
  guard !isReloading else{return};isReloading=true;defer{isReloading=false}
  if let values:[UncertainAssistantTool]=try? await APIClient.shared.requestValue("/api/v1/agent/tool-calls/uncertain"){uncertain=values}
  do { async let executions: [AssistantRun] = APIClient.shared.requestValue("/api/v1/agent/runs");async let decisions: [AssistantApproval] = APIClient.shared.requestValue("/api/v1/agent/approvals");runs=try await executions;approvals=try await decisions;for run in runs { artifacts[run.id]=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(run.id)/artifacts");try await loadEvents(run.id) };error=nil }
  catch { self.error=error.localizedDescription }
 }
 @MainActor private func action(_ id:String,_ action:String) async {
  do { let body=try JSONSerialization.data(withJSONObject:["input":inputs[id] ?? ""]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(id)/\(action)",method:"POST",body:body);await reload() } catch { self.error=error.localizedDescription }
 }
 @MainActor private func decide(_ id:String,_ approved:Bool) async {
  do { let body=try JSONSerialization.data(withJSONObject:["approved":approved]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/approvals/\(id)/decision",method:"POST",body:body);await reload() } catch { self.error=error.localizedDescription }
 }
 @MainActor private func reconcile(_ id:String,_ outcome:String)async{do{let body=try JSONSerialization.data(withJSONObject:["outcome":outcome,"evidence":evidence[id] ?? ""]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/tool-calls/\(id)/reconcile",method:"POST",body:body);await reload()}catch{self.error=error.localizedDescription}}

}
