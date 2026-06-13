import Combine
import Foundation

@MainActor
final class TasksViewModel: ObservableObject {
    @Published private(set) var tasks: [DispatchTask] = []
    @Published private(set) var bots: [Bot] = []
    @Published var selectedTaskId: UUID?
    @Published var isCreatingTask = false
    @Published var query = ""
    @Published var filter: DispatchTaskFilter = .all
    @Published var viewMode: DispatchTaskViewMode = .timeline
    @Published var zoomMode: DispatchTaskZoomMode = .week
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    private let apiClient: APIClient
    private let fixture: TaskConsoleFixture?
    private var refreshTask: Swift.Task<Void, Never>?

    init(fixture: TaskConsoleFixture? = nil) {
        self.apiClient = .shared
        self.fixture = fixture
        if let fixture {
            tasks = fixture.tasks
            bots = fixture.bots
            lastUpdated = Date()
        }
    }

    init(apiClient: APIClient, fixture: TaskConsoleFixture? = nil) {
        self.apiClient = apiClient
        self.fixture = fixture
        if let fixture {
            tasks = fixture.tasks
            bots = fixture.bots
            lastUpdated = Date()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var filteredTasks: [DispatchTask] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { task in
            if !trimmedQuery.isEmpty {
                let haystack = "\(task.title) \(task.description ?? "") \(task.latestStatusNote ?? "")"
                guard haystack.localizedCaseInsensitiveContains(trimmedQuery) else { return false }
            }
            guard filter != .all else { return true }
            return task.lane.id == filter
        }
    }

    var selectedTask: DispatchTask? {
        guard let selectedTaskId else { return nil }
        return tasks.first { $0.id == selectedTaskId }
    }

    var readyCount: Int {
        tasks.filter { $0.lane.id == .ready }.count
    }

    var runningCount: Int {
        tasks.filter { $0.lane.id == .running }.count
    }

    var reviewCount: Int {
        tasks.filter { $0.lane.id == .review }.count
    }

    var alertTasks: [DispatchTask] {
        tasks.filter { [.awaitingReview, .failed, .rejected, .cancelled, .blocked].contains($0.status) }
    }

    func load(showLoading: Bool = true, includeBots: Bool = true) async {
        if fixture != nil {
            lastUpdated = Date()
            return
        }
        if showLoading { isLoading = true }
        errorMessage = nil
        defer { if showLoading { isLoading = false } }
        do {
            async let taskData = apiClient.fetchTasks()
            async let botData = includeBots ? apiClient.fetchBotsValue() : bots
            let loadedTasks = try await taskData
            tasks = loadedTasks
            bots = try await botData
            lastUpdated = Date()
            if let selectedTaskId, !loadedTasks.contains(where: { $0.id == selectedTaskId }) {
                self.selectedTaskId = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAutoRefresh() {
        guard fixture == nil else { return }
        refreshTask?.cancel()
        refreshTask = Swift.Task { [weak self] in
            while !Swift.Task.isCancelled {
                try? await Swift.Task.sleep(nanoseconds: 5_000_000_000)
                await self?.load(showLoading: false, includeBots: false)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func createTask(_ mutation: DispatchTaskMutation) async -> Bool {
        if fixture != nil {
            let dependencyIds = mutation.dependencyIds ?? []
            let initialStatus: DispatchTaskStatus
            if let requestedStatus = mutation.status {
                initialStatus = requestedStatus
            } else if !dependencyIds.isEmpty {
                initialStatus = .blocked
            } else {
                initialStatus = mutation.assigneeBotId == nil ? .available : .claimed
            }
            var created = TaskConsoleFixture.makeTask(
                id: UUID(),
                title: mutation.title ?? L10n.t("新任务", "New task"),
                status: initialStatus,
                priority: mutation.priority ?? .normal,
                start: mutation.estimatedStartAt ?? Date(),
                progress: mutation.progress ?? 0,
                assignee: bots.first { $0.id == mutation.assigneeBotId }
            )
            created.description = mutation.description
            created.estimatedEndAt = mutation.estimatedEndAt
            if !dependencyIds.isEmpty {
                created.dependencies = dependencyModels(for: dependencyIds)
            }
            tasks.insert(created, at: 0)
            lastUpdated = Date()
            return true
        }
        do {
            let created = try await apiClient.createTask(mutation)
            tasks.insert(created, at: 0)
            selectedTaskId = created.id
            lastUpdated = Date()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateTask(id: UUID, mutation: DispatchTaskMutation) async -> Bool {
        if fixture != nil {
            applyLocalMutation(id: id, mutation: mutation)
            lastUpdated = Date()
            return true
        }
        do {
            let updated = try await apiClient.updateTask(id: id, mutation)
            replaceTask(updated)
            lastUpdated = Date()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveSchedule(taskId: UUID, start: Date, end: Date) async {
        guard let oldTask = tasks.first(where: { $0.id == taskId }) else { return }
        applySchedule(taskId: taskId, start: start, end: end)
        if fixture != nil {
            lastUpdated = Date()
            return
        }
        do {
            let updated = try await apiClient.updateTask(id: taskId, DispatchTaskMutation(estimatedStartAt: start, estimatedEndAt: end))
            replaceTask(updated)
            lastUpdated = Date()
        } catch {
            replaceTask(oldTask)
            errorMessage = error.localizedDescription
        }
    }

    func runAction(_ action: DispatchTaskAction, task: DispatchTask, assigneeBotId: UUID?, note: String?) async -> Bool {
        if fixture != nil {
            applyLocalAction(action, taskId: task.id)
            lastUpdated = Date()
            return true
        }
        do {
            let input = DispatchTaskActionInput(assigneeBotId: assigneeBotId, note: note, reason: action == .reject ? note : nil)
            let updated: DispatchTask
            switch action {
            case .dispatch:
                updated = try await apiClient.dispatchTask(id: task.id, input)
            case .cancel:
                updated = try await apiClient.cancelTask(id: task.id, input)
            case .accept:
                updated = try await apiClient.acceptTask(id: task.id, input)
            case .reject:
                updated = try await apiClient.rejectTask(id: task.id, input)
            case .retry:
                updated = try await apiClient.retryTask(id: task.id, input)
            }
            replaceTask(updated)
            lastUpdated = Date()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteTask(_ task: DispatchTask) async -> Bool {
        if fixture != nil {
            tasks.removeAll { $0.id == task.id }
            selectedTaskId = nil
            lastUpdated = Date()
            return true
        }
        do {
            try await apiClient.deleteTask(id: task.id)
            tasks.removeAll { $0.id == task.id }
            selectedTaskId = nil
            lastUpdated = Date()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func replaceTask(_ task: DispatchTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
    }

    private func applySchedule(taskId: UUID, start: Date, end: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].estimatedStartAt = start
        tasks[index].estimatedEndAt = end
    }

    private func applyLocalMutation(id: UUID, mutation: DispatchTaskMutation) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let title = mutation.title { tasks[index].title = title }
        if mutation.clearDescription { tasks[index].description = nil }
        else if let description = mutation.description { tasks[index].description = description }
        if let priority = mutation.priority { tasks[index].priority = priority }
        if let status = mutation.status { tasks[index].status = status }
        if mutation.clearAssignee {
            tasks[index].assigneeBotId = nil
            tasks[index].assigneeBot = nil
        } else if let assigneeBotId = mutation.assigneeBotId {
            tasks[index].assigneeBotId = assigneeBotId
            tasks[index].assigneeBot = bots.first { $0.id == assigneeBotId }
        }
        if mutation.clearEstimatedStart { tasks[index].estimatedStartAt = nil }
        else if let estimatedStartAt = mutation.estimatedStartAt { tasks[index].estimatedStartAt = estimatedStartAt }
        if mutation.clearEstimatedEnd { tasks[index].estimatedEndAt = nil }
        else if let estimatedEndAt = mutation.estimatedEndAt { tasks[index].estimatedEndAt = estimatedEndAt }
        if let progress = mutation.progress { tasks[index].progress = progress }
        if let latestStatusNote = mutation.latestStatusNote { tasks[index].latestStatusNote = latestStatusNote }
        if let dependencyIds = mutation.dependencyIds {
            tasks[index].dependencies = dependencyModels(for: dependencyIds, excluding: id)
        }
    }

    private func dependencyModels(for ids: [UUID], excluding taskId: UUID? = nil) -> [DispatchTaskDependency] {
        var seen = Set<UUID>()
        return ids.compactMap { dependencyId in
            guard dependencyId != taskId, seen.insert(dependencyId).inserted else { return nil }
            let task = tasks.first { $0.id == dependencyId }
            return DispatchTaskDependency(
                id: stableDependencyId(taskId: taskId, dependencyId: dependencyId),
                dependsOnTaskId: dependencyId,
                dependsOnTask: task.map {
                    DispatchTaskBrief(id: $0.id, title: $0.title, status: $0.status, progress: $0.progress)
                }
            )
        }
    }

    private func stableDependencyId(taskId: UUID?, dependencyId: UUID) -> UUID {
        guard let taskId else { return UUID() }
        let namespace = taskId.uuidString.replacingOccurrences(of: "-", with: "")
        let dependency = dependencyId.uuidString.replacingOccurrences(of: "-", with: "")
        let seed = "\(namespace)\(dependency)"
        let prefix = String(seed.prefix(32))
        let formatted = "\(prefix.prefix(8))-\(prefix.dropFirst(8).prefix(4))-\(prefix.dropFirst(12).prefix(4))-\(prefix.dropFirst(16).prefix(4))-\(prefix.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private func applyLocalAction(_ action: DispatchTaskAction, taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        switch action {
        case .dispatch, .retry:
            tasks[index].status = tasks[index].dependencies.isEmpty
                ? (tasks[index].assigneeBotId == nil ? .available : .claimed)
                : .blocked
            tasks[index].progress = 0
            tasks[index].result = nil
            tasks[index].error = nil
            tasks[index].dispatchedAt = Date()
        case .cancel:
            tasks[index].status = .cancelled
        case .accept:
            tasks[index].status = .completed
            tasks[index].progress = 100
        case .reject:
            tasks[index].status = .rejected
        }
    }
}

enum DispatchTaskAction: String, CaseIterable, Identifiable {
    case dispatch
    case cancel
    case accept
    case reject
    case retry

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dispatch:
            return L10n.t("入队任务", "Queue task")
        case .cancel:
            return L10n.t("取消任务", "Cancel task")
        case .accept:
            return L10n.t("通过结果", "Approve result")
        case .reject:
            return L10n.t("要求修改", "Request changes")
        case .retry:
            return L10n.t("重新入队", "Retry task")
        }
    }

    var systemImage: String {
        switch self {
        case .dispatch:
            return "paperplane.fill"
        case .cancel:
            return "xmark.circle.fill"
        case .accept:
            return "checkmark.seal.fill"
        case .reject:
            return "arrow.uturn.backward.circle.fill"
        case .retry:
            return "arrow.clockwise.circle.fill"
        }
    }

    var description: String {
        switch self {
        case .dispatch:
            return L10n.t("让任务进入机器人运行时队列。", "Make this task visible to the bot runtime queue.")
        case .cancel:
            return L10n.t("停止等待或正在执行的任务。", "Stop a waiting or active task.")
        case .accept:
            return L10n.t("确认机器人提交的结果，任务变为完成。", "Approve the bot result and mark the task complete.")
        case .reject:
            return L10n.t("把结果退回，后续可重新入队。", "Reject the submitted result so it can be revised and retried.")
        case .retry:
            return L10n.t("清空旧结果/错误并再次放入队列。", "Clear the previous result or error and queue the task again.")
        }
    }

    var confirmationTitle: String {
        switch self {
        case .dispatch:
            return L10n.t("将任务入队？", "Queue this task?")
        case .cancel:
            return L10n.t("取消这个任务？", "Cancel this task?")
        case .accept:
            return L10n.t("通过这个结果？", "Approve this result?")
        case .reject:
            return L10n.t("要求机器人修改？", "Request changes?")
        case .retry:
            return L10n.t("重新入队这个任务？", "Retry this task?")
        }
    }

    var isDestructive: Bool {
        self == .cancel || self == .reject
    }

    static func availableActions(for status: DispatchTaskStatus) -> [DispatchTaskAction] {
        switch status {
        case .pending, .available, .blocked:
            return [.dispatch, .cancel]
        case .claimed, .inProgress:
            return [.cancel]
        case .awaitingReview:
            return [.accept, .reject, .cancel]
        case .failed, .rejected, .cancelled:
            return [.retry]
        case .completed:
            return []
        }
    }
}

struct TaskConsoleFixture {
    let tasks: [DispatchTask]
    let bots: [Bot]

    static let sample: TaskConsoleFixture = {
        let base = TaskTimelineBuilder.startOfWeek(Date())
        let bots = [
            makeBot(id: UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!, name: "Planner"),
            makeBot(id: UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000002")!, name: "Builder"),
            makeBot(id: UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000003")!, name: "Reviewer")
        ]
        let discovery = makeTask(
            id: UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000001")!,
            title: "Collect project requirements",
            status: .available,
            priority: .normal,
            start: Date(timeInterval: -TaskTimelineBuilder.week, since: base),
            progress: 35,
            assignee: nil
        )
        var implementation = makeTask(
            id: UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!,
            title: "Build timeline renderer",
            status: .inProgress,
            priority: .high,
            start: base,
            progress: 68,
            assignee: bots[1]
        )
        implementation.dependencies = [
            DispatchTaskDependency(
                id: UUID(uuidString: "cccccccc-0000-4000-8000-000000000001")!,
                dependsOnTaskId: discovery.id,
                dependsOnTask: DispatchTaskBrief(id: discovery.id, title: discovery.title, status: discovery.status, progress: discovery.progress)
            )
        ]
        let review = makeTask(
            id: UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000003")!,
            title: "Review generated report",
            status: .awaitingReview,
            priority: .critical,
            start: Date(timeInterval: TaskTimelineBuilder.week, since: base),
            progress: 100,
            assignee: bots[2]
        )
        var reviewed = review
        reviewed.result = [
            "summary": AnyCodable("Generated report is ready for approval."),
            "artifact_url": AnyCodable("https://example.local/reports/123")
        ]
        reviewed.review = AnyCodable(["status": AnyCodable("pending"), "requested_by": AnyCodable("iOS fixture")])

        var failed = makeTask(
            id: UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000004")!,
            title: "Retry broker smoke test",
            status: .failed,
            priority: .normal,
            start: Date(timeInterval: 2 * TaskTimelineBuilder.week, since: base),
            progress: 42,
            assignee: bots[0]
        )
        failed.result = nil
        failed.error = ["message": AnyCodable("Broker smoke test timed out")]

        let completed = makeTask(
            id: UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000005")!,
            title: "Publish task summary",
            status: .completed,
            priority: .normal,
            start: Date(timeInterval: -2 * TaskTimelineBuilder.week, since: base),
            progress: 100,
            assignee: bots[0]
        )
        return TaskConsoleFixture(tasks: [discovery, implementation, reviewed, failed, completed], bots: bots)
    }()

    static func makeBot(id: UUID = UUID(), name: String) -> Bot {
        Bot(id: id, ownerId: UUID(), name: name, description: nil, avatar: nil, avatarUrl: nil, botType: nil, status: "online", mqttTopic: nil, createdAt: nil, updatedAt: nil)
    }

    static func makeTask(
        id: UUID = UUID(),
        title: String,
        status: DispatchTaskStatus,
        priority: DispatchTaskPriority,
        start: Date,
        progress: Int,
        assignee: Bot?
    ) -> DispatchTask {
        let owner = UUID(uuidString: "dddddddd-0000-4000-8000-000000000001")!
        return DispatchTask(
            id: id,
            ownerId: owner,
            title: title,
            description: "Fixture task used to verify the iOS task console.",
            priority: priority,
            status: status,
            parentTaskId: nil,
            assigneeBotId: assignee?.id,
            assigneeBot: assignee,
            estimatedStartAt: start,
            estimatedEndAt: TaskTimelineBuilder.taskEnd(
                DispatchTask.emptyForDuration(priority: priority, createdAt: start),
                start: start
            ),
            actualStartAt: status == .inProgress ? start : nil,
            actualEndAt: status == .completed ? Date(timeInterval: TaskTimelineBuilder.week, since: start) : nil,
            dispatchedAt: status == .available ? nil : start,
            claimedAt: status == .inProgress ? Date(timeInterval: TaskTimelineBuilder.day, since: start) : nil,
            dispatched: nil,
            claimed: nil,
            claimedByBotId: nil,
            claimedByBot: nil,
            currentExecutorBotId: assignee?.id,
            currentExecutorBot: assignee,
            executorBotId: nil,
            executorBot: nil,
            result: ["summary": AnyCodable("Generated fixture result")],
            error: status == .failed ? ["message": AnyCodable("Broker smoke test timed out")] : nil,
            review: nil,
            progress: progress,
            latestStatusNote: "Updated by iOS fixture",
            dependencies: [],
            events: [
                DispatchTaskEvent(id: UUID(), actorType: "system", actorId: nil, status: status, progress: progress, note: "Fixture event", eventType: "task.updated", type: nil, payload: nil, createdAt: Date())
            ],
            createdAt: start,
            updatedAt: Date()
        )
    }
}

private extension DispatchTask {
    static func emptyForDuration(priority: DispatchTaskPriority, createdAt: Date) -> DispatchTask {
        DispatchTask(
            id: UUID(),
            ownerId: UUID(),
            title: "",
            description: nil,
            priority: priority,
            status: .available,
            parentTaskId: nil,
            assigneeBotId: nil,
            assigneeBot: nil,
            estimatedStartAt: nil,
            estimatedEndAt: nil,
            actualStartAt: nil,
            actualEndAt: nil,
            dispatchedAt: nil,
            claimedAt: nil,
            dispatched: nil,
            claimed: nil,
            claimedByBotId: nil,
            claimedByBot: nil,
            currentExecutorBotId: nil,
            currentExecutorBot: nil,
            executorBotId: nil,
            executorBot: nil,
            result: nil,
            error: nil,
            review: nil,
            progress: 0,
            latestStatusNote: nil,
            dependencies: [],
            events: [],
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
