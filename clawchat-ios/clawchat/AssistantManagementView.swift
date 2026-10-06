import SwiftUI
private struct ConfirmedMemory:Codable,Identifiable {let id:String;let bot_id:String;let scope:String;let content:String;let source:String;let confirmed:Bool}
private struct WorkSchedule:Codable,Identifiable {let id:String;let title:String;let prompt:String;let timezone:String;let recurrence:String;let status:String;let next_at:Date;let last_task_id:String?;let last_task_status:String?;let last_task_note:String?}
private struct ManagementResult:Codable {let status:String}
struct AssistantManagementView:View {
 @State private var bots:[Bot]=[]
 @State private var botID=""
 @State private var memories:[ConfirmedMemory]=[]
 @State private var schedules:[WorkSchedule]=[]
 @State private var memory=""
 @State private var editingID:String?
 @State private var title=""
 @State private var prompt=""
 @State private var date=Date()
 @State private var timezone=TimeZone.current.identifier
 @State private var recurrence="once"
 @State private var missed="once"
 @State private var error:String?
 @State private var exportURL:URL?
 @FocusState private var focusedField: String?
 @AppStorage(AppLanguageMode.storageKey) private var languageModeRawValue = AppLanguageMode.english.rawValue
 var body:some View {
  let _ = languageModeRawValue
  Form {
   if let error { Text(error).foregroundStyle(.red) }
   Picker(L10n.t("助手", "Bot"),selection:$botID){ForEach(bots){bot in Text(bot.name).tag(bot.id.uuidString.lowercased())}}
   Section(L10n.t("已确认记忆", "Confirmed memory")) {
    TextField(L10n.t("记忆内容", "Memory content"),text:$memory,axis:.vertical).focused($focusedField, equals: "memory")
    Button(L10n.t("确认保存记忆", "Confirm and save memory")) { Task { await saveMemory() } }.disabled(botID.isEmpty || memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    Button(L10n.t("导出记忆", "Export memory")) { Task { await exportMemory() } }
    if let exportURL { ShareLink(L10n.t("分享记忆文件", "Share memory file"),item:exportURL) }
    ForEach(memories){row in
     VStack(alignment:.leading,spacing:8){Text(row.content);Text((row.scope == "personal" ? L10n.t("个人", "Personal") : row.scope) + " · " + (row.source == "user_confirmation" ? L10n.t("用户确认", "User confirmed") : row.source)).font(.caption);HStack(spacing:20){Button(L10n.t("修改", "Edit")){memory=row.content;botID=row.bot_id;editingID=row.id};Button(L10n.t("删除", "Delete"),role:.destructive){Task{await removeMemory(row.id)}}}}
    }
   }
   Section(L10n.t("新建计划任务", "New schedule")) {
    TextField(L10n.t("标题", "Title"),text:$title).focused($focusedField, equals: "title")
    TextField(L10n.t("工作内容", "Instructions"),text:$prompt,axis:.vertical).focused($focusedField, equals: "prompt")
    DatePicker(L10n.t("当地执行时间", "Local execution time"),selection:$date).environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
    LabeledContent(L10n.t("时区", "Time zone")) {
        TextField(L10n.t("时区", "Time zone"),text:$timezone).focused($focusedField, equals: "timezone")
            .textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
    }
    if TimeZone(identifier: timezone) == nil { Text(L10n.t("请输入有效时区，例如 Asia/Shanghai。", "Enter a valid time zone, such as Asia/Shanghai.")).font(.caption).foregroundStyle(.red) }
    Picker(L10n.t("重复", "Repeat"),selection:$recurrence){Text(L10n.t("一次", "Once")).tag("once");Text(L10n.t("每天", "Daily")).tag("daily");Text(L10n.t("每周", "Weekly")).tag("weekly")}
    Picker(L10n.t("错过时间", "Missed execution"),selection:$missed){Text(L10n.t("补跑一次", "Run once")).tag("once");Text(L10n.t("跳过", "Skip")).tag("skip")}
    Button(L10n.t("创建计划", "Create schedule")){Task{await createSchedule()}}.disabled(botID.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || TimeZone(identifier: timezone) == nil)
   }
   Section(L10n.t("已有计划", "Schedules")) {
    ForEach(schedules){row in
     VStack(alignment:.leading,spacing:8){Text(row.title).font(.headline);Text(scheduleStatus(row.status) + " · " + row.timezone + " · " + recurrenceLabel(row.recurrence));Text(L10n.t("下次 ", "Next: ") + nextExecution(row)).font(.caption)
      if row.last_task_status == "failed" { Text(L10n.t("最近执行失败：", "Last execution failed: ") + (row.last_task_note ?? L10n.t("请查看任务并恢复", "Review the task and resume"))).foregroundStyle(.red) }
      if row.last_task_id != nil { NavigationLink(L10n.t("查看最近任务与结果", "View latest task and result")) { TasksView() } }
      if ["active","paused"].contains(row.status){HStack(spacing:20){Button(row.status=="active" ? L10n.t("暂停", "Pause") : L10n.t("恢复", "Resume")){Task{await scheduleAction(row.id,row.status=="active" ? "pause" : "resume")}};Button(L10n.t("取消计划", "Cancel schedule"),role:.destructive){Task{await scheduleAction(row.id,"cancel")}}}}
     }
    }
   }
  }.scrollDismissesKeyboard(.interactively).scrollContentBackground(.hidden).background(Color.rcmsBackground).tint(Color.rcmsAccent).buttonStyle(.borderless).navigationBarTitleDisplayMode(.inline).navigationTitle(L10n.t("记忆与计划", "Memory and schedules")).task{await reload()}.refreshable{await reload()}
 }
 private func nextExecution(_ schedule: WorkSchedule) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: L10n.t("zh_CN", "en_US"))
    formatter.timeZone = TimeZone(identifier: schedule.timezone) ?? .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: schedule.next_at)
 }
 private func scheduleStatus(_ value: String) -> String {
    switch value {
    case "active": return L10n.t("已启用", "Active")
    case "paused": return L10n.t("已暂停", "Paused")
    case "cancelled": return L10n.t("已取消", "Cancelled")
    case "completed": return L10n.t("已完成", "Completed")
    default: return value
    }
 }
 private func recurrenceLabel(_ value: String) -> String {
    switch value {
    case "once": return L10n.t("一次", "Once")
    case "daily": return L10n.t("每天", "Daily")
    case "weekly": return L10n.t("每周", "Weekly")
    default: return value
    }
 }
 @MainActor private func reload()async{do{bots=try await APIClient.shared.fetchBotsValue();memories=try await APIClient.shared.requestValue("/api/v1/agent/memories");schedules=try await APIClient.shared.requestValue("/api/v1/agent/schedules");if botID.isEmpty{botID=bots.first?.id.uuidString.lowercased() ?? ""};error=nil}catch{self.error=error.localizedDescription}}
 @MainActor private func saveMemory()async{do{let body=try JSONSerialization.data(withJSONObject:["bot_id":botID,"scope":"personal","content":memory,"source":"user_confirmation","confirmed":true]);let _:ConfirmedMemory=try await APIClient.shared.requestValue("/api/v1/agent/memories"+(editingID.map{"/"+$0} ?? ""),method:editingID==nil ? "POST" : "PUT",body:body);memory="";editingID=nil;focusedField=nil;await reload()}catch{self.error=error.localizedDescription}}
 @MainActor private func removeMemory(_ id:String)async{do{let _:ManagementResult=try await APIClient.shared.requestValue("/api/v1/agent/memories/\(id)",method:"DELETE");await reload()}catch{self.error=error.localizedDescription}}
 @MainActor private func exportMemory()async{do{let rows:[ConfirmedMemory]=try await APIClient.shared.requestValue("/api/v1/agent/memories/export");let file=FileManager.default.temporaryDirectory.appendingPathComponent("confirmed-memories.json");try JSONEncoder().encode(rows).write(to:file,options:.atomic);exportURL=file}catch{self.error=error.localizedDescription}}
 @MainActor private func createSchedule()async{do{let body=try JSONSerialization.data(withJSONObject:["bot_id":botID,"title":title,"prompt":prompt,"timezone":timezone,"recurrence":recurrence,"missed_policy":missed,"next_at":ISO8601DateFormatter().string(from:date)]);let _:WorkSchedule=try await APIClient.shared.requestValue("/api/v1/agent/schedules",method:"POST",body:body);title="";prompt="";focusedField=nil;await reload()}catch{self.error=error.localizedDescription}}
 @MainActor private func scheduleAction(_ id:String,_ action:String)async{do{let _:ManagementResult=try await APIClient.shared.requestValue("/api/v1/agent/schedules/\(id)/\(action)",method:"POST");await reload()}catch{self.error=error.localizedDescription}}
}
