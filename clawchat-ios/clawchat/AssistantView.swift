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
 @State private var runs: [AssistantRun] = []
 @State private var approvals: [AssistantApproval] = []
 @State private var inputs: [String:String] = [:]
 @State private var error: String?
 var body: some View {
  List {
   if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("assistant.error") }
   Section("执行中的工作") {
    if runs.isEmpty { Text("暂无工作") }
    ForEach(runs) { run in
     VStack(alignment:.leading,spacing:8) {
      Text(run.task_id == nil ? "会话工作" : "派发任务").font(.headline)
      Text("\(run.cancel_requested ? "正在停止" : run.status) · \(run.steps)/\(run.max_steps) 步")
      if let message = run.error, !message.isEmpty { Text(message) }
      if let result = run.result?.content { Text(result).textSelection(.enabled) }
      if ["queued","running","waiting_input","waiting_approval","paused"].contains(run.status) { Button("停止",role:.destructive) { Task { await action(run.id,"cancel") } } }
      if ["waiting_input","paused","failed"].contains(run.status) {
       TextField("补充信息",text:Binding(get:{inputs[run.id] ?? ""},set:{inputs[run.id]=$0}))
       Button("保存并继续") { Task { await action(run.id,"resume") } }
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
      if approval.status == "pending" {
       HStack { Button("批准本次操作") { Task { await decide(approval.id,true) } }; Button("拒绝",role:.destructive) { Task { await decide(approval.id,false) } } }
      }
     }
    }
   }
  }.navigationTitle("个人助手").refreshable { await reload() }.task { while !Task.isCancelled { await reload();try? await Task.sleep(for:.seconds(5)) } }
 }
 @MainActor private func reload() async {
  do { async let executions: [AssistantRun] = APIClient.shared.requestValue("/api/v1/agent/runs");async let decisions: [AssistantApproval] = APIClient.shared.requestValue("/api/v1/agent/approvals");runs=try await executions;approvals=try await decisions;error=nil }
  catch { self.error=error.localizedDescription }
 }
 @MainActor private func action(_ id:String,_ action:String) async {
  do { let body=try JSONSerialization.data(withJSONObject:["input":inputs[id] ?? ""]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/runs/\(id)/\(action)",method:"POST",body:body);await reload() } catch { self.error=error.localizedDescription }
 }
 @MainActor private func decide(_ id:String,_ approved:Bool) async {
  do { let body=try JSONSerialization.data(withJSONObject:["approved":approved]);let _:AssistantActionResult=try await APIClient.shared.requestValue("/api/v1/agent/approvals/\(id)/decision",method:"POST",body:body);await reload() } catch { self.error=error.localizedDescription }
 }
}
