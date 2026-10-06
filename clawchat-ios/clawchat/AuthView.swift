import SwiftUI
import Combine

class AuthViewModel: ObservableObject {
    @Published var identifier = ""
    @Published var username = ""
    @Published var email = ""
    @Published var password = ""
    @Published var phone = ""
    @Published var phoneCode = ""
    @Published var phoneCodeCooldown = 0
    @Published var isLoading = false
    @Published var isRequestingPhoneCode = false
    @Published var errorMessage: String?
    @Published var fieldErrors: [String: String] = [:]
    @Published var phoneConfiguration: PhoneAuthConfiguration?
    @Published var phoneChallenge: PhoneCaptchaChallenge?

    private let injectedPhoneAPI: (any PhoneAuthenticationAPI)?
    private var phoneAPI: any PhoneAuthenticationAPI { injectedPhoneAPI ?? APIClient.shared }
    private var phoneRequest: AnyCancellable?
    private var phoneOperation: UUID?
    private var pendingPhoneChallenge: (id: UUID, phone: String, api: any PhoneAuthenticationAPI)?

    init(phoneAPI: (any PhoneAuthenticationAPI)? = nil) {
        injectedPhoneAPI = phoneAPI
    }

    var supportsPhoneAuth: Bool { phoneConfiguration?.enabled == true }

