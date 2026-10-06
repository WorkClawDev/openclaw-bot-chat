import SwiftUI

/// Identity marks belong on the bot list only. Message cells never instantiate this view.
struct BotIdentityMark: View {
    let name: String
    let imageURL: String?
    let size: CGFloat
    var isGroup = false

    private var style: (String, Color) {
        if isGroup { return ("person.2.fill", .orange) }
        let key = name.lowercased()
        if key.contains("code") || key.contains("代码") { return ("chevron.left.forwardslash.chevron.right", .blue) }
        if key.contains("写") || key.contains("文") { return ("pencil.tip", .green) }
        if key.contains("翻译") { return ("globe", .teal) }
        let colors: [Color] = [.purple, .indigo, .teal, .orange]
        let index = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % colors.count }
        return ("sparkle", colors[index])
    }

    var body: some View {
        Group {
            if let url = APIClient.shared.resolvedURL(from: imageURL) {
                RemoteAvatarImage(url: url) { fallback }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(style.1.opacity(0.1))
            .overlay {
                Image(systemName: style.0)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(style.1)
            }
    }
}

enum HomeUtility: String, CaseIterable, Identifiable {
    case contacts, tasks, documents, assistant, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .contacts: L10n.t("机器人与群组", "Bots and groups")
        case .tasks: L10n.t("任务", "Tasks")
        case .documents: L10n.t("文档", "Documents")
        case .assistant: L10n.t("执行与授权", "Activity and approvals")
        case .settings: L10n.t("设置", "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .contacts: "person.2"
        case .tasks: "checklist"
        case .documents: "doc.text"
        case .assistant: "checkmark.shield"
        case .settings: "gearshape"
        }
    }
}

struct HomeUtilitySheet: View {
    @Environment(\.dismiss) private var dismiss
    let utility: HomeUtility

    var body: some View {
        destination
            .environment(\.closeHomeUtility, { dismiss() })
            .background(Color.rcmsBackground)
            .tint(Color.rcmsTextPrimary)
            .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var destination: some View {
        switch utility {
        case .contacts: ContactsView()
        case .tasks: TasksView()
        case .documents: DocumentsView()
        case .assistant: NavigationStack { AssistantView().navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { HomeUtilityCloseButton() } } }
        case .settings: SettingsView()
        }
    }
}

extension EnvironmentValues {
    @Entry var closeHomeUtility: (() -> Void)? = nil
}

struct HomeUtilityCloseButton: View {
    @Environment(\.closeHomeUtility) private var close
    var body: some View {
        if let close {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.t("关闭", "Close"))
            .accessibilityIdentifier("home.utility.close")
        }
    }
}

/// Deterministic visual-review data. Normal authenticated launches do not use it.
enum HomeV5Preview {
    static var model: HomeDashboardViewModel {
        let names = ["Grok Bot", "Code Bot", "写作助手", "资料助手", "翻译助手", "生活助手"]
        let snippets = ["简报已整理好，附上了来源链接。", "已找到问题，修改建议在这里。", "第二版文案已经完成。", "已整理为三个重点。", "这段翻译可以更自然一些。", "周末行程已经安排好了。"]
        let bots = names.enumerated().map { index, name in
            Bot(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                name: name, description: "随时开始聊天", status: "online", mqttTopic: "preview-bot-\(index)")
        }
        let conversations = bots.enumerated().map { index, bot in
            Conversation(id: bot.mqttTopic!, type: "bot", name: bot.name, targetId: bot.id.uuidString,
                         lastMessage: .init(content: snippets[index], timestamp: 1_791_087_000 - Int64(index * 400)), unreadCount: index == 0 ? 2 : nil)
        }
        return HomeDashboardViewModel(bots: bots, conversations: conversations, isPreview: true)
    }

    static var files: [Message] {
#if DEBUG
        if let kind = UserDefaults.standard.string(forKey: "uiTestFileKind"), ["pdf", "docx", "xlsx"].contains(kind) {
            return [Message(from: RealtimeMessagePayload(
                id: "v5-file", topic: "fixture", conversationId: "fixture", timestamp: 1_791_087_000,
                from: MessagePeerPayload(type: "bot", id: "fixture-bot", name: "Grok Bot", avatar: nil),
                to: MessagePeerPayload(type: "user", id: "preview-user", name: nil, avatar: nil),
                content: RealtimeContentPayload(type: "file", body: "layout-check.\(kind)", url: "http://127.0.0.1:18084/layout-check.\(kind)", name: "layout-check.\(kind)", size: 2048), seq: 1
            ))]
        }
        if let rawID = UserDefaults.standard.string(forKey: "uiTestDocumentID"), let id = UUID(uuidString: rawID) {
            let path = "/documents/\(id.uuidString.lowercased())"
            return [Message(from: RealtimeMessagePayload(
                id: "v5-document", topic: "fixture", conversationId: "fixture", timestamp: 1_791_087_000,
                from: MessagePeerPayload(type: "bot", id: "fixture-bot", name: "Grok Bot", avatar: nil),
                to: MessagePeerPayload(type: "user", id: "preview-user", name: nil, avatar: nil),
                content: RealtimeContentPayload(type: "text", body: "V5 linked document\n\(path)", meta: [
                    "document_title": AnyCodable("V5 linked document"), "document_url": AnyCodable(path),
                    "document_summary": AnyCodable("Open the saved document or continue editing it in chat.")
                ]), seq: 1
            ))]
        }
#endif
        let asset = Asset(id: "00000000-0000-4000-8000-000000000005", kind: "file", status: "ready", mimeType: "text/markdown", size: 20, fileName: "AI应用简报.md", downloadURL: "http://127.0.0.1:18082/fixture/result.md")
        return [Message(from: RealtimeMessagePayload(
            id: "v5-file", topic: "fixture", conversationId: "fixture", timestamp: 1_791_087_000,
            from: MessagePeerPayload(type: "bot", id: "fixture-bot", name: "Grok Bot", avatar: nil),
            to: MessagePeerPayload(type: "user", id: "preview-user", name: nil, avatar: nil),
            content: RealtimeContentPayload(type: "file", body: asset.fileName, url: asset.downloadURL, name: asset.fileName, size: asset.size, meta: ["asset": asset.metaValue]), seq: 1
        ))]
    }

    static var messages: [Message] {
        [
            (true, "帮我整理一下今天的 AI 行业动态，重点关注产品应用。"),
            (false, "好的。我会筛选与产品相关的消息，并保留来源。"),
            (false, "整理好了，今天可以重点看这三个方向：\n\n1. **多模态交互**：语音与图像进入日常工作流。\n2. **工具调用**：从回答问题延伸到完成操作。\n3. **端侧体验**：更快的响应和更清晰的权限提示。"),
            (true, "再精简一点，方便发到群里。"),
            (false, "可以。我会保留核心结论，把每个要点压缩成一句话。")
        ].enumerated().map { index, item in
            Message(from: RealtimeMessagePayload(
                id: "v5-preview-\(index)", topic: "preview-bot-0", conversationId: "preview-bot-0", timestamp: 1_791_087_000 + Int64(index),
                from: MessagePeerPayload(type: item.0 ? "user" : "bot", id: item.0 ? "preview-user" : "preview-bot", name: item.0 ? "我" : "Grok Bot", avatar: nil),
                to: MessagePeerPayload(type: item.0 ? "bot" : "user", id: item.0 ? "preview-bot" : "preview-user", name: nil, avatar: nil),
                content: RealtimeContentPayload(type: "text", body: item.1, url: nil, name: nil, size: nil, meta: nil), seq: Int64(index + 1)
            ))
        }
    }
}
