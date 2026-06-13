import Foundation
import SwiftUI

extension Bot: Equatable {
    static func == (lhs: Bot, rhs: Bot) -> Bool {
        lhs.id == rhs.id
            && lhs.ownerId == rhs.ownerId
            && lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.avatar == rhs.avatar
            && lhs.avatarUrl == rhs.avatarUrl
            && lhs.botType == rhs.botType
            && lhs.status == rhs.status
            && lhs.mqttTopic == rhs.mqttTopic
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}

extension AnyCodable: Equatable {
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.jsonObject, rhs.jsonObject) {
        case (let left as String, let right as String):
            return left == right
        case (let left as Int, let right as Int):
            return left == right
        case (let left as Double, let right as Double):
            return left == right
        case (let left as Bool, let right as Bool):
            return left == right
        case (is NSNull, is NSNull):
            return true
        default:
            let left = jsonComparableString(lhs.jsonObject)
            let right = jsonComparableString(rhs.jsonObject)
            return left == right
        }
    }

    private static func jsonComparableString(_ object: Any) -> String {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return String(describing: object)
    }
}

enum DispatchTaskStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case available
    case claimed
    case inProgress = "in_progress"
    case awaitingReview = "awaiting_review"
    case completed
    case failed
    case rejected
    case cancelled
    case blocked

    var id: String { rawValue }

    var label: String {
        rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum DispatchTaskPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case normal
    case high
    case critical

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}

enum DispatchTaskFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case dispatched
    case running
    case review
    case done
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:
            return L10n.t("全部状态", "All states")
        case .ready:
            return L10n.t("就绪", "Ready")
        case .dispatched:
            return L10n.t("已分派", "Dispatched")
        case .running:
            return L10n.t("运行中", "Running")
        case .review:
            return L10n.t("待审核", "Needs Review")
        case .done:
            return L10n.t("完成", "Done")
        case .failed:
            return L10n.t("异常", "Failed")
        }
    }

    var shortLabel: String {
        switch self {
        case .all:
            return L10n.t("全部", "All")
        case .review:
            return L10n.t("审核", "Review")
        default:
            return label
        }
    }
}

enum DispatchTaskViewMode: String, CaseIterable, Identifiable {
    case timeline
    case board
    case list
    case calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .timeline:
            return L10n.t("时间线", "Timeline")
        case .board:
            return L10n.t("看板", "Board")
        case .list:
            return L10n.t("列表", "List")
        case .calendar:
            return L10n.t("日程", "Calendar")
        }
    }
}

enum DispatchTaskZoomMode: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:
            return L10n.t("日", "Day")
        case .week:
            return L10n.t("周", "Week")
        case .month:
            return L10n.t("月", "Month")
        }
    }

    var weekWidth: CGFloat {
        switch self {
        case .day:
            return 118
        case .week:
            return 76
        case .month:
            return 58
        }
    }
}

struct DispatchTaskLane: Identifiable, Equatable {
    let id: DispatchTaskFilter
    let label: String
    let shortLabel: String
    let colorHex: String
    let softColorHex: String
    let statuses: [DispatchTaskStatus]

    var color: Color { Color(hex: colorHex) }
    var softColor: Color { Color(hex: softColorHex) }
}

enum DispatchTaskLanes {
    static let lanes: [DispatchTaskLane] = [
        DispatchTaskLane(id: .ready, label: "Ready", shortLabel: "Ready", colorHex: "#1682f0", softColorHex: "#dbeafe", statuses: [.pending, .available]),
        DispatchTaskLane(id: .dispatched, label: "Dispatched", shortLabel: "Dispatched", colorHex: "#7c3aed", softColorHex: "#ede9fe", statuses: [.claimed]),
        DispatchTaskLane(id: .running, label: "Running", shortLabel: "Running", colorHex: "#f59e0b", softColorHex: "#fef3c7", statuses: [.inProgress]),
        DispatchTaskLane(id: .review, label: "Needs Review", shortLabel: "Review", colorHex: "#0f9f8f", softColorHex: "#ccfbf1", statuses: [.awaitingReview]),
        DispatchTaskLane(id: .done, label: "Done", shortLabel: "Done", colorHex: "#10a878", softColorHex: "#d1fae5", statuses: [.completed]),
        DispatchTaskLane(id: .failed, label: "Failed", shortLabel: "Failed", colorHex: "#ef5a74", softColorHex: "#ffe4e6", statuses: [.failed, .rejected, .cancelled, .blocked])
    ]

