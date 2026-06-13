import SwiftUI
import Combine

class AuthViewModel: ObservableObject {
    @Published var identifier = ""
    @Published var username = ""
    @Published var email = ""
    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var fieldErrors: [String: String] = [:]

    private var cancellables = Set<AnyCancellable>()

    func validateLogin() -> Bool {
        fieldErrors = [:]
        var isValid = true
        
        if identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors["identifier"] = L10n.t("请输入用户名或邮箱", "Username or email is required")
            isValid = false
        }
        
        if password.isEmpty {
            fieldErrors["password"] = L10n.t("请输入密码", "Password is required")
            isValid = false
        }
        
        return isValid
    }

    func login() {
        guard validateLogin() else { return }
        
        isLoading = true
        errorMessage = nil

        APIClient.shared.login(identifier: identifier, password: password)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    if let apiError = error as? APIClient.APIError {
                        self.errorMessage = apiError.errorDescription
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                }
            } receiveValue: { (payload: AuthPayload) in
                AuthManager.shared.login(payload: payload)
                RealtimeService.shared.start()
            }
            .store(in: &cancellables)
    }

    func validateRegister() -> Bool {
        fieldErrors = [:]
        var isValid = true
        
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors["username"] = L10n.t("请输入用户名", "Username is required")
            isValid = false
        } else if username.count < 3 {
            fieldErrors["username"] = L10n.t("用户名至少需要 3 个字符", "Username must be at least 3 characters")
            isValid = false
        }
        
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors["email"] = L10n.t("请输入邮箱", "Email is required")
            isValid = false
        } else if !email.contains("@") {
            fieldErrors["email"] = L10n.t("邮箱格式不正确", "Invalid email format")
            isValid = false
        }
        
        if password.isEmpty {
            fieldErrors["password"] = L10n.t("请输入密码", "Password is required")
            isValid = false
        } else if password.count < 8 {
            fieldErrors["password"] = L10n.t("密码至少需要 8 个字符", "Password must be at least 8 characters")
            isValid = false
        }
        
        return isValid
    }

    func register() {
        guard validateRegister() else { return }
        
        isLoading = true
        errorMessage = nil

        APIClient.shared.register(username: username, email: email, password: password)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    if let apiError = error as? APIClient.APIError {
                        self.errorMessage = apiError.errorDescription
                    } else {
                        self.errorMessage = error.localizedDescription
                    }
                }
            } receiveValue: { (payload: AuthPayload) in
                AuthManager.shared.login(payload: payload)
                RealtimeService.shared.start()
            }
            .store(in: &cancellables)
    }
}

struct LoginView: View {
    @StateObject private var viewModel = AuthViewModel()
    @State private var isRegistering = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesWideLayout: Bool {
        AppPlatform.usesDesktopPresentation && horizontalSizeClass == .regular
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                if usesWideLayout {
                    wideBody
                } else {
                    compactBody
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isRegistering) {
                RegisterView()
            }
        }
    }

    private var compactBody: some View {
        ScrollView {
            VStack(spacing: 26) {
                authBrandHeader(title: L10n.t("欢迎回来", "Welcome back"), subtitle: L10n.t("登录 ClawChat", "Sign in to ClawChat"), logoSize: 72)

                loginForm
                    .padding(.horizontal, 20)

                registerLink

                divider

                capabilityCard([
                    ("antenna.radiowaves.left.and.right", L10n.t("实时消息", "MQTT realtime")),
                    ("shield.checkered", L10n.t("安全认证", "Secure auth")),
                    ("message.badge", L10n.t("连接机器人、群组和历史消息", "Connect bots, groups, and message history"))
                ])
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
    }

    private var wideBody: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("ClawChat")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text(L10n.t("面向用户、机器人和群组的实时聊天。", "Broker-first chats for humans, bots, and groups."))
                        .font(.title3)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                capabilityCard([
                    ("antenna.radiowaves.left.and.right", L10n.t("实时消息", "MQTT realtime")),
                    ("shield.checkered", L10n.t("安全认证", "Secure auth")),
                    ("message.badge", L10n.t("机器人和群组历史", "Bot and group history"))
                ])

                Spacer()
            }
            .frame(maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
            .padding(54)

            Divider()
                .overlay(Color.rcmsDivider)

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(L10n.t("欢迎回来", "Welcome back"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text(L10n.t("登录 ClawChat", "Sign in to ClawChat"))
                        .font(.body)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }

                loginForm

                registerLink
            }
            .frame(width: 430)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 54)
        }
        .padding(22)
    }

    private var loginForm: some View {
        VStack(spacing: 18) {
            AuthTextInput(
                icon: "envelope",
                placeholder: L10n.t("邮箱或用户名", "Email or username"),
                text: $viewModel.identifier,
                error: viewModel.fieldErrors["identifier"]
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

            AuthSecureInput(
                icon: "lock",
                placeholder: L10n.t("密码", "Password"),
                text: $viewModel.password,
                error: viewModel.fieldErrors["password"]
            )

            if let error = viewModel.errorMessage {
                AuthErrorBanner(message: error)
            }

            Button(action: viewModel.login) {
                AuthPrimaryButtonLabel(title: L10n.t("登录", "Login"), isLoading: viewModel.isLoading)
            }
            .disabled(viewModel.isLoading)
        }
    }

    private var registerLink: some View {
        VStack {
            Button {
                isRegistering = true
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.t("还没有账号？", "Don't have an account?"))
                        .foregroundStyle(Color.rcmsTextSecondary)
                    Text(L10n.t("创建账号", "Create account"))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.rcmsAccent)
                }
                .font(.subheadline)
            }
        }
    }
}

