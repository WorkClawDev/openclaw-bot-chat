import Foundation
import Combine
import Testing
@testable import clawchat

@MainActor
struct AccountIsolationTests {
    @Test func loginLifetimeChangesButSameAccountKeepsItsDiskNamespace() {
        let endpoint = URL(string: "http://localhost:23000")!
        let a = UUID(), b = UUID()
        let session = AccountSession(endpoint: endpoint, userID: a)
        let first = session.snapshot
        #expect(!session.activate(endpoint: endpoint, userID: a))
        #expect(session.isCurrent(first))
        session.activate(endpoint: endpoint, userID: nil)
        #expect(!session.isCurrent(first))
        session.activate(endpoint: endpoint, userID: b)
        #expect(session.snapshot.cacheIdentifier != first.cacheIdentifier)
        session.activate(endpoint: endpoint, userID: a)
        #expect(session.snapshot.cacheIdentifier == first.cacheIdentifier)
        #expect(!session.isCurrent(first))
        session.activate(endpoint: URL(string: "http://localhost:23001")!, userID: a)
        #expect(session.snapshot.cacheIdentifier != first.cacheIdentifier)
    }

    @Test func diskCachesAndQueuedWritesStayWithTheirOriginalAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "http://localhost:23000")!, a = UUID(), b = UUID(), groupID = UUID()
        let session = AccountSession(endpoint: endpoint, userID: a)
        let aScope = session.snapshot
        let aStore = LocalMessageStore(scope: aScope, rootDirectory: root)
        let group = ChatGroup(id: groupID, name: "Account A only", description: nil, avatar: nil, avatarUrl: nil, ownerId: a, memberCount: 1, isActive: true, mqttTopic: "chat/group/\(groupID)", createdAt: nil, updatedAt: nil)
        aStore.upsert(groups: [group])
        let message = Self.message("account-a-message")
        aStore.upsert(messages: [message])
        aStore.syncConversationPreview(for: message, currentUserID: a.uuidString, isActiveConversation: false)
        #expect(aStore.cachedGroups().map(\.id) == [groupID])
        #expect(aStore.recentMessages(conversationId: message.conversationId, limit: 10).count == 1)
        session.activate(endpoint: endpoint, userID: b)
        let bStore = LocalMessageStore(scope: session.snapshot, rootDirectory: root)
        // A's captured store can finish queued work without ever writing to B.
        aStore.upsert(messages: [Self.message("account-a-late")])
        #expect(aStore.recentMessages(conversationId: message.conversationId, limit: 10).count == 2)
        #expect(bStore.cachedGroups().isEmpty && bStore.cachedConversations().isEmpty)
        #expect(bStore.recentMessages(conversationId: message.conversationId, limit: 10).isEmpty)
        session.activate(endpoint: endpoint, userID: a)
        let reopened = LocalMessageStore(scope: session.snapshot, rootDirectory: root)
        #expect(reopened.cachedGroups().map(\.id) == [groupID])
        #expect(reopened.recentMessages(conversationId: message.conversationId, limit: 10).count == 2)
        #expect(reopened.cachedConversations().count == 1)
    }

    @Test func imageCachesAreSeparatedByAccountAndServer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "http://localhost:23000")!
        let a = UUID(), b = UUID()
        let aScope = AccountSession(endpoint: endpoint, userID: a).snapshot
        let aStore = LocalImageStore(scope: aScope, rootDirectory: root)
        let bStore = LocalImageStore(scope: AccountSession(endpoint: endpoint, userID: b).snapshot, rootDirectory: root)
        let otherServer = LocalImageStore(scope: AccountSession(endpoint: URL(string: "http://localhost:23001")!, userID: a).snapshot, rootDirectory: root)
        let content = MessageContent(type: "image", body: nil, url: "https://example.invalid/private.png", name: "private.png", size: 3, meta: nil)
        let bytes = Data([1, 2, 3])
        let stored = try #require(aStore.cacheImageData(bytes, for: content))
        #expect(try Data(contentsOf: stored) == bytes)
        #expect(bStore.cachedFileURL(for: content) == nil)
        #expect(otherServer.cachedFileURL(for: content) == nil)
        let reopened = LocalImageStore(scope: aScope, rootDirectory: root)
        #expect(reopened.cachedFileURL(for: content) == stored)
    }

    @Test func unownedLegacyDatabaseIsNeverHydrated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = URL(string: "http://localhost:23000")!
        let oldDirectory = root.appendingPathComponent("clawchat/endpoints/" + ServiceEndpointConfiguration.storageIdentifier(for: endpoint))
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let legacy = oldDirectory.appendingPathComponent("messages.sqlite")
        let sentinel = Data("unowned legacy data retained".utf8)
        try sentinel.write(to: legacy)
        let scope = AccountSession(endpoint: endpoint, userID: UUID()).snapshot
        let store = LocalMessageStore(scope: scope, rootDirectory: root)
        #expect(store.cachedGroups().isEmpty && store.cachedConversations().isEmpty)
        #expect(try Data(contentsOf: legacy) == sentinel)
        let anonymous = LocalMessageStore(scope: AccountSession(endpoint: endpoint, userID: nil).snapshot, rootDirectory: root)
        #expect(anonymous.recentMessages(conversationId: "private", limit: 10).isEmpty)
    }

    @Test func lateHTTPResponseIsRejectedBeforeSuccessOrUnauthorizedHandling() async throws {
        for status in [200, 401] {
            let path = "/" + UUID().uuidString
            let endpoint = URL(string: "https://account-isolation.invalid")!
            let state = AccountSession(endpoint: endpoint, userID: UUID())
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AccountGateProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let api = APIClient(session: transport, baseURL: endpoint, remoteDataSession: transport, accountSession: state)
            let task = Task { () -> Bool in
                do {
                    let _: [String: String] = try await api.requestValue(path, requiresAuth: true)
                    return false
                } catch is CancellationError { return true }
                catch { return false }
            }
            try await Self.waitForRequest(path)
            state.activate(endpoint: endpoint, userID: UUID())
            AccountGateProtocol.release(path, status: status)
            #expect(await task.value)
            #expect(AccountGateProtocol.requestCount(path) == 1)
        }
    }

    @Test func uploadCompletionIsRejectedAfterAccountSwitch() async throws {
        let path = "/" + UUID().uuidString
        let endpoint = URL(string: "https://account-isolation.invalid")!
        let state = AccountSession(endpoint: endpoint, userID: UUID())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountGateProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let api = APIClient(session: transport, baseURL: endpoint, remoteDataSession: transport, accountSession: state)
        let upload = PresignedUpload(method: "PUT", url: endpoint.absoluteString + path, headers: nil, expiresAt: Date().addingTimeInterval(60))
        let task = Task { () -> Bool in
            do { try await api.uploadImageData(Data([1, 2, 3]), with: upload); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        try await Self.waitForRequest(path)
        state.activate(endpoint: endpoint, userID: UUID())
        AccountGateProtocol.release(path, status: 200)
        #expect(await task.value)
        // The old client must also reject an upload before starting transport.
        do { try await api.uploadImageData(Data([1]), with: upload); Issue.record("An obsolete upload client was accepted") }
        catch { #expect(error is CancellationError) }
        #expect(AccountGateProtocol.requestCount(path) == 1)
    }

    @Test func lateCombineResponseIsRejectedAfterAccountSwitch() async throws {
        let path = "/" + UUID().uuidString
        let endpoint = URL(string: "https://account-isolation.invalid")!
        let state = AccountSession(endpoint: endpoint, userID: UUID())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountGateProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let api = APIClient(session: transport, baseURL: endpoint, remoteDataSession: transport, accountSession: state)
        var received = false, cancelled = false
        let publisher: AnyPublisher<[String: String], Error> = api.request(path, requiresAuth: false)
        let subscription = publisher.sink { completion in
            if case .failure(let error) = completion { cancelled = error is CancellationError }
        } receiveValue: { _ in received = true }
        defer { subscription.cancel() }
        try await Self.waitForRequest(path)
        state.activate(endpoint: endpoint, userID: UUID())
        AccountGateProtocol.release(path, status: 200)
        for _ in 0..<100 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled && !received)
    }

    private static func waitForRequest(_ path: String) async throws {
        for _ in 0..<100 {
            if AccountGateProtocol.isWaiting(path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(AccountGateProtocol.isWaiting(path), "The test must actually hold a request in flight")
    }

    static func message(_ id: String) -> Message {
        Message(from: RealtimeMessagePayload(id: id, topic: "chat/group/private", conversationId: "chat/group/private", timestamp: 1_800_000_000, from: MessagePeerPayload(type: "user", id: "a"), to: MessagePeerPayload(type: "group", id: "private"), content: RealtimeContentPayload(type: "text", body: id), seq: 1))
    }
}

private final class AccountGateProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var pending: [String: AccountGateProtocol] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "account-isolation.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.pending[path] = self
        Self.counts[path, default: 0] += 1
    }
    override func stopLoading() {}
    static func isWaiting(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pending[path] != nil
    }
    static func requestCount(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path, default: 0]
    }
    static func release(_ path: String, status: Int) {
        lock.lock(); let handler = pending.removeValue(forKey: path); lock.unlock()
        guard let handler, let url = handler.request.url else { return }
        handler.client?.urlProtocol(handler, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        handler.client?.urlProtocol(handler, didLoad: Data(#"{"code":0,"message":"ok","data":{"private":"account A"}}"#.utf8))
        handler.client?.urlProtocolDidFinishLoading(handler)
    }
}