    static func lane(for task: DispatchTask) -> DispatchTaskLane {
        lanes.first { $0.statuses.contains(task.status) } ?? lanes[0]
    }

    static func statusColorHex(_ status: DispatchTaskStatus) -> String {
        switch status {
        case .pending:
            return "#94a3b8"
        case .available:
            return "#1682f0"
        case .claimed, .inProgress:
            return "#f59e0b"
        case .awaitingReview:
            return "#0f9f8f"
        case .completed:
            return "#20ae83"
        case .failed, .rejected, .blocked:
            return "#ef5a74"
        case .cancelled:
            return "#64748b"
        }
    }
}

struct DispatchTask: Codable, Identifiable, Equatable {
    let id: UUID
    let ownerId: UUID
    var title: String
    var description: String?
    var priority: DispatchTaskPriority
    var status: DispatchTaskStatus
    var parentTaskId: UUID?
    var assigneeBotId: UUID?
    var assigneeBot: Bot?
    var estimatedStartAt: Date?
    var estimatedEndAt: Date?
    var actualStartAt: Date?
    var actualEndAt: Date?
    var dispatchedAt: Date?
    var claimedAt: Date?
    var dispatched: DispatchTaskDispatchInfo?
    var claimed: DispatchTaskClaimInfo?
    var claimedByBotId: UUID?
    var claimedByBot: Bot?
    var currentExecutorBotId: UUID?
    var currentExecutorBot: Bot?
    var executorBotId: UUID?
    var executorBot: Bot?
    var result: [String: AnyCodable]?
    var error: [String: AnyCodable]?
    var review: AnyCodable?
    var progress: Int
    var latestStatusNote: String?
    var dependencies: [DispatchTaskDependency]
    var events: [DispatchTaskEvent]
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, description, priority, status, dispatched, claimed, result, error, review, progress, dependencies, events
        case ownerId = "owner_id"
        case parentTaskId = "parent_task_id"
        case assigneeBotId = "assignee_bot_id"
        case assigneeBot = "assignee_bot"
        case estimatedStartAt = "estimated_start_at"
        case estimatedEndAt = "estimated_end_at"
        case actualStartAt = "actual_start_at"
        case actualEndAt = "actual_end_at"
        case dispatchedAt = "dispatched_at"
        case claimedAt = "claimed_at"
        case claimedByBotId = "claimed_by_bot_id"
        case claimedByBot = "claimed_by_bot"
        case currentExecutorBotId = "current_executor_bot_id"
        case currentExecutorBot = "current_executor_bot"
        case executorBotId = "executor_bot_id"
        case executorBot = "executor_bot"
        case latestStatusNote = "latest_status_note"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DispatchTaskDependency: Codable, Identifiable, Equatable {
    let id: UUID
    let dependsOnTaskId: UUID
    let dependsOnTask: DispatchTaskBrief?

    enum CodingKeys: String, CodingKey {
        case id
        case dependsOnTaskId = "depends_on_task_id"
        case dependsOnTask = "depends_on_task"
    }
}

struct DispatchTaskBrief: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let status: DispatchTaskStatus
    let progress: Int
}