struct RegisterView: View {
    @StateObject private var viewModel = AuthViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesWideLayout: Bool {
        AppPlatform.usesDesktopPresentation && horizontalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            FrostedBackground()

                if usesWideLayout {
                    wideBody
                } else {
                    compactBody
                }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var compactBody: some View {
        ScrollView {
            VStack(spacing: 26) {
                authBrandHeader(title: L10n.t("创建账号", "Create account"), subtitle: L10n.t("开始和机器人、团队聊天", "Start chatting with bots and teams"), logoSize: 72)

                registerForm
                    .padding(.horizontal, 20)

                signInLink

                divider

                capabilityCard([
                    ("cpu", L10n.t("机器人单聊", "Bot single chat")),
                    ("person.3", L10n.t("群组会话", "Group conversations")),
                    ("clock", L10n.t("实时历史", "Realtime history"))
                ])
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
    }

    private var wideBody: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 16, y: 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("ClawChat")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text(L10n.t("一个账号即可使用机器人单聊、群组房间和实时历史。", "Create one account for bot direct chats, group rooms, and realtime history."))
                        .font(.title3)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                capabilityCard([
                    ("cpu", L10n.t("机器人单聊", "Bot single chat")),
                    ("person.3", L10n.t("群组会话", "Group conversations")),
                    ("clock", L10n.t("实时历史", "Realtime history"))
                ])

                Spacer()
            }
            .frame(maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
            .padding(54)

            Divider()
                .overlay(Color.rcmsDivider)

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(L10n.t("创建账号", "Create account"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text(L10n.t("开始和机器人、团队聊天", "Start chatting with bots and teams"))
                        .font(.body)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }

                registerForm

                signInLink
            }
            .frame(width: 430)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 54)
        }
        .padding(22)
    }

    private var registerForm: some View {
        VStack(spacing: 18) {
            AuthTextInput(
                icon: "person",
                placeholder: L10n.t("用户名", "Username"),
                text: $viewModel.username,
                error: viewModel.fieldErrors["username"]
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

            AuthTextInput(
                icon: "envelope",
                placeholder: L10n.t("邮箱", "Email"),
                text: $viewModel.email,
                error: viewModel.fieldErrors["email"]
            )
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

            AuthSecureInput(
                icon: "lock",
                placeholder: L10n.t("密码", "Password"),
                text: $viewModel.password,
                error: viewModel.fieldErrors["password"]
            )

            PasswordRequirementRow(text: L10n.t("至少 8 个字符", "At least 8 characters"), isMet: viewModel.password.count >= 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            if let error = viewModel.errorMessage {
                AuthErrorBanner(message: error)
            }

            Button(action: viewModel.register) {
                AuthPrimaryButtonLabel(title: L10n.t("注册", "Register"), isLoading: viewModel.isLoading)
            }
            .disabled(viewModel.isLoading)
        }
    }

    private var signInLink: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 4) {
                Text(L10n.t("已有账号？", "Already have an account?"))
                    .foregroundStyle(Color.rcmsTextSecondary)
                Text(L10n.t("登录", "Sign in"))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.rcmsAccent)
            }
            .font(.subheadline)
        }
    }
}
