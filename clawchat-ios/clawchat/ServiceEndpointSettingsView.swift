import SwiftUI

struct ServiceEndpointSettingsView: View {
    @ObservedObject var manager: ServiceEndpointManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPreset: ServiceEndpointPreset
    @State private var customEndpointText: String
    @State private var errorMessage: String?
    @State private var showsApplyConfirmation = false

    init(manager: ServiceEndpointManager) {
        self.manager = manager
        _selectedPreset = State(initialValue: manager.selectedPreset)
        _customEndpointText = State(initialValue: manager.customEndpointText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.t("服务区", "Region"), selection: $selectedPreset) {
                        ForEach(ServiceEndpointPreset.allCases) { preset in
                            VStack(alignment: .leading) {
                                Text(preset.title)
                                Text(preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(preset)
                        }
                    }
                    .pickerStyle(.inline)
                    .disabled(manager.isLaunchOverridden)
                }

                if selectedPreset == .custom {
                    Section {
                        TextField("https://api.example.com", text: $customEndpointText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .disabled(manager.isLaunchOverridden)
                    } header: {
                        Text(L10n.t("Endpoint", "Endpoint"))
                    }
                }

                Section {
                    LabeledContent(L10n.t("当前地址", "Current endpoint")) {
                        Text(manager.baseURL.absoluteString)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let previewURL {
                        LabeledContent(L10n.t("将切换到", "Switching to")) {
                            Text(previewURL.absoluteString)
                                .fontDesign(.monospaced)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        prepareApply()
                    } label: {
                        Text(L10n.t("应用并退出登录", "Apply and log out"))
                    }
                    .disabled(manager.isLaunchOverridden)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle(L10n.t("服务地址", "Service endpoint"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("完成", "Done")) {
                        dismiss()
                    }
                }
            }
            .alert(
                L10n.t("切换服务地址？", "Switch endpoint?"),
                isPresented: $showsApplyConfirmation,
                actions: {
                    Button(L10n.t("取消", "Cancel"), role: .cancel) {}
                    Button(L10n.t("切换", "Switch"), role: .destructive) {
                        applyEndpoint()
                    }
                },
                message: {
                    Text(L10n.t("切换后会退出当前账号，并重新连接新系统。", "Switching logs out of the current account and reconnects to the selected system."))
                }
            )
            .alert(
                L10n.t("服务地址无效", "Invalid endpoint"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { _ in errorMessage = nil }
                ),
                actions: {
                    Button(L10n.t("确定", "OK"), role: .cancel) {}
                },
                message: {
                    Text(errorMessage ?? "")
                }
            )
        }
    }

    private var previewURL: URL? {
        ServiceEndpointConfiguration.endpointURL(
            for: selectedPreset,
            customEndpointText: customEndpointText
        )
    }

    private var footerText: String {
        if manager.isLaunchOverridden {
            return L10n.t(
                "当前由启动参数 OPENCLAW_API_BASE_URL 覆盖，App 内切换暂不可用。",
                "OPENCLAW_API_BASE_URL is overriding the endpoint, so in-app switching is disabled."
            )
        }
        return L10n.t(
            "中国区、美国区和自定义环境互相独立；切换时会清空当前登录态。",
            "China, United States, and custom environments are independent; switching clears the current session."
        )
    }

    private func prepareApply() {
        guard previewURL != nil else {
            errorMessage = ServiceEndpointManager.EndpointError.invalidURL.localizedDescription
            return
        }
        showsApplyConfirmation = true
    }

    private func applyEndpoint() {
        do {
            _ = try manager.apply(preset: selectedPreset, customEndpointText: customEndpointText)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
