import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var pushNotifications = ChatPushNotifications.shared
    @AppStorage("settings.appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage("settings.compactMessageMode") private var compactMessageMode = false

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some View {
        Group {
            if ChatRoomV2FeatureFlag.uiTestMode == "chatFilesV5" {
                NavigationStack {
                    ChatRoomView(previewContext: ChatContext(id: "fixture", title: "Grok Bot", subtitle: "", isGroup: false, groupId: nil), messages: HomeV5Preview.files)
                }
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatActivityV5" {
                NavigationStack {
                    ChatRoomView(previewContext: ChatContext(id: "fixture", title: "Grok Bot", subtitle: "", isGroup: false, groupId: nil), messages: HomeV5Preview.messages)
                }
            } else if ChatRoomV2FeatureFlag.uiTestMode == "homeV5" {
                HomeDashboardView(viewModel: HomeV5Preview.model)
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2ImagePreview" {
                ChatRoomV2ImagePreviewFixtureView(context: uiTestChatContext)
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2LiveBridge" {
                ChatRoomV2LiveBridgeFixtureView(context: uiTestChatContext)
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2StatusStability" {
                ChatRoomV2StatusStabilityFixtureView(context: uiTestChatContext)
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2Keyboard" {
                ChatRoomView(
                    previewContext: uiTestChatContext,
                    messages: uiTestKeyboardMessages,
                    connectionState: .connected,
                    currentUserID: "fixture-user"
                )
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2" {
                VStack(spacing: 0) {
                    if ProcessInfo.processInfo.arguments.contains("-chatRoomV2DensityControl") {
                        Toggle("Compact message mode", isOn: $compactMessageMode)
                            .accessibilityIdentifier("fixture.compact.toggle")
                            .padding(.horizontal, 16)
                    }
                    ChatRoomUIKitV2View(context: uiTestChatContext,
                                       fixture: ChatRoomV2FeatureFlag.fixture ?? .textPrependStress,
                                       compactMessageMode: compactMessageMode)
                }
            } else if ChatRoomV2FeatureFlag.uiTestMode == "assistantConsole" {
                NavigationStack { AssistantView() }
            } else if ChatRoomV2FeatureFlag.uiTestMode == "tasksConsole" {
                TasksView(viewModel: TasksViewModel(fixture: .sample))
            } else if ChatRoomV2FeatureFlag.uiTestMode?.hasPrefix("ipadWorkspace") == true {
                IpadWorkspaceView(launchSection: ChatRoomV2FeatureFlag.uiTestMode)
            } else if authManager.isAuthenticated {
                AdaptiveHomeShell()
                    .id(authManager.currentUser?.id)
                    .onAppear {
                        authManager.refreshCurrentUserIfNeeded()
                        RealtimeService.shared.start()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active else { return }
                        authManager.refreshCurrentUserIfNeeded()
                        RealtimeService.shared.start()
                    }
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(appearanceMode.colorScheme)
        .onAppear { activateNotifications() }
        .onChange(of: authManager.currentUser?.id) { _, _ in activateNotifications() }
        .onChange(of: authManager.accessToken) { _, _ in activateNotifications() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activateNotifications() }
        }
        .background(ChatPushPresentationHost(notifications: pushNotifications).frame(width: 0, height: 0))
    }

    private func activateNotifications() {
        guard authManager.isAuthenticated, let user = authManager.currentUser,
              let token = authManager.accessToken else { return }
        pushNotifications.activate(ChatPushSession(userID: user.id, accessToken: token, endpoint: APIClient.shared.baseURL))
    }

    private var uiTestChatContext: ChatContext {
        ChatContext(
            id: "ui-test-chat-v2",
            title: "Chat V2 Test",
            subtitle: "",
            isGroup: false,
            groupId: nil,
            bot: nil,
            memberCount: nil,
            avatarURLString: nil
        )
    }

    private var uiTestKeyboardMessages: [Message] {
        (41...100).map { sequence in
            let isOutgoing = sequence.isMultiple(of: 4)
            let sender = MessagePeerPayload(
                type: isOutgoing ? "user" : "bot",
                id: isOutgoing ? "fixture-user" : "fixture-bot",
                name: isOutgoing ? "Fixture User" : "Fixture Bot",
                avatar: nil
            )
            let receiver = MessagePeerPayload(
                type: isOutgoing ? "bot" : "user",
                id: isOutgoing ? "fixture-bot" : "fixture-user",
                name: nil,
                avatar: nil
            )
            return Message(from: RealtimeMessagePayload(
                id: "keyboard-fixture-\(sequence)",
                topic: uiTestChatContext.id,
                conversationId: uiTestChatContext.id,
                timestamp: Int64(1_800_000_000 + sequence),
                from: sender,
                to: receiver,
                content: RealtimeContentPayload(
                    type: "text",
                    body: "#\(sequence) Keyboard fixture message keeps V2 anchored while the composer appears and hides.",
                    url: nil,
                    name: nil,
                    size: nil,
                    meta: nil
                ),
                seq: Int64(sequence)
            ))
        }
    }
}

private struct AdaptiveHomeShell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesWideWorkspace: Bool {
        AppPlatform.usesDesktopPresentation && horizontalSizeClass == .regular
    }

    var body: some View {
        if usesWideWorkspace {
            IpadWorkspaceView()
        } else {
            HomeView()
        }
    }
}

struct HomeView: View {
    @AppStorage(AppLanguageMode.storageKey) private var languageModeRawValue = AppLanguageMode.english.rawValue

    var body: some View {
        let _ = languageModeRawValue
        HomeDashboardView()
            .tint(Color.rcmsTextPrimary)
    }
}


#Preview {
    ContentView()
}