    func loadPhoneAvailability() {
        phoneAPI.fetchPhoneConfiguration()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.phoneConfiguration = $0 })
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()
    private var cooldownTimer: AnyCancellable?

    var canRequestPhoneCode: Bool {
        !isRequestingPhoneCode && phoneCodeCooldown == 0
    }

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

    func validatePhoneForCode() -> Bool {
        fieldErrors = [:]
        let normalized = normalizedMainlandPhone(phone)
        if normalized == nil {
            fieldErrors["phone"] = L10n.t("请输入有效的中国大陆手机号", "Enter a valid mainland China phone number")
            return false
        }
        return true
    }

    func requestPhoneCode() {
        guard canRequestPhoneCode, validatePhoneForCode(), let normalized = normalizedMainlandPhone(phone) else { return }
        let api = phoneAPI
        let operation = UUID()
        phoneOperation = operation
        isRequestingPhoneCode = true
        errorMessage = nil
        phoneRequest = api.fetchPhoneConfiguration()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case .failure(let error) = completion { self?.failPhoneCode(operation, error: error) }
            } receiveValue: { [weak self] configuration in
                guard let self, self.phoneOperation == operation else { return }
                self.phoneConfiguration = configuration
                guard configuration.enabled else { self.failPhoneCode(operation, error: PhoneCaptchaError.unavailable); return }
                switch configuration.captchaProvider {
                case "mock" where PhoneCaptchaChallenge.isLoopback(api.baseURL):
                    self.sendPhoneCode(operation, phone: normalized, api: api, token: "mock")
                case "turnstile":
                    guard let url = PhoneCaptchaChallenge.url(baseURL: api.baseURL) else {
                        self.failPhoneCode(operation, error: PhoneCaptchaError.unavailable); return
                    }
                    self.pendingPhoneChallenge = (operation, normalized, api)
                    self.phoneChallenge = PhoneCaptchaChallenge(id: operation, url: url)
                default:
                    self.failPhoneCode(operation, error: PhoneCaptchaError.unavailable)
                }
            }
    }

    func completePhoneChallenge(_ id: UUID, result: Result<String, PhoneCaptchaError>) {
        guard let pending = pendingPhoneChallenge, pending.id == id, phoneOperation == id else { return }
        pendingPhoneChallenge = nil
        phoneChallenge = nil
        switch result {
        case .success(let token):
            guard !token.isEmpty, token.count <= 2048 else { failPhoneCode(id, error: PhoneCaptchaError.failed); return }
            sendPhoneCode(id, phone: pending.phone, api: pending.api, token: token)
        case .failure(let error): failPhoneCode(id, error: error)
        }
    }

    func cancelPhoneChallenge() {
        // Sheet dismissal after successful verification must not cancel the code POST.
        guard pendingPhoneChallenge != nil else { return }
        cancelPhoneCodeRequest()
    }

    func cancelPhoneCodeRequest() {
        phoneRequest?.cancel()
        phoneOperation = nil
        pendingPhoneChallenge = nil
        phoneChallenge = nil
        isRequestingPhoneCode = false
    }

    private func sendPhoneCode(_ operation: UUID, phone: String, api: any PhoneAuthenticationAPI, token: String) {
        guard phoneOperation == operation else { return }
        guard normalizedMainlandPhone(self.phone) == phone, phoneAPI.baseURL == api.baseURL else {
            failPhoneCode(operation, error: PhoneCaptchaError.contextChanged); return
        }
        phoneRequest = api.requestPhoneCode(phone: phone, captchaToken: token, purpose: "login")
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                if case .failure(let error) = completion { self?.failPhoneCode(operation, error: error) }
            } receiveValue: { [weak self] response in
                guard let self, self.phoneOperation == operation else { return }
                self.phoneOperation = nil
                self.isRequestingPhoneCode = false
                self.startPhoneCodeCooldown(response.cooldownSeconds ?? 60)
            }
    }

    private func failPhoneCode(_ operation: UUID, error: Error) {
        guard phoneOperation == operation else { return }
        phoneOperation = nil
        pendingPhoneChallenge = nil
        phoneChallenge = nil
        isRequestingPhoneCode = false
        errorMessage = error.localizedDescription
    }

    func validatePhoneLogin() -> Bool {
        fieldErrors = [:]
        var isValid = true

        if normalizedMainlandPhone(phone) == nil {
            fieldErrors["phone"] = L10n.t("请输入有效的中国大陆手机号", "Enter a valid mainland China phone number")
            isValid = false
        }

        let trimmedCode = phoneCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCode.count != 6 || trimmedCode.contains(where: { !$0.isNumber }) {
            fieldErrors["phoneCode"] = L10n.t("请输入 6 位验证码", "Enter the 6-digit code")
            isValid = false
        }

        return isValid
    }

    func phoneLogin() {
        guard validatePhoneLogin(), let normalizedPhone = normalizedMainlandPhone(phone) else { return }

        isLoading = true
        errorMessage = nil

        APIClient.shared.phoneLogin(phone: normalizedPhone, code: phoneCode.trimmingCharacters(in: .whitespacesAndNewlines))
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

    func normalizedMainlandPhone(_ value: String) -> String? {
        var phone = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in [" ", "-", "(", ")"] {
            phone = phone.replacingOccurrences(of: token, with: "")
        }
        if phone.hasPrefix("+86") {
            phone.removeFirst(3)
        } else if phone.hasPrefix("0086") {
            phone.removeFirst(4)
        }
        guard phone.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return phone
    }

    private func startPhoneCodeCooldown(_ seconds: Int) {
        phoneCodeCooldown = max(1, seconds)
        cooldownTimer?.cancel()
        cooldownTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.phoneCodeCooldown > 0 {
                    self.phoneCodeCooldown -= 1
                }
                if self.phoneCodeCooldown == 0 {
                    self.cooldownTimer?.cancel()
                    self.cooldownTimer = nil
                }
            }
    }
}

