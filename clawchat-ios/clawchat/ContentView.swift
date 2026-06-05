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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-test-chat-room") {
                ChatRoomUITestHarness()
            } else if authManager.isAuthenticated {
                authenticatedHome
            } else {
                LoginView()
            }
            #else
            if authManager.isAuthenticated {
                authenticatedHome
            } else {
                LoginView()
            }
            #endif
        }
        .preferredColorScheme(appearanceMode.colorScheme)
    }

    private var authenticatedHome: some View {
        HomeView()
            .onAppear {
                authManager.refreshCurrentUserIfNeeded()
                RealtimeService.shared.start()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                authManager.refreshCurrentUserIfNeeded()
                RealtimeService.shared.start()
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
