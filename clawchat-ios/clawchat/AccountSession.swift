import Foundation

/// A login lifetime, independent of access-token renewal. No credentials are retained here.
final class AccountSession: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let generation: UUID
        let endpoint: URL
        let userID: UUID?

        var cacheIdentifier: String {
            ServiceEndpointConfiguration.storageIdentifier(for: endpoint) + "/accounts/" + (userID?.uuidString.lowercased() ?? "anonymous")
        }
    }

    static let shared: AccountSession = {
        let defaults = UserDefaults.standard
        let cached = defaults.data(forKey: "current_user")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let userID = defaults.string(forKey: "access_token") == nil ? nil : (cached?["id"] as? String).flatMap(UUID.init(uuidString:))
        return AccountSession(endpoint: ServiceEndpointConfiguration.currentBaseURL, userID: userID)
    }()

    private let lock = NSLock()
    private var value: Snapshot

    init(endpoint: URL, userID: UUID?) {
        value = Snapshot(generation: UUID(), endpoint: endpoint, userID: userID)
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == snapshot
    }

    @discardableResult
    func activate(endpoint: URL, userID: UUID?, force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard force || value.endpoint != endpoint || value.userID != userID else { return false }
        value = Snapshot(generation: UUID(), endpoint: endpoint, userID: userID)
        return true
    }
}
