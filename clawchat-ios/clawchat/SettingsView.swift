import SwiftUI
import UserNotifications
import PhotosUI

struct SettingsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject var viewModel: SettingsViewModel
    @StateObject var authManager = AuthManager.shared
    @StateObject var realtimeService = RealtimeService.shared
    let loadsProfileOnAppear: Bool

    @AppStorage("settings.botNotificationsEnabled") var botNotificationsEnabled = false
    @AppStorage("settings.compactMessageMode") var compactMessageMode = false
    @AppStorage("settings.imageUploadQuality") var imageUploadQuality = "Compressed"
    @AppStorage("settings.appearanceMode") var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppLanguageMode.storageKey) var languageModeRawValue = AppLanguageMode.english.rawValue

    @State var didInitialLoad = false
    @State var isEditingProfile = false
    @State var nicknameDraft = ""
    @State var avatarURLDraft = ""
    @State var selectedAvatarItem: PhotosPickerItem?
    @State var pendingAvatarImage: PendingAvatarImage?
    @State var isUploadingAvatar = false
    @State var profileErrorMessage: String?

    @State var showPasswordEditor = false
    @State var currentPassword = ""
    @State var newPassword = ""
    @State var confirmPassword = ""
    @State var passwordErrorMessage: String?

    @State var showDeviceDetails = false
    @State var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State var toast: SettingsToastPayload?

    @FocusState var focusNicknameField: Bool

    init(previewUser: User? = nil) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(previewUser: previewUser))
        loadsProfileOnAppear = previewUser == nil
    }

    var resolvedUser: User? {
        viewModel.currentUser ?? authManager.currentUser
    }

    var hasNotificationPermission: Bool {
        notificationAuthorizationStatus == .authorized || notificationAuthorizationStatus == .provisional
    }

    var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var languageMode: AppLanguageMode {
        AppLanguageMode(rawValue: languageModeRawValue) ?? .english
    }

    var usesWideSettingsLayout: Bool {
        AppPlatform.usesDesktopPresentation && horizontalSizeClass == .regular
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                FrostedBackground()

                ScrollView {
                    settingsContent
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await refreshAll()
                }

                if let toast {
                    toastView(toast)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if loadsProfileOnAppear {
                    await initialLoadIfNeeded()
                } else {
                    syncProfileDraftsIfNeeded()
                    await refreshNotificationAuthorization()
                }
            }
            .onChange(of: resolvedUser?.id) { _, _ in
                syncProfileDraftsIfNeeded()
            }
            .sheet(item: $pendingAvatarImage) { pending in
                AvatarCropperView(
                    image: pending.image,
                    title: L10n.t("调整头像", "Adjust avatar"),
                    onCancel: {
                        pendingAvatarImage = nil
                    },
                    onConfirm: { croppedImage in
                        pendingAvatarImage = nil
                        Task { await uploadProfileAvatarImage(croppedImage) }
                    }
                )
            }
            .alert(
                L10n.t("个人资料加载失败", "Profile failed to load"),
                isPresented: Binding(
                    get: { viewModel.loadErrorMessage != nil },
                    set: { _ in viewModel.loadErrorMessage = nil }
                ),
                actions: {
                    Button(L10n.t("确定", "OK"), role: .cancel) {}
                },
                message: {
                    Text(viewModel.loadErrorMessage ?? "")
                }
            )
        }
    }

    @ViewBuilder
    var settingsContent: some View {
        if let user = resolvedUser {
            if usesWideSettingsLayout {
                wideSettingsContent(user: user)
            } else {
                compactSettingsContent(user: user)
            }
        } else if viewModel.isLoading {
            loadingIndicator
                .padding(.horizontal, 16)
                .padding(.top, 16)
        } else {
            loadingIndicator
                .padding(.horizontal, 16)
                .padding(.top, 16)
        }
    }
}