struct DispatchTaskEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let actorType: String
    let actorId: UUID?
    let status: DispatchTaskStatus
    let progress: Int
    let note: String?
    let eventType: String?
    let type: String?
    let payload: [String: AnyCodable]?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status, progress, note, type, payload
        case actorType = "actor_type"
        case actorId = "actor_id"
        case eventType = "event_type"
        case createdAt = "created_at"
    }
}

struct DispatchTaskDispatchInfo: Codable, Equatable {
    let at: Date?
    let byId: UUID?
    let topic: String?
    let payload: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case at, topic, payload
        case byId = "by_id"
    }
}

struct DispatchTaskClaimInfo: Codable, Equatable {
    let at: Date?
    let botId: UUID?
    let workerId: String?
    let bot: Bot?

    enum CodingKeys: String, CodingKey {
        case at, bot
        case botId = "bot_id"
        case workerId = "worker_id"
    }
}

extension DispatchTask {
    var lane: DispatchTaskLane {
        DispatchTaskLanes.lane(for: self)
    }

    var activeExecutorBot: Bot? {
        currentExecutorBot ?? executorBot ?? claimed?.bot ?? claimedByBot ?? assigneeBot
    }

    var executorId: UUID? {
        currentExecutorBotId ?? executorBotId ?? claimed?.botId ?? claimedByBotId ?? assigneeBotId
    }

    var executorLabel: String {
        if let name = activeExecutorBot?.name, !name.isEmpty {
            return name
        }
        return executorId?.uuidString.lowercased() ?? L10n.t("共享池", "Shared pool")
    }

    var dependencyIds: [UUID] {
        dependencies.map(\.dependsOnTaskId)
    }
}

struct DispatchTaskMutation: Equatable {
    var title: String?
    var description: String?
    var priority: DispatchTaskPriority?
    var status: DispatchTaskStatus?
    var parentTaskId: UUID?
    var assigneeBotId: UUID?
    var estimatedStartAt: Date?
    var estimatedEndAt: Date?
    var progress: Int?
    var dependencyIds: [UUID]?
    var latestStatusNote: String?
    var clearDescription = false
    var clearAssignee = false
    var clearEstimatedStart = false
    var clearEstimatedEnd = false

    func jsonData() throws -> Data {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if clearDescription {
            body["description"] = NSNull()
        } else if let description {
            body["description"] = description
        }
        if let priority { body["priority"] = priority.rawValue }
        if let status { body["status"] = status.rawValue }
        if let parentTaskId { body["parent_task_id"] = parentTaskId.uuidString.lowercased() }
        if clearAssignee {
            body["assignee_bot_id"] = NSNull()
        } else if let assigneeBotId {
            body["assignee_bot_id"] = assigneeBotId.uuidString.lowercased()
        }
        if clearEstimatedStart {
            body["estimated_start_at"] = NSNull()
        } else if let estimatedStartAt {
            body["estimated_start_at"] = Self.apiDateFormatter.string(from: estimatedStartAt)
        }
        if clearEstimatedEnd {
            body["estimated_end_at"] = NSNull()
        } else if let estimatedEndAt {
            body["estimated_end_at"] = Self.apiDateFormatter.string(from: estimatedEndAt)
        }
        if let progress { body["progress"] = progress }
        if let dependencyIds {
            body["dependency_ids"] = dependencyIds.map { $0.uuidString.lowercased() }
        }
        if let latestStatusNote, !latestStatusNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["latest_status_note"] = latestStatusNote
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static let apiDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct DispatchTaskActionInput: Equatable {
    var assigneeBotId: UUID?
    var note: String?
    var reason: String?

    init(assigneeBotId: UUID? = nil, note: String? = nil, reason: String? = nil) {
        self.assigneeBotId = assigneeBotId
        self.note = note
        self.reason = reason
    }

    func jsonData() throws -> Data {
        var body: [String: Any] = [
            "assignee_bot_id": assigneeBotId?.uuidString.lowercased() ?? NSNull()
        ]
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["note"] = note
            body["latest_status_note"] = note
        }
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["reason"] = reason
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
