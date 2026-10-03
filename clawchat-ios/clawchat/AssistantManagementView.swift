import SwiftUI
private struct ConfirmedMemory:Codable,Identifiable {let id:String;let bot_id:String;let scope:String;let content:String;let source:String;let confirmed:Bool}
private struct WorkSchedule:Codable,Identifiable {let id:String;let title:String;let prompt:String;let timezone:String;let recurrence:String;let status:String;let next_at:String;let last_task_id:String?;let last_task_status:String?;let last_task_note:String?}
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
 var body:some View {
  Form {
   if let error { Text(error).foregroundStyle(.red) }
   Picker("助手",selection:$botID){ForEach(bots){bot in Text(bot.name).tag(bot.id.uuidString.lowercased())}}
   Section("已确认记忆") {
    TextField("记忆内容",text:$memory,axis:.vertical)
    Button("确认保存记忆") { Task { await saveMemory() } }
    Button("导出记忆") { Task { await exportMemory() } }
    if let exportURL { ShareLink("分享记忆文件",item:exportURL) }
    ForEach(memories){row in
     VStack(alignment:.leading){Text(row.content);Text("\(row.scope) · 来源 \(row.source)").font(.caption);HStack{Button("修改"){memory=row.content;botID=row.bot_id;editingID=row.id};Button("删除",role:.destructive){Task{await removeMemory(row.id)}}}}
    }
   }
   Section("新建计划任务") {
    TextField("标题",text:$title)
    TextField("工作内容",text:$prompt,axis:.vertical)
    DatePicker("当地执行时间",selection:$date)
    TextField("时区",text:$timezone)
    Picker("重复",selection:$recurrence){Text("一次").tag("once");Text("每天").tag("daily");Text("每周").tag("weekly")}
    Picker("错过时间",selection:$missed){Text("补跑一次").tag("once");Text("跳过").tag("skip")}
    Button("创建计划"){Task{await createSchedule()}}
   }
   Section("已有计划") {
    ForEach(schedules){row in
     VStack(alignment:.leading){Text(row.title).font(.headline);Text("\(row.status) · \(row.timezone) · \(row.recurrence)");Text("下次 \(row.next_at)").font(.caption)
      if row.last_task_status == "failed" { Text("最近执行失败："+(row.last_task_note ?? "请查看任务并恢复")).foregroundStyle(.red) }
      if row.last_task_id != nil { NavigationLink("查看最近任务与结果") { TasksView() } }
      if ["active","paused"].contains(row.status){HStack{Button(row.status=="active" ? "暂停" : "恢复"){Task{await scheduleAction(row.id,row.status=="active" ? "pause" : "resume")}};Button("取消计划",role:.destructive){Task{await scheduleAction(row.id,"cancel")}}}}
     }
    }
   }
  }.navigationTitle("记忆与计划").task{await reload()}.refreshable{await reload()}
 }
 @MainActor private func reload()async{do{bots=try await APIClient.shared.fetchBotsValue();memories=try await APIClient.shared.requestValue("/api/v1/agent/memories");schedules=try await APIClient.shared.requestValue("/api/v1/agent/schedules");if botID.isEmpty{botID=bots.first?.id.uuidString.lowercased() ?? ""};error=nil}catch{self.error=error.localizedDescription}}
 @MainActor private func saveMemory()async{do{let body=try JSONSerialization.data(withJSONObject:["bot_id":botID,"scope":"personal","content":memory,"source":"user_confirmation","confirmed":true]);let _:ConfirmedMemory=try await APIClient.shared.requestValue("/api/v1/agent/memories"+(editingID.map{"/"+$0} ?? ""),method:editingID==nil ? "POST" : "PUT",body:body);memory="";editingID=nil;await reload()}catch{self.error=error.localizedDescription}}
 @MainActor private func removeMemory(_ id:String)async{do{let _:ManagementResult=try await APIClient.shared.requestValue("/api/v1/agent/memories/\(id)",method:"DELETE");await reload()}catch{self.error=error.localizedDescription}}
 @MainActor private func exportMemory()async{do{let rows:[ConfirmedMemory]=try await APIClient.shared.requestValue("/api/v1/agent/memories/export");let file=FileManager.default.temporaryDirectory.appendingPathComponent("confirmed-memories.json");try JSONEncoder().encode(rows).write(to:file,options:.atomic);exportURL=file}catch{self.error=error.localizedDescription}}
 @MainActor private func createSchedule()async{do{let body=try JSONSerialization.data(withJSONObject:["bot_id":botID,"title":title,"prompt":prompt,"timezone":timezone,"recurrence":recurrence,"missed_policy":missed,"next_at":ISO8601DateFormatter().string(from:date)]);let _:WorkSchedule=try await APIClient.shared.requestValue("/api/v1/agent/schedules",method:"POST",body:body);title="";prompt="";await reload()}catch{self.error=error.localizedDescription}}
 @MainActor private func scheduleAction(_ id:String,_ action:String)async{do{let _:ManagementResult=try await APIClient.shared.requestValue("/api/v1/agent/schedules/\(id)/\(action)",method:"POST");await reload()}catch{self.error=error.localizedDescription}}
}
