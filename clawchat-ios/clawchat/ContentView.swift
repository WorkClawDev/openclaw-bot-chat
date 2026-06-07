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
            } else if ChatRoomV2FeatureFlag.uiTestMode == "chatRoomV2" {
                ChatRoomUIKitV2View(context: uiTestChatContext, fixture: ChatRoomV2FeatureFlag.fixture ?? .textPrependStress)
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

    var body: some View {
        ZStack {
            FrostedBackground()

            TabView(selection: $selectedTab) {
                HomeDashboardView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(MainTab.home)

                BotsView()
                    .tabItem {
                        Label("Bots", systemImage: "cpu.fill")
                    }
                    .tag(MainTab.bots)

                GroupsView()
                    .tabItem {
                        Label("Groups", systemImage: "person.3.fill")
                    }
                    .tag(MainTab.groups)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
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
        case bots
        case groups
        case settings
    }
}


#Preview {
    ContentView()
}
