import Combine
import Foundation
import Testing
@testable import clawchat

@MainActor
struct PhoneCaptchaTests {
    @Test func unauthenticatedCodeRejectionPreservesTheServerReasonInBothTransports() async throws {
        let endpoint = URL(string: "https://phone-auth-test.invalid")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneRejectionProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let api = APIClient(session: transport, baseURL: endpoint, remoteDataSession: transport,
                            accountSession: AccountSession(endpoint: endpoint, userID: nil))
        do {
            for try await _ in api.phoneLogin(phone: "13800138000", code: "000000").values {
                Issue.record("An invalid code unexpectedly authenticated")
            }
            Issue.record("Expected a rejected phone code")
        } catch {
            #expect(error.localizedDescription == "invalid or expired verification code")
            if case APIClient.APIError.unauthorized = error {
                Issue.record("An unsigned login rejection is not an expired account session")
            }
        }
        do {
            let _: [String: String] = try await api.requestValue("/api/v1/auth/phone/login", requiresAuth: false)
            Issue.record("Expected a rejected phone code")
        } catch {
            #expect(error.localizedDescription == "invalid or expired verification code")
        }
    }

    @Test func verifiesOnceAndForwardsTokenWithoutReusingIt() async throws {
        let api = PhoneAPIStub()
        let model = AuthViewModel(phoneAPI: api)
        model.phone = "13800138000"
        model.requestPhoneCode(); model.requestPhoneCode()
        try await wait { model.phoneChallenge != nil }
        #expect(api.configRequests == 1)
        #expect(api.sent.isEmpty)
        let challenge = try #require(model.phoneChallenge)
        model.completePhoneChallenge(challenge.id, result: .success("verified-token"))
        model.completePhoneChallenge(challenge.id, result: .success("duplicate-token"))
        model.cancelPhoneChallenge() // Automatic sheet dismissal after successful verification.
        try await wait { model.phoneCodeCooldown > 0 }
        #expect(api.sent.count == 1)
        #expect(api.sent.first?.phone == "13800138000")
        #expect(api.sent.first?.token == "verified-token")
        #expect(!model.isRequestingPhoneCode)
        #expect(!model.canRequestPhoneCode)
        #expect(model.phoneChallenge == nil)
    }

    @Test func cancelledAndExpiredChallengesDoNotSendAndCanRetry() async throws {
        let api = PhoneAPIStub()
        let model = AuthViewModel(phoneAPI: api)
        model.phone = "13800138000"
        model.requestPhoneCode()
        try await wait { model.phoneChallenge != nil }
        let first = try #require(model.phoneChallenge)
        model.cancelPhoneChallenge()
        model.completePhoneChallenge(first.id, result: .success("late-token"))
        #expect(api.sent.isEmpty)
        #expect(model.canRequestPhoneCode)
        model.requestPhoneCode()
        try await wait { model.phoneChallenge != nil }
        let second = try #require(model.phoneChallenge)
        #expect(second.id != first.id)
        model.completePhoneChallenge(first.id, result: .failure(.expired))
        #expect(model.phoneChallenge?.id == second.id)
        model.completePhoneChallenge(second.id, result: .failure(.expired))
        #expect(model.errorMessage != nil)
        #expect(model.canRequestPhoneCode)
        #expect(model.phoneCodeCooldown == 0)
        #expect(api.sent.isEmpty)
    }

    @Test func changedPhoneCannotConsumeAnotherPhonesChallenge() async throws {
        let api = PhoneAPIStub()
        let model = AuthViewModel(phoneAPI: api)
        model.phone = "13800138000"
        model.requestPhoneCode()
        try await wait { model.phoneChallenge != nil }
        let challenge = try #require(model.phoneChallenge)
        model.phone = "13900139000"
        model.completePhoneChallenge(challenge.id, result: .success("verified-token"))
        #expect(api.sent.isEmpty)
        #expect(model.canRequestPhoneCode)
        #expect(model.errorMessage != nil)
    }

