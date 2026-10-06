import SwiftUI
import Combine

struct ChatRunSnapshot: Codable, Identifiable {
    let id: String
    let conversation: String
    let status: String
    let cancel_requested: Bool
    let error: String?

    var isActive: Bool { ["queued", "running", "waiting_input", "waiting_approval", "paused"].contains(status) }
    var label: String {
        if cancel_requested { return L10n.t("正在停止…", "Stopping…") }
        switch status {
        case "queued": return L10n.t("等待机器人响应…", "Waiting for the bot…")
        case "running": return L10n.t("正在处理…", "Working…")
        case "waiting_input": return L10n.t("需要补充信息", "More information needed")
        case "waiting_approval": return L10n.t("等待你确认操作", "Waiting for your confirmation")
        case "paused": return L10n.t("已暂停", "Paused")
        default: return status
        }
    }
}

struct ChatApprovalSnapshot: Codable, Identifiable {
    let id: String
    let run_id: String
    let tool: String
    let status: String
    let arguments: [String: AnyCodable]?
    let expires_at: Date

    var actionTitle: String {
        switch tool {
        case "local__fs_replace_text": return L10n.t("修改文件内容", "Edit file contents")
        case "local__fs_write": return L10n.t("写入文件", "Write a file")
        default: return tool
        }
    }

    var target: String? { arguments?["path"]?.value as? String }

    var details: String {
        guard let arguments,
              let data = try? JSONEncoder().encode(arguments),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "{}" }
        return text
    }
}

@MainActor
final class ChatActivityModel: ObservableObject {
    @Published private(set) var runs: [ChatRunSnapshot] = []
    @Published private(set) var approvals: [ChatApprovalSnapshot] = []
    @Published private(set) var isCurrent = false
    @Published private(set) var isActing = false
    @Published var error: String?
    private var isLoading = false
    private var revision = 0
    let conversationID: String
    private let api: APIClient

    init(conversationID: String, api: APIClient? = nil) {
        self.conversationID = conversationID
        self.api = api ?? .shared
    }

    func reload() async {
        guard !isLoading, !isActing else { return }
        isLoading = true
        let requestRevision = revision
        defer { isLoading = false }
        do {
            let allRuns: [ChatRunSnapshot] = try await api.requestValue("/api/v1/agent/runs")
            let matching = allRuns.filter { $0.conversation == conversationID && $0.isActive }
            let ids = Set(matching.map(\.id))
            let allApprovals: [ChatApprovalSnapshot] = matching.isEmpty ? [] : try await api.requestValue("/api/v1/agent/approvals")
            try Task.checkCancellation()
            guard requestRevision == revision, !isActing else { return }
            runs = matching
            approvals = allApprovals.filter { ids.contains($0.run_id) && $0.status == "pending" }
            isCurrent = true
        } catch {
            guard requestRevision == revision else { return }
            isCurrent = false
            // A bot without the optional execution API still has a fully usable chat.
            if !runs.isEmpty { self.error = error.localizedDescription }
        }
    }

    func decide(_ approval: ChatApprovalSnapshot, approved: Bool) async {
        guard isCurrent, !isActing, approval.expires_at > Date(), approvals.contains(where: { $0.id == approval.id }) else { return }
        await perform("/api/v1/agent/approvals/\(approval.id)/decision", body: ["approved": approved])
    }

    func stop(_ run: ChatRunSnapshot) async {
        guard isCurrent, !isActing, !run.cancel_requested else { return }
        await perform("/api/v1/agent/runs/\(run.id)/cancel", body: ["input": ""])
    }

    func resume(_ run: ChatRunSnapshot, input: String) async {
        guard isCurrent, !isActing else { return }
        if run.status == "waiting_input", input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        await perform("/api/v1/agent/runs/\(run.id)/resume", body: ["input": input])
    }

    private func perform(_ path: String, body: [String: Any]) async {
        isActing = true
        revision += 1
        error = nil
        defer { isActing = false }
        do {
            struct Result: Codable { let status: String }
            let encoded = try JSONSerialization.data(withJSONObject: body)
            let _: Result = try await api.requestValue(path, method: "POST", body: encoded)
            // Let an older poll finish before requesting the post-action state.
            while isLoading { try await Task.sleep(for: .milliseconds(50)) }
            isActing = false
            isCurrent = false
            await reload()
        } catch { self.error = error.localizedDescription }
    }
}

struct ChatActivityView: View {
    @StateObject private var model: ChatActivityModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var supplementalInput = ""

    init(conversationID: String) {
        _model = StateObject(wrappedValue: ChatActivityModel(conversationID: conversationID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let run = model.runs.first {
                HStack(spacing: 8) {
                    if run.status == "running" && !run.cancel_requested { ProgressView().controlSize(.mini) }
                    Text(model.isCurrent ? run.label : L10n.t("状态暂时无法同步", "Status unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await model.stop(run) } } label: {
                        Image(systemName: "stop.circle").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(L10n.t("停止", "Stop"))
                    .accessibilityIdentifier("chat.activity.stop")
                    .disabled(model.isActing || !model.isCurrent || run.cancel_requested)
                }
                if run.status == "waiting_input" || run.status == "paused" {
                    HStack {
                        TextField(L10n.t("补充信息", "Additional information"), text: $supplementalInput)
                            .accessibilityIdentifier("chat.activity.input")
                        Button(L10n.t("继续", "Continue")) {
                            Task { await model.resume(run, input: supplementalInput) }
                        }
                        .accessibilityIdentifier("chat.activity.resume")
                        .disabled(model.isActing || !model.isCurrent || (run.status == "waiting_input" && supplementalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }.font(.subheadline)
                }
            }
            if let approval = model.approvals.first {
                approvalCard(approval)
                if model.approvals.count > 1 {
                    Text(L10n.t("还有 \(model.approvals.count - 1) 项待确认", "\(model.approvals.count - 1) more awaiting confirmation"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.error {
                HStack {
                    Text(error).font(.caption).lineLimit(2)
                    Spacer()
                    Button(L10n.t("重试", "Retry")) { Task { model.error = nil; await model.reload() } }
                }.foregroundStyle(Color.rcmsDanger)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.reload()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("agentUpdate"))) { _ in
            Task { await model.reload() }
        }
    }

    private func approvalCard(_ approval: ChatApprovalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("确认这次操作", "Confirm this action")).font(.subheadline.weight(.semibold))
            Text(approval.actionTitle).font(.subheadline)
            if let target = approval.target {
                Text(target).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            DisclosureGroup(L10n.t("查看操作内容", "Review action details")) {
                ScrollView {
                    Text(approval.tool + "\n" + approval.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 130)
            }.font(.caption)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if approval.expires_at <= timeline.date {
                    Text(L10n.t("确认已过期，请让机器人重新发起。", "This confirmation expired. Ask the bot to try again.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Button(L10n.t("确认执行", "Confirm")) { Task { await model.decide(approval, approved: true) } }
                            .buttonStyle(.borderedProminent).tint(Color.rcmsAccent)
                            .accessibilityIdentifier("chat.activity.approve")
                        Button(L10n.t("取消", "Cancel")) { Task { await model.decide(approval, approved: false) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("chat.activity.deny")
                    }
                    .disabled(model.isActing || !model.isCurrent)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rcmsSurfaceMuted, in: RoundedRectangle(cornerRadius: 16))
        .tint(Color.rcmsTextPrimary)
    }
}
