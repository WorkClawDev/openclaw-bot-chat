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
 let expires_at: String
}
private struct AssistantActionResult: Codable { let status: String }
struct AssistantView: View {
 @Environment(\.openURL) private var openURL
 @State private var events:[String:[AssistantEvent]]=[:]
 @State private var artifacts:[String:[AssistantArtifact]]=[:]
 @State private var runs: [AssistantRun] = []
 @State private var approvals: [AssistantApproval] = []
 @State private var inputs: [String:String] = [:]
 @State private var error: String?
 @State private var isReloading=false
 var body: some View {
  List {
   if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("assistant.error") }
   NavigationLink("记忆与计划") { AssistantManagementView() }
   Section("执行中的工作") {
    if runs.isEmpty { Text("暂无工作") }
    ForEach(runs) { run in
     VStack(alignment:.leading,spacing:8) {
      Text(run.task_id == nil ? "会话工作" : "派发任务").font(.headline)
      Text("\(run.cancel_requested ? "正在停止" : statusLabel(run.status)) · \(run.steps)/\(run.max_steps) 步")
      if run.status == "running",let delta=events[run.id]?.last(where:{$0.type=="assistant_delta"})?.data["text"]?.value as? String { Text(delta).textSelection(.enabled).accessibilityIdentifier("assistant.stream") }
      DisclosureGroup("执行步骤") { ForEach((events[run.id] ?? []).filter{$0.type != "assistant_delta"}) { event in Text("#\(event.seq) · \(event.type)" + ((event.data["tool"]?.value as? String).map{" · "+$0} ?? "")).font(.caption) } }
      ForEach(artifacts[run.id] ?? []) { file in
       Button("下载 \(file.file_name) · 版本 \(file.version)") { Task { await download(file.id) } }
       if let raw=file.document_id,let document=UUID(uuidString:raw) { NavigationLink("查看文档") { DocumentDetailView(documentID:document) } }
      }
      if let message = run.error, !message.isEmpty { Text(message) }
      if let result = run.result?.content { Text(result).textSelection(.enabled) }
      if ["queued","running","waiting_input","waiting_approval","paused"].contains(run.status) { Button("停止",role:.destructive) { Task { await action(run.id,"cancel") } } }
      if ["waiting_input","paused","failed"].contains(run.status) {
       TextField("补充信息",text:Binding(get:{inputs[run.id] ?? ""},set:{inputs[run.id]=$0}))
       Button("保存并继续") { Task { await action(run.id,"resume") } }.disabled(run.status=="waiting_input" && (inputs[run.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("assistant.resume")
      }
     }
    }
   }
   Section("操作授权") {
    ForEach(approvals) { approval in
     VStack(alignment:.leading,spacing:8) {
      Text(approval.tool).font(.headline)
      Text("状态：\(approval.status)")
      Text("任务：\(approval.run_id)").font(.caption)
      if let arguments = approval.arguments, let data = try? JSONEncoder().encode(arguments), let text = String(data:data,encoding:.utf8) { Text(text).font(.caption).textSelection(.enabled) }
      Text("参数指纹：\(approval.parameter_hash)").font(.caption).textSelection(.enabled)
      if approval.status == "pending", (ISO8601DateFormatter().date(from:approval.expires_at) ?? .distantPast) > Date() {
       HStack { Button("批准本次操作") { Task { await decide(approval.id,true) } }; Button("拒绝",role:.destructive) { Task { await decide(approval.id,false) } } }
      }
     }
    }
   }
  }.buttonStyle(.borderless).navigationTitle("个人助手").onReceive(NotificationCenter.default.publisher(for:Notification.Name("agentUpdate"))){_ in Task{await reload()}}.refreshable { await reload() }.task { while !Task.isCancelled { await reload();try? await Task.sleep(for:.seconds(5)) } }
 }
 private func statusLabel(_ status:String)->String { ["queued":"排队中","running":"正在工作","waiting_input":"需要补充信息","waiting_approval":"等待授权","paused":"已暂停","succeeded":"成果已交付","failed":"执行失败","cancelled":"已停止"][status] ?? status }
 @MainActor private func loadEvents(_ id:String)async throws {
  var cursor=events[id]?.last?.seq ?? 0
  while true { let page:[AssistantEvent]=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(id)/events?after_seq=\(cursor)");if page.isEmpty { break };var unique=Dictionary(uniqueKeysWithValues:(events[id] ?? []).map{($0.seq,$0)});for event in page{unique[event.seq]=event};events[id]=unique.values.sorted{$0.seq<$1.seq};cursor=page.last!.seq;if page.count<200{break} }
 }
 @MainActor private func download(_ id:String) async {
  do { let asset:Asset = try await APIClient.shared.requestValue("/api/v1/agent/artifacts/\(id)/download");if let raw=asset.downloadURL,let url=URL(string:raw) { openURL(url) } } catch { self.error=error.localizedDescription }
 }
 @MainActor private func reload() async {
  guard !isReloading else{return};isReloading=true;defer{isReloading=false}
  do { async let executions: [AssistantRun] = APIClient.shared.requestValue("/api/v1/agent/runs");async let decisions: [AssistantApproval] = APIClient.shared.requestValue("/api/v1/agent/approvals");runs=try await executions;approvals=try await decisions;for run in runs { artifacts[run.id]=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(run.id)/artifacts");try await loadEvents(run.id) };error=nil }
  catch { self.error=error.localizedDescription }
 }
 @MainActor private func action(_ id:String,_ action:String) async {
  do { let body=try JSONSerialization.data(withJSONObject:["input":inputs[id] ?? ""]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(id)/\(action)",method:"POST",body:body);await reload() } catch { self.error=error.localizedDescription }
 }
 @MainActor private func decide(_ id:String,_ approved:Bool) async {
  do { let body=try JSONSerialization.data(withJSONObject:["approved":approved]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/approvals/\(id)/decision",method:"POST",body:body);await reload() } catch { self.error=error.localizedDescription }
 }
}
