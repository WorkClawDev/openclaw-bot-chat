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
            fieldErrors["identifier"] = "Username or email is required"
            isValid = false
        }
        
        if password.isEmpty {
            fieldErrors["password"] = "Password is required"
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
            fieldErrors["username"] = "Username is required"
            isValid = false
        } else if username.count < 3 {
            fieldErrors["username"] = "Username must be at least 3 characters"
            isValid = false
        }
        
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fieldErrors["email"] = "Email is required"
            isValid = false
        } else if !email.contains("@") {
            fieldErrors["email"] = "Invalid email format"
            isValid = false
        }
        
        if password.isEmpty {
            fieldErrors["password"] = "Password is required"
            isValid = false
        } else if password.count < 8 {
            fieldErrors["password"] = "Password must be at least 8 characters"
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

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                ScrollView {
                    VStack(spacing: 26) {
                        VStack(spacing: 18) {
                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: Color.black.opacity(0.08), radius: 14, y: 8)
                                .padding(.top, 28)

                            VStack(spacing: 8) {
                                Text("Welcome back")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.rcmsTextStrong)

                                Text("Sign in to ClawChat")
                                    .font(.body)
                                    .foregroundStyle(Color.rcmsTextSecondary)
                                    .multilineTextAlignment(.center)
                            }
                        }

                        VStack(spacing: 18) {
                            AuthTextInput(
                                icon: "envelope",
                                placeholder: "Email or username",
                                text: $viewModel.identifier,
                                error: viewModel.fieldErrors["identifier"]
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                            AuthSecureInput(
                                icon: "lock",
                                placeholder: "Password",
                                text: $viewModel.password,
                                error: viewModel.fieldErrors["password"]
                            )

                            if let error = viewModel.errorMessage {
                                AuthErrorBanner(message: error)
                            }

                            Button(action: viewModel.login) {
                                AuthPrimaryButtonLabel(title: "Login", isLoading: viewModel.isLoading)
                            }
                            .disabled(viewModel.isLoading)
                        }
                        .padding(.horizontal, 20)

                        Button {
                            isRegistering = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Don't have an account?")
                                    .foregroundStyle(Color.rcmsTextSecondary)
                                Text("Create account")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.rcmsAccent)
                            }
                            .font(.subheadline)
                        }

                        Rectangle()
                            .fill(Color.rcmsDivider)
                            .frame(height: 1)
                            .padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 16) {
                            CapabilityRow(icon: "antenna.radiowaves.left.and.right", text: "MQTT realtime")
                            CapabilityRow(icon: "shield.checkered", text: "Secure auth")
                            CapabilityRow(icon: "message.badge", text: "Connect bots, groups, and message history")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(Color.rcmsControlSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.rcmsHairline, lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isRegistering) {
                RegisterView()
            }
        }
    }
}

struct RegisterView: View {
    @StateObject private var viewModel = AuthViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FrostedBackground()

            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 18) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: Color.black.opacity(0.08), radius: 14, y: 8)
                            .padding(.top, 28)

                        VStack(spacing: 8) {
                            Text("Create account")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.rcmsTextStrong)
                            Text("Start chatting with bots and teams")
                                .font(.body)
                                .foregroundStyle(Color.rcmsTextSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    VStack(spacing: 18) {
                        AuthTextInput(
                            icon: "person",
                            placeholder: "Username",
                            text: $viewModel.username,
                            error: viewModel.fieldErrors["username"]
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                        AuthTextInput(
                            icon: "envelope",
                            placeholder: "Email",
                            text: $viewModel.email,
                            error: viewModel.fieldErrors["email"]
                        )
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                        AuthSecureInput(
                            icon: "lock",
                            placeholder: "Password",
                            text: $viewModel.password,
                            error: viewModel.fieldErrors["password"]
                        )

                        PasswordRequirementRow(text: "At least 8 characters", isMet: viewModel.password.count >= 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)

                        if let error = viewModel.errorMessage {
                            AuthErrorBanner(message: error)
                        }

                        Button(action: viewModel.register) {
                            AuthPrimaryButtonLabel(title: "Register", isLoading: viewModel.isLoading)
                        }
                        .disabled(viewModel.isLoading)
                    }
                    .padding(.horizontal, 20)
                    
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Already have an account?")
                                .foregroundStyle(Color.rcmsTextSecondary)
                            Text("Sign in")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.rcmsAccent)
                        }
                        .font(.subheadline)
                    }

                    Rectangle()
                        .fill(Color.rcmsDivider)
                        .frame(height: 1)
                        .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 16) {
                        CapabilityRow(icon: "cpu", text: "Bot single chat")
                        CapabilityRow(icon: "person.3", text: "Group conversations")
                        CapabilityRow(icon: "clock", text: "Realtime history")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color.rcmsControlSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.rcmsHairline, lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AuthTextInput: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(error == nil ? Color.rcmsAccent : Color.rcmsDanger)
                    .frame(width: 22)

                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.rcmsTextPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.rcmsFieldSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(error == nil ? Color.rcmsHairline : Color.rcmsDanger.opacity(0.55), lineWidth: 1)
            )

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.rcmsDanger)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct AuthSecureInput: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(error == nil ? Color.rcmsAccent : Color.rcmsDanger)
                    .frame(width: 22)

                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.rcmsTextPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.rcmsFieldSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(error == nil ? Color.rcmsHairline : Color.rcmsDanger.opacity(0.55), lineWidth: 1)
            )

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.rcmsDanger)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct AuthPrimaryButtonLabel: View {
    let title: String
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(.white)
            } else {
                Text(title)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(Color.rcmsAccent)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.rcmsAccent.opacity(0.26), radius: 10, y: 5)
    }
}

private struct AuthErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .padding(.top, 1)
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(Color.rcmsDanger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.rcmsDanger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PasswordRequirementRow: View {
    let text: String
    let isMet: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isMet ? Color.rcmsOnline : Color.rcmsTextSecondary.opacity(0.55))
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.rcmsTextSecondary)
        }
    }
}

private struct CapabilityRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.rcmsOnline)

            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.rcmsTextSecondary)
                .frame(width: 28)

            Text(text)
                .font(.body)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
    }
}

struct AuthView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LoginView()
                .previewDisplayName("Login")
            RegisterView()
                .previewDisplayName("Register")
        }
        .preferredColorScheme(.light)
    }
}