struct LoginView: View {
    @StateObject private var viewModel = AuthViewModel()
    @State private var isRegistering = false
    @State private var usesPhoneAuth = ServiceEndpointConfiguration.currentBaseURL == ServiceEndpointConfiguration.chinaBaseURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesWideLayout: Bool {
        AppPlatform.usesDesktopPresentation && horizontalSizeClass == .regular
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    FrostedBackground()

                    if usesWideLayout && geometry.size.width >= 1000 {
                        wideBody
                    } else {
                        compactBody
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isRegistering) {
                RegisterView()
            }
            .task { viewModel.loadPhoneAvailability() }
            .onReceive(viewModel.$phoneConfiguration) { configuration in
                if configuration?.enabled == false { usesPhoneAuth = false }
            }
            .onDisappear { viewModel.cancelPhoneCodeRequest() }
            .sheet(item: $viewModel.phoneChallenge, onDismiss: viewModel.cancelPhoneChallenge) { challenge in
                PhoneCaptchaSheet(challenge: challenge) { result in
                    viewModel.completePhoneChallenge(challenge.id, result: result)
                }
            }
        }
    }

    private var compactBody: some View {
        ScrollView {
            VStack(spacing: 26) {
                authBrandHeader(title: L10n.t("欢迎回来", "Welcome back"), subtitle: L10n.t("登录 ClawChat", "Sign in to ClawChat"), logoSize: 72)

                activeLoginForm
                    .padding(.horizontal, 20)

                loginModeLink

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

                activeLoginForm

                loginModeLink
            }
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 54)
        }
        .padding(22)
    }

    private var activeLoginForm: some View {
        Group {
            if usesPhoneAuth {
                phoneLoginForm
            } else {
                passwordLoginForm
            }
        }
    }

    private var passwordLoginForm: some View {
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

    private var phoneLoginForm: some View {
        VStack(spacing: 18) {
            AuthTextInput(
                icon: "iphone",
                placeholder: L10n.t("手机号", "Phone number"),
                text: $viewModel.phone,
                error: viewModel.fieldErrors["phone"]
            )
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

            HStack(alignment: .top, spacing: 10) {
                AuthTextInput(
                    icon: "number",
                    placeholder: L10n.t("验证码", "Code"),
                    text: $viewModel.phoneCode,
                    error: viewModel.fieldErrors["phoneCode"]
                )
                .keyboardType(.numberPad)

                Button {
                    viewModel.requestPhoneCode()
                } label: {
                    Group {
                        if viewModel.isRequestingPhoneCode {
                            ProgressView()
                                .tint(Color.rcmsAccent)
                        } else {
                            Text(phoneCodeButtonTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }
                    .frame(width: 108, height: 48)
                    .foregroundStyle(viewModel.canRequestPhoneCode ? Color.rcmsAccent : Color.rcmsTextSecondary)
                    .background(Color.rcmsFieldSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.rcmsHairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRequestPhoneCode)
            }

            if let error = viewModel.errorMessage {
                AuthErrorBanner(message: error)
            }

            Button(action: viewModel.phoneLogin) {
                AuthPrimaryButtonLabel(title: L10n.t("登录 / 注册", "Log in / Register"), isLoading: viewModel.isLoading)
            }
            .disabled(viewModel.isLoading)
        }
    }

    private var phoneCodeButtonTitle: String {
        if viewModel.phoneCodeCooldown > 0 {
            return "\(viewModel.phoneCodeCooldown)s"
        }
        return L10n.t("获取验证码", "Get code")
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

    private var loginModeLink: some View {
        VStack(spacing: 10) {
            if usesPhoneAuth {
                Button {
                    usesPhoneAuth = false
                    viewModel.cancelPhoneCodeRequest()
                    viewModel.errorMessage = nil
                    viewModel.fieldErrors = [:]
                } label: {
                    Text(L10n.t("使用邮箱或用户名登录", "Use email or username"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.rcmsAccent)
                }
            } else {
                if viewModel.supportsPhoneAuth {
                    Button {
                        usesPhoneAuth = true
                        viewModel.errorMessage = nil
                        viewModel.fieldErrors = [:]
                    } label: {
                        Text(L10n.t("使用手机号验证码登录", "Use phone code"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.rcmsAccent)
                    }
                }
                registerLink
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
        GeometryReader { geometry in
            ZStack {
                FrostedBackground()

                if usesWideLayout && geometry.size.width >= 1000 {
                    wideBody
                } else {
                    compactBody
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                }
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
            .frame(maxWidth: 430)
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
