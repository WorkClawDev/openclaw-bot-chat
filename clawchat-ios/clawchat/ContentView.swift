import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authManager = AuthManager.shared
    @AppStorage("settings.appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some View {
        Group {
            if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2ImagePreview" {
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
                ChatRoomUIKitV2View(context: uiTestChatContext, fixture: ChatRoomV2FeatureFlag.fixture ?? .textPrependStress)
            } else if ChatRoomV2FeatureFlag.uiTestMode == "tasksConsole" {
                TasksView(viewModel: TasksViewModel(fixture: .sample))
            } else if ChatRoomV2FeatureFlag.uiTestMode?.hasPrefix("ipadWorkspace") == true {
                IpadWorkspaceView(launchSection: ChatRoomV2FeatureFlag.uiTestMode)
            } else if authManager.isAuthenticated {
                AdaptiveHomeShell()
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
    @State private var selectedTab: MainTab = .home
    @AppStorage(AppLanguageMode.storageKey) private var languageModeRawValue = AppLanguageMode.english.rawValue

    var body: some View {
        let _ = languageModeRawValue

        ZStack {
            FrostedBackground()

            TabView(selection: $selectedTab) {
                HomeDashboardView()
                .tabItem {
                    Label(L10n.t("首页", "Home"), systemImage: "house.fill")
                }
                .tag(MainTab.home)

                ContactsView()
                    .tabItem {
                        Label(L10n.t("通讯录", "Contacts"), systemImage: "person.2.fill")
                    }
                    .tag(MainTab.contacts)

                TasksView()
                    .tabItem {
                        Label(L10n.t("任务", "Tasks"), systemImage: "checklist.checked")
                    }
                    .tag(MainTab.tasks)

                if DocumentsFeatureFlag.isEnabled {
                    DocumentsView()
                        .tabItem {
                            Label(L10n.t("文档", "Docs"), systemImage: "doc.text.fill")
                        }
                        .tag(MainTab.documents)
                }

                SettingsView()
                    .tabItem {
                        Label(L10n.t("设置", "Settings"), systemImage: "gearshape.fill")
                    }
                    .tag(MainTab.settings)
            }
            .tint(Color.rcmsAccent)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color.rcmsToolbarSurface, for: .tabBar)
        }
    }

    private enum MainTab: Hashable {
        case home
        case tasks
        case contacts
        case documents
        case settings
    }
}


#Preview {
    ContentView()
}
