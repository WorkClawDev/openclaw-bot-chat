import Foundation
import SQLite3

final class LocalMessageStore {
    static let shared = LocalMessageStore()
    static let conversationsDidChangeNotification = Notification.Name("LocalMessageStoreConversationsDidChange")

    private let queue = DispatchQueue(label: "site.changer.clawchat.local-message-store")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var database: OpaquePointer?

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        queue.sync {
            openDatabaseIfNeeded()
            createTablesIfNeeded()
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func recentMessages(conversationId: String, limit: Int) -> [Message] {
        queue.sync {
            recentMessagesLocked(conversationId: conversationId, limit: limit)
        }
    }

    func recentMessagesAsync(conversationId: String, limit: Int) async -> [Message] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.recentMessagesLocked(
                    conversationId: conversationId,
                    limit: limit
                ))
            }
        }
    }

    func messagesBefore(conversationId: String, beforeSequence: Int, limit: Int) -> [Message] {
        guard beforeSequence > 0 else { return [] }

        return queue.sync {
            messagesBeforeLocked(
                conversationId: conversationId,
                beforeSequence: beforeSequence,
                limit: limit
            )
        }
    }

    func messagesBeforeAsync(conversationId: String, beforeSequence: Int, limit: Int) async -> [Message] {
        guard beforeSequence > 0 else { return [] }

        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.messagesBeforeLocked(
                    conversationId: conversationId,
                    beforeSequence: beforeSequence,
                    limit: limit
                ))
            }
        }
    }

    private func recentMessagesLocked(conversationId: String, limit: Int) -> [Message] {
        loadMessages(
            sql: """
            SELECT payload_json
            FROM cached_messages
            WHERE conversation_id = ?
            ORDER BY COALESCE(created_at, 0) DESC,
                     COALESCE(timestamp, 0) DESC,
                     COALESCE(seq, -1) DESC,
                     id DESC
            LIMIT ?
            """,
            bind: { statement in
                bind(text: conversationId, to: 1, in: statement)
                sqlite3_bind_int(statement, 2, Int32(normalizedLimit(limit)))
            },
            reverseResults: true
        )
    }

    private func messagesBeforeLocked(conversationId: String, beforeSequence: Int, limit: Int) -> [Message] {
        loadMessages(
            sql: """
            SELECT payload_json
            FROM cached_messages
            WHERE conversation_id = ?
              AND seq IS NOT NULL
              AND seq < ?
            ORDER BY seq DESC
            LIMIT ?
            """,
            bind: { statement in
                bind(text: conversationId, to: 1, in: statement)
                sqlite3_bind_int64(statement, 2, sqlite3_int64(beforeSequence))
                sqlite3_bind_int(statement, 3, Int32(normalizedLimit(limit)))
            },
            reverseResults: true
        )
    }

    func highestSequence(conversationId: String) -> Int? {
        queue.sync {
            highestSequenceLocked(conversationId: conversationId)
        }
    }

    func highestSequenceAsync(conversationId: String) async -> Int? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.highestSequenceLocked(conversationId: conversationId))
            }
        }
    }

    func cachedConversations(limit: Int = 200) -> [Conversation] {
        queue.sync {
            loadConversations(
                sql: """
                SELECT payload_json
                FROM cached_conversations
                ORDER BY COALESCE(last_message_timestamp, 0) DESC,
                         updated_at DESC,
                         id DESC
                LIMIT ?
                """,
                bind: { statement in
                    sqlite3_bind_int(statement, 1, Int32(normalizedLimit(limit)))
                }
            )
        }
    }

    func cachedBots(limit: Int = 200) -> [Bot] {
        queue.sync {
            cachedBotsLocked(limit: limit)
        }
    }

    func cachedBotsAsync(limit: Int = 200) async -> [Bot] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.cachedBotsLocked(limit: limit))
            }
        }
    }

    func cachedGroups(limit: Int = 200) -> [ChatGroup] {
        queue.sync {
            loadGroups(
                sql: """
                SELECT payload_json
                FROM cached_groups
                ORDER BY name COLLATE NOCASE ASC,
                         updated_at DESC,
                         id DESC
                LIMIT ?
                """,
                bind: { statement in
                    sqlite3_bind_int(statement, 1, Int32(normalizedLimit(limit)))
                }
            )
        }
    }

    func upsert(messages: [Message]) {
        guard !messages.isEmpty else { return }

        queue.async {
            self.upsertMessagesLocked(messages)
        }
    }

    func upsert(conversations: [Conversation]) {
        queue.async {
            self.upsertConversationsLocked(conversations)
            self.pruneCachedConversationsLocked(keeping: conversations.map(\.id))
            self.notifyConversationChanges()
        }
    }

    func upsert(bots: [Bot]) {
        queue.async {
            self.upsertBotsLocked(bots)
        }
    }

    func upsert(groups: [ChatGroup]) {
        queue.async {
            self.upsertGroupsLocked(groups)
        }
    }

    func syncConversationPreview(for message: Message, currentUserID: String?, isActiveConversation: Bool) {
        queue.async {
            self.applyRealtimeConversationUpdateLocked(
                for: message,
                currentUserID: currentUserID,
                isActiveConversation: isActiveConversation
            )
            self.notifyConversationChanges()
        }
    }

    func markConversationRead(conversationId: String) {
        queue.async {
            guard var conversation = self.cachedConversationLocked(id: conversationId) else {
                return
            }
            conversation.unreadCount = 0
            self.writeConversationLocked(conversation, lastMessageSeq: nil)
            self.notifyConversationChanges()
        }
    }

    func resetForCurrentServiceEndpoint() {
        queue.sync {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
            openDatabaseIfNeeded()
            createTablesIfNeeded()
            notifyConversationChanges()
        }
    }

    private func highestSequenceLocked(conversationId: String) -> Int? {
        guard let statement = prepareStatement(
            sql: "SELECT MAX(seq) FROM cached_messages WHERE conversation_id = ?"
        ) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        bind(text: conversationId, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func cachedBotsLocked(limit: Int) -> [Bot] {
        loadBots(
            sql: """
            SELECT payload_json
            FROM cached_bots
            ORDER BY name COLLATE NOCASE ASC,
                     updated_at DESC,
                     id DESC
            LIMIT ?
            """,
            bind: { statement in
                sqlite3_bind_int(statement, 1, Int32(normalizedLimit(limit)))
            }
        )
    }

    private func openDatabaseIfNeeded() {
        guard database == nil else { return }

        let databaseURL = databaseFileURL()
        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            let message = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            print("Failed to open local message database: \(message)")
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
        }
    }

    private func createTablesIfNeeded() {
        guard let database else { return }

        let schema = """
        CREATE TABLE IF NOT EXISTS cached_messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            seq INTEGER,
            timestamp INTEGER,
            created_at REAL,
            payload_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cached_messages_conversation_seq
            ON cached_messages (conversation_id, seq DESC, timestamp DESC, created_at DESC);

        CREATE TABLE IF NOT EXISTS cached_conversations (
            id TEXT PRIMARY KEY,
            type TEXT,
            name TEXT,
            avatar TEXT,
            target_id TEXT,
            last_message_content TEXT,
            last_message_timestamp INTEGER,
            last_message_seq INTEGER,
            unread_count INTEGER NOT NULL DEFAULT 0,
            payload_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cached_conversations_last_message
            ON cached_conversations (last_message_timestamp DESC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS cached_bots (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            status TEXT,
            payload_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cached_bots_name
            ON cached_bots (name COLLATE NOCASE ASC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS cached_groups (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cached_groups_name
            ON cached_groups (name COLLATE NOCASE ASC, updated_at DESC);
        """

        if sqlite3_exec(database, schema, nil, nil, nil) != SQLITE_OK {
            print("Failed to create local cache tables: \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    private func upsertMessagesLocked(_ messages: [Message]) {
        guard let database else { return }
        guard let statement = prepareStatement(
            sql: """
            INSERT INTO cached_messages (
                id,
                conversation_id,
                seq,
                timestamp,
                created_at,
                payload_json,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversation_id = excluded.conversation_id,
                seq = excluded.seq,
                timestamp = excluded.timestamp,
                created_at = excluded.created_at,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        let now = Date().timeIntervalSince1970

        for message in messages {
            guard let payload = encode(message: message) else { continue }

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            bind(text: message.id, to: 1, in: statement)
            bind(text: message.conversationId, to: 2, in: statement)

            if let seq = message.seq {
                sqlite3_bind_int64(statement, 3, sqlite3_int64(seq))
            } else {
                sqlite3_bind_null(statement, 3)
            }

            if let timestamp = message.timestamp {
                sqlite3_bind_int64(statement, 4, sqlite3_int64(timestamp))
            } else {
                sqlite3_bind_null(statement, 4)
            }

            if let createdAt = message.createdAt?.timeIntervalSince1970 {
                sqlite3_bind_double(statement, 5, createdAt)
            } else {
                sqlite3_bind_null(statement, 5)
            }

            bind(text: payload, to: 6, in: statement)
            sqlite3_bind_double(statement, 7, now)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to cache message \(message.id): \(String(cString: sqlite3_errmsg(database)))")
            }

            updateConversationPreviewLocked(
                for: message,
                currentUserID: nil,
                isActiveConversation: false,
                adjustUnreadCount: false
            )
        }

        sqlite3_exec(database, "COMMIT", nil, nil, nil)
        notifyConversationChanges()
    }

    private func upsertConversationsLocked(_ conversations: [Conversation]) {
        for conversation in conversations {
            let merged = mergeConversation(existing: cachedConversationLocked(id: conversation.id), remote: conversation)
            writeConversationLocked(merged, lastMessageSeq: nil)
        }
    }

    private func pruneCachedConversationsLocked(keeping conversationIDs: [String]) {
        guard let database else { return }

        let uniqueIDs = Array(Set(conversationIDs))
        if uniqueIDs.isEmpty {
            sqlite3_exec(database, "DELETE FROM cached_conversations", nil, nil, nil)
            return
        }

        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
        guard let statement = prepareStatement(
            sql: "DELETE FROM cached_conversations WHERE id NOT IN (\(placeholders))"
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }

        for (index, conversationID) in uniqueIDs.enumerated() {
            bind(text: conversationID, to: Int32(index + 1), in: statement)
        }
        if sqlite3_step(statement) != SQLITE_DONE {
            print("Failed to prune cached conversations: \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    private func upsertBotsLocked(_ bots: [Bot]) {
        guard let database else { return }
        guard let statement = prepareStatement(
            sql: """
            INSERT INTO cached_bots (
                id,
                name,
                status,
                payload_json,
                updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                status = excluded.status,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        let now = Date().timeIntervalSince1970

        if bots.isEmpty {
            sqlite3_exec(database, "DELETE FROM cached_bots", nil, nil, nil)
            sqlite3_exec(database, "COMMIT", nil, nil, nil)
            return
        }

        for bot in bots {
            guard let payload = encode(bot: bot) else { continue }

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            bind(text: bot.id.uuidString.lowercased(), to: 1, in: statement)
            bind(text: bot.name, to: 2, in: statement)
            bind(optionalText: bot.status, to: 3, in: statement)
            bind(text: payload, to: 4, in: statement)
            sqlite3_bind_double(statement, 5, now)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to cache bot \(bot.id): \(String(cString: sqlite3_errmsg(database)))")
            }
        }

        deleteRowsMissingFromSnapshotLocked(
            tableName: "cached_bots",
            ids: bots.map { $0.id.uuidString.lowercased() }
        )
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
    }

    private func upsertGroupsLocked(_ groups: [ChatGroup]) {
        guard let database else { return }
        guard let statement = prepareStatement(
            sql: """
            INSERT INTO cached_groups (
                id,
                name,
                payload_json,
                updated_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil)
        let now = Date().timeIntervalSince1970

        if groups.isEmpty {
            sqlite3_exec(database, "DELETE FROM cached_groups", nil, nil, nil)
            sqlite3_exec(database, "COMMIT", nil, nil, nil)
            return
        }

        for group in groups {
            guard let payload = encode(group: group) else { continue }

            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            bind(text: group.id.uuidString.lowercased(), to: 1, in: statement)
            bind(text: group.name, to: 2, in: statement)
            bind(text: payload, to: 3, in: statement)
            sqlite3_bind_double(statement, 4, now)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to cache group \(group.id): \(String(cString: sqlite3_errmsg(database)))")
            }
        }

        deleteRowsMissingFromSnapshotLocked(
            tableName: "cached_groups",
            ids: groups.map { $0.id.uuidString.lowercased() }
        )
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
    }

    private func deleteRowsMissingFromSnapshotLocked(tableName: String, ids: [String]) {
        guard !ids.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        guard let statement = prepareStatement(
            sql: "DELETE FROM \(tableName) WHERE id NOT IN (\(placeholders))"
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }

        for (index, id) in ids.enumerated() {
            bind(text: id, to: Int32(index + 1), in: statement)
        }

        if sqlite3_step(statement) != SQLITE_DONE, let database {
            print("Failed to prune \(tableName): \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    private func applyRealtimeConversationUpdateLocked(
        for message: Message,
        currentUserID: String?,
        isActiveConversation: Bool
    ) {
        updateConversationPreviewLocked(
            for: message,
            currentUserID: currentUserID,
            isActiveConversation: isActiveConversation,
            adjustUnreadCount: true
        )
    }

    private func updateConversationPreviewLocked(
        for message: Message,
        currentUserID: String?,
        isActiveConversation: Bool,
        adjustUnreadCount: Bool
    ) {
        let existing = cachedConversationLocked(id: message.conversationId)
        let updated = mergeConversation(
            existing: existing,
            remote: nil,
            message: message,
            currentUserID: currentUserID,
            isActiveConversation: isActiveConversation,
            adjustUnreadCount: adjustUnreadCount
        )
        writeConversationLocked(updated, lastMessageSeq: message.seq)
    }

    private func mergeConversation(
        existing: Conversation?,
        remote: Conversation?,
        message: Message? = nil,
        currentUserID: String? = nil,
        isActiveConversation: Bool = false,
        adjustUnreadCount: Bool = false
    ) -> Conversation {
        let conversationID = remote?.id ?? existing?.id ?? message?.conversationId ?? ""
        var merged = existing ?? defaultConversation(id: conversationID)

        if let remote {
            merged.type = remote.type
            merged.name = chooseName(current: merged.name, candidate: remote.name)
            merged.avatar = remote.avatar ?? merged.avatar
            merged.targetId = remote.targetId ?? merged.targetId
            merged.unreadCount = mergeUnreadCount(local: merged.unreadCount, remote: remote.unreadCount)
            if snippetTimestamp(remote.lastMessage) >= snippetTimestamp(merged.lastMessage) {
                merged.lastMessage = remote.lastMessage
            }
        }

        if let message {
            applyMetadata(from: message, to: &merged, currentUserID: currentUserID)
            let snippet = previewSnippet(from: message)
            if snippetTimestamp(snippet) >= snippetTimestamp(merged.lastMessage) {
                merged.lastMessage = snippet
            }

            if adjustUnreadCount {
                if isMessageFromCurrentUser(message, currentUserID: currentUserID) || isActiveConversation {
                    merged.unreadCount = 0
                } else {
                    merged.unreadCount = (merged.unreadCount ?? 0) + 1
                }
            }
        }

        if merged.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.name = defaultConversationName(for: merged)
        }
        if merged.unreadCount == nil {
            merged.unreadCount = 0
        }
        return merged
    }

    private func mergeUnreadCount(local: Int?, remote: Int?) -> Int {
        switch (local, remote) {
        case let (local?, remote?):
            if local == 0 {
                return 0
            }
            return remote
        case let (_, remote?):
            return remote
        case let (local?, _):
            return local
        default:
            return 0
        }
    }

    private func applyMetadata(from message: Message, to conversation: inout Conversation, currentUserID: String?) {
        let normalizedConversationID = normalize(message.conversationId)
        if normalizedConversationID.hasPrefix("chat/group/") {
            conversation.type = "group"
            if conversation.targetId?.isEmpty != false {
                conversation.targetId = String(message.conversationId.split(separator: "/").last ?? "")
            }
            if shouldReplaceConversationName(conversation.name) {
                if let explicitName = message.to.name?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
                    conversation.name = explicitName
                } else {
                    conversation.name = "群聊"
                }
            }
            return
        }

        let peer: ChatPeer
        if isMessageFromCurrentUser(message, currentUserID: currentUserID) {
            peer = message.to
        } else {
            peer = message.from
        }

        conversation.type = peer.type
        if conversation.targetId?.isEmpty != false {
            conversation.targetId = peer.id
        }
        if conversation.avatar == nil {
            conversation.avatar = peer.avatar
        }
        if shouldReplaceConversationName(conversation.name) {
            let candidate = peer.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            conversation.name = candidate.isEmpty ? defaultPeerName(type: peer.type, id: peer.id) : candidate
        }
    }

    private func writeConversationLocked(_ conversation: Conversation, lastMessageSeq: Int?) {
        guard let database else { return }
        guard let statement = prepareStatement(
            sql: """
            INSERT INTO cached_conversations (
                id,
                type,
                name,
                avatar,
                target_id,
                last_message_content,
                last_message_timestamp,
                last_message_seq,
                unread_count,
                payload_json,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                type = excluded.type,
                name = excluded.name,
                avatar = excluded.avatar,
                target_id = excluded.target_id,
                last_message_content = excluded.last_message_content,
                last_message_timestamp = excluded.last_message_timestamp,
                last_message_seq = COALESCE(excluded.last_message_seq, cached_conversations.last_message_seq),
                unread_count = excluded.unread_count,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """
        ) else {
            return
        }
        defer { sqlite3_finalize(statement) }

        let payload = encode(conversation: conversation) ?? "{}"
        let snippet = conversation.lastMessage

        bind(text: conversation.id, to: 1, in: statement)
        bind(optionalText: conversation.type, to: 2, in: statement)
        bind(optionalText: conversation.name, to: 3, in: statement)
        bind(optionalText: conversation.avatar, to: 4, in: statement)
        bind(optionalText: conversation.targetId, to: 5, in: statement)
        bind(optionalText: snippet?.content, to: 6, in: statement)

        if let timestamp = snippet?.timestamp {
            sqlite3_bind_int64(statement, 7, sqlite3_int64(timestamp))
        } else {
            sqlite3_bind_null(statement, 7)
        }

        if let lastMessageSeq {
            sqlite3_bind_int64(statement, 8, sqlite3_int64(lastMessageSeq))
        } else {
            sqlite3_bind_null(statement, 8)
        }

        sqlite3_bind_int64(statement, 9, sqlite3_int64(conversation.unreadCount ?? 0))
        bind(text: payload, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)

        if sqlite3_step(statement) != SQLITE_DONE {
            print("Failed to cache conversation \(conversation.id): \(String(cString: sqlite3_errmsg(database)))")
        }
    }

    private func cachedConversationLocked(id: String) -> Conversation? {
        guard let statement = prepareStatement(
            sql: "SELECT payload_json FROM cached_conversations WHERE id = ? LIMIT 1"
        ) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        bind(text: id, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let rawValue = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return decode(conversationPayload: String(cString: rawValue))
    }

    private func loadMessages(
        sql: String,
        bind: (OpaquePointer) -> Void,
        reverseResults: Bool
    ) -> [Message] {
        guard let statement = prepareStatement(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        var items: [Message] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawValue = sqlite3_column_text(statement, 0) else {
                continue
            }

            let payload = String(cString: rawValue)
            guard let message = decode(messagePayload: payload) else {
                continue
            }
            items.append(message)
        }

        return reverseResults ? items.reversed() : items
    }

    private func loadConversations(
        sql: String,
        bind: (OpaquePointer) -> Void
    ) -> [Conversation] {
        guard let statement = prepareStatement(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        var items: [Conversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawValue = sqlite3_column_text(statement, 0) else {
                continue
            }

            let payload = String(cString: rawValue)
            guard let conversation = decode(conversationPayload: payload) else {
                continue
            }
            items.append(conversation)
        }
        return items
    }

    private func loadBots(
        sql: String,
        bind: (OpaquePointer) -> Void
    ) -> [Bot] {
        guard let statement = prepareStatement(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        var items: [Bot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawValue = sqlite3_column_text(statement, 0) else {
                continue
            }

            let payload = String(cString: rawValue)
            guard let bot = decode(botPayload: payload) else {
                continue
            }
            items.append(bot)
        }
        return items
    }

    private func loadGroups(
        sql: String,
        bind: (OpaquePointer) -> Void
    ) -> [ChatGroup] {
        guard let statement = prepareStatement(sql: sql) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(statement)

        var items: [ChatGroup] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawValue = sqlite3_column_text(statement, 0) else {
                continue
            }

            let payload = String(cString: rawValue)
            guard let group = decode(groupPayload: payload) else {
                continue
            }
            items.append(group)
        }
        return items
    }

    private func prepareStatement(sql: String) -> OpaquePointer? {
        guard let database else { return nil }

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) != SQLITE_OK {
            print("Failed to prepare SQLite statement: \(String(cString: sqlite3_errmsg(database)))")
            return nil
        }
        return statement
    }

    private func bind(text: String, to index: Int32, in statement: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    private func bind(optionalText: String?, to index: Int32, in statement: OpaquePointer) {
        guard let optionalText, !optionalText.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(text: optionalText, to: index, in: statement)
    }

    private func encode(message: Message) -> String? {
        guard let data = try? encoder.encode(message) else {
            print("Failed to encode local message \(message.id)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func encode(conversation: Conversation) -> String? {
        guard let data = try? encoder.encode(conversation) else {
            print("Failed to encode local conversation \(conversation.id)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func encode(bot: Bot) -> String? {
        guard let data = try? encoder.encode(bot) else {
            print("Failed to encode local bot \(bot.id)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func encode(group: ChatGroup) -> String? {
        guard let data = try? encoder.encode(group) else {
            print("Failed to encode local group \(group.id)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decode(messagePayload: String) -> Message? {
        guard let data = messagePayload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(Message.self, from: data)
    }

    private func decode(conversationPayload: String) -> Conversation? {
        guard let data = conversationPayload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(Conversation.self, from: data)
    }

    private func decode(botPayload: String) -> Bot? {
        guard let data = botPayload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(Bot.self, from: data)
    }

    private func decode(groupPayload: String) -> ChatGroup? {
        guard let data = groupPayload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(ChatGroup.self, from: data)
    }

    private func notifyConversationChanges() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.conversationsDidChangeNotification, object: nil)
        }
    }

    private func previewSnippet(from message: Message) -> Conversation.MessageSnippet {
        let content = message.content.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewText: String
        if let content, !content.isEmpty {
            previewText = content
        } else if message.content.isAudio {
            previewText = "[语音]"
        } else {
            switch message.content.type.lowercased() {
            case "image":
                previewText = "[图片]"
            case "file":
                previewText = "[文件]"
            default:
                previewText = "[消息]"
            }
        }

        return Conversation.MessageSnippet(
            content: previewText,
            timestamp: message.timestamp ?? Int64(message.createdAt?.timeIntervalSince1970 ?? 0)
        )
    }

    private func snippetTimestamp(_ snippet: Conversation.MessageSnippet?) -> Int64 {
        snippet?.timestamp ?? Int64.min
    }

    private func isMessageFromCurrentUser(_ message: Message, currentUserID: String?) -> Bool {
        normalize(message.senderId) == normalize(currentUserID)
    }

    private func normalize(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func chooseName(current: String, candidate: String) -> String {
        if shouldReplaceConversationName(current) {
            return candidate
        }
        return current
    }

    private func shouldReplaceConversationName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed == "新对话"
            || trimmed == "群聊"
            || trimmed.hasPrefix("Bot ")
            || trimmed.hasPrefix("User ")
            || trimmed.hasPrefix("Group ")
    }

    private func defaultConversation(id: String) -> Conversation {
        let parts = id.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "chat", parts[1] == "group" {
            return Conversation(id: id, type: "group", name: "群聊", avatar: nil, targetId: parts[2], lastMessage: nil, unreadCount: 0)
        }

        if parts.count == 6, parts[0] == "chat", parts[1] == "dm" {
            return Conversation(id: id, type: parts[4], name: defaultPeerName(type: parts[4], id: parts[5]), avatar: nil, targetId: parts[5], lastMessage: nil, unreadCount: 0)
        }

        return Conversation(id: id, type: "conversation", name: "新对话", avatar: nil, targetId: nil, lastMessage: nil, unreadCount: 0)
    }

    private func defaultConversationName(for conversation: Conversation) -> String {
        if conversation.type == "group" {
            return "群聊"
        }
        return defaultPeerName(type: conversation.type, id: conversation.targetId ?? conversation.id)
    }

    private func defaultPeerName(type: String, id: String) -> String {
        switch normalize(type) {
        case "bot":
            return "Bot \(id)"
        case "user":
            return "User \(id)"
        case "group":
            return "Group \(id)"
        default:
            return "新对话"
        }
    }

    private func databaseFileURL() -> URL {
        let fileManager = FileManager.default
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        let endpointIdentifier = ServiceEndpointConfiguration.storageIdentifier(for: APIClient.shared.baseURL)
        let directoryURL = baseURL
            .appendingPathComponent("clawchat", isDirectory: true)
            .appendingPathComponent("endpoints", isDirectory: true)
            .appendingPathComponent(endpointIdentifier, isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL.appendingPathComponent("messages.sqlite", isDirectory: false)
    }

    private func normalizedLimit(_ limit: Int) -> Int {
        max(1, min(limit, 200))
    }
}