    @Test func providerFailureDoesNotStartCooldownAndRequiresFreshVerification() async throws {
        let api = PhoneAPIStub()
        api.sendError = URLError(.notConnectedToInternet)
        let model = AuthViewModel(phoneAPI: api)
        model.phone = "13800138000"
        model.requestPhoneCode()
        try await wait { model.phoneChallenge != nil }
        let first = try #require(model.phoneChallenge)
        model.completePhoneChallenge(first.id, result: .success("token-one"))
        try await wait { model.errorMessage != nil }
        #expect(model.phoneCodeCooldown == 0)
        #expect(model.canRequestPhoneCode)
        api.sendError = nil
        model.requestPhoneCode()
        try await wait { model.phoneChallenge != nil }
        let second = try #require(model.phoneChallenge)
        #expect(second.id != first.id)
        model.completePhoneChallenge(second.id, result: .success("token-two"))
        try await wait { model.phoneCodeCooldown > 0 }
        #expect(api.sent.map(\.token) == ["token-one", "token-two"])
    }

    @Test func mockIsOnlyAcceptedFromAnExplicitLocalConfiguration() async throws {
        for endpoint in ["https://service.invalid", "http://127.0.0.1:23000"] {
            let api = PhoneAPIStub(baseURL: URL(string: endpoint)!)
            api.configuration = PhoneAuthConfiguration(enabled: true, captchaProvider: "mock")
            let model = AuthViewModel(phoneAPI: api)
            model.phone = "13800138000"
            model.requestPhoneCode()
            try await wait { !model.isRequestingPhoneCode }
            #expect(api.sent.count == (endpoint.contains("127.0.0.1") ? 1 : 0))
            #expect(model.phoneChallenge == nil)
        }
    }

    @Test func disabledOrUnknownProvidersNeverSend() async throws {
        for config in [PhoneAuthConfiguration(enabled: false, captchaProvider: "turnstile"), PhoneAuthConfiguration(enabled: true, captchaProvider: "unknown")] {
            let api = PhoneAPIStub(); api.configuration = config
            let model = AuthViewModel(phoneAPI: api); model.phone = "13800138000"
            model.requestPhoneCode()
            try await wait { !model.isRequestingPhoneCode }
            #expect(api.sent.isEmpty)
            #expect(model.phoneChallenge == nil)
            #expect(model.errorMessage != nil)
        }
    }

    @Test func bridgeOnlyAcceptsItsOwnMainFrameAndSecureOrigin() throws {
        let challenge = PhoneCaptchaChallenge(id: UUID(), url: try #require(PhoneCaptchaChallenge.url(baseURL: URL(string: "https://service.invalid")!)))
        #expect(challenge.acceptsMessage(from: challenge.url, isMainFrame: true))
        #expect(!challenge.acceptsMessage(from: challenge.url, isMainFrame: false))
        for foreign in ["https://service.invalid:444/api/v1/auth/phone/challenge", "https://other.invalid/api/v1/auth/phone/challenge", "https://service.invalid/other", "http://service.invalid/api/v1/auth/phone/challenge"] {
            #expect(!challenge.acceptsMessage(from: URL(string: foreign), isMainFrame: true))
        }
        #expect(PhoneCaptchaChallenge.url(baseURL: URL(string: "http://service.invalid")!) == nil)
        #expect(PhoneCaptchaChallenge.url(baseURL: URL(string: "https://user:password@service.invalid")!) == nil)
        #expect(PhoneCaptchaChallenge.url(baseURL: URL(string: "file:///tmp")!) == nil)
        #expect(PhoneCaptchaChallenge.url(baseURL: URL(string: "http://127.0.0.1:23000")!) != nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Phone verification did not reach the expected state")
    }
}

private final class PhoneRejectionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "phone-auth-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":401,"message":"invalid or expired verification code","data":null}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class PhoneAPIStub: PhoneAuthenticationAPI {
    let baseURL: URL
    var configuration = PhoneAuthConfiguration(enabled: true, captchaProvider: "turnstile")
    var configRequests = 0
    var sent: [(phone: String, token: String)] = []
    var sendError: Error?
    init(baseURL: URL = URL(string: "https://service.invalid")!) { self.baseURL = baseURL }
    func fetchPhoneConfiguration() -> AnyPublisher<PhoneAuthConfiguration, Error> {
        configRequests += 1
        return Just(configuration).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
    func requestPhoneCode(phone: String, captchaToken: String, purpose: String) -> AnyPublisher<PhoneCodeResponse, Error> {
        sent.append((phone, captchaToken))
        if let sendError { return Fail(error: sendError).eraseToAnyPublisher() }
        return Just(PhoneCodeResponse(cooldownSeconds: 60)).setFailureType(to: Error.self).eraseToAnyPublisher()
    }
}
