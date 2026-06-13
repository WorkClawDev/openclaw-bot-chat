import Foundation
import Testing
@testable import clawchat

struct TaskTimelineTests {
    @Test func mapsStatusesToFrontendLanes() {
        let expected: [(DispatchTaskStatus, DispatchTaskFilter, String)] = [
            (.pending, .ready, "#94a3b8"),
            (.available, .ready, "#1682f0"),
            (.claimed, .dispatched, "#f59e0b"),
            (.inProgress, .running, "#f59e0b"),
            (.awaitingReview, .review, "#0f9f8f"),
            (.completed, .done, "#20ae83"),
            (.failed, .failed, "#ef5a74"),
            (.rejected, .failed, "#ef5a74"),
            (.cancelled, .failed, "#64748b"),
            (.blocked, .failed, "#ef5a74")
        ]

        for (status, lane, color) in expected {
            let task = makeTask(status: status)
            #expect(DispatchTaskLanes.lane(for: task).id == lane)
            #expect(DispatchTaskLanes.statusColorHex(status) == color)
        }
    }

    @Test func usesFrontendDateFallbackRules() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let dispatched = Date(timeInterval: TaskTimelineBuilder.day, since: created)
        let estimatedStart = Date(timeInterval: 2 * TaskTimelineBuilder.day, since: created)
        let estimatedEnd = Date(timeInterval: 4 * TaskTimelineBuilder.day, since: created)

        var estimated = makeTask(status: .available, createdAt: created)
        estimated.estimatedStartAt = estimatedStart
        estimated.dispatchedAt = dispatched
        estimated.estimatedEndAt = estimatedEnd
        #expect(TaskTimelineBuilder.taskStart(estimated, index: 0, rangeStart: created) == estimatedStart)
        #expect(TaskTimelineBuilder.taskEnd(estimated, start: estimatedStart) == estimatedEnd)

        var dispatchedOnly = makeTask(status: .claimed, createdAt: created)
        dispatchedOnly.dispatchedAt = dispatched
        #expect(TaskTimelineBuilder.taskStart(dispatchedOnly, index: 0, rangeStart: created) == dispatched)

        var fallbackDuration = makeTask(status: .available, priority: .critical, createdAt: created)
        fallbackDuration.estimatedEndAt = nil
        let end = TaskTimelineBuilder.taskEnd(fallbackDuration, start: created)
        #expect(end.timeIntervalSince(created) == 3 * TaskTimelineBuilder.week)
    }

    @Test func buildsVisibleWeeksRowsAndDependencyArrows() {
        let base = TaskTimelineBuilder.startOfWeek(Date(timeIntervalSince1970: 1_800_000_000))
        let dependency = makeTask(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            status: .available,
            createdAt: base
        )
        var dependent = makeTask(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
            status: .inProgress,
            createdAt: Date(timeInterval: TaskTimelineBuilder.week, since: base)
        )
        dependent.dependencies = [
            DispatchTaskDependency(
                id: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
                dependsOnTaskId: dependency.id,
                dependsOnTask: DispatchTaskBrief(id: dependency.id, title: dependency.title, status: dependency.status, progress: dependency.progress)
            )
        ]

        let timeline = TaskTimelineBuilder.build(tasks: [dependency, dependent], weekWidth: 76, referenceDate: base)

        #expect(timeline.weeks.count == TaskTimelineBuilder.visibleWeeks)
        #expect(timeline.groupCounts[.ready] == 1)
        #expect(timeline.groupCounts[.running] == 1)
        #expect(timeline.rows.filter { $0.kind == .group }.count == DispatchTaskLanes.lanes.count)
        #expect(timeline.bars.count == 2)
        #expect(timeline.arrows.count == 1)
    }

    @Test func encodesSchedulePayloadForUpdate() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = Date(timeInterval: TaskTimelineBuilder.week, since: start)
        let data = try DispatchTaskMutation(estimatedStartAt: start, estimatedEndAt: end).jsonData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(object["estimated_start_at"] == "2027-01-15T08:00:00Z")
        #expect(object["estimated_end_at"] == "2027-01-22T08:00:00Z")
    }

    @Test func encodesNullableMutationFieldsForTaskEditing() throws {
        let dependencyId = UUID(uuidString: "10000000-0000-4000-8000-000000000011")!
        let data = try DispatchTaskMutation(
            priority: .critical,
            dependencyIds: [dependencyId],
            latestStatusNote: "rescheduled",
            clearDescription: true,
            clearAssignee: true,
            clearEstimatedStart: true,
            clearEstimatedEnd: true
        ).jsonData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["priority"] as? String == "critical")
        #expect(object["latest_status_note"] as? String == "rescheduled")
        #expect(object["description"] is NSNull)
        #expect(object["assignee_bot_id"] is NSNull)
        #expect(object["estimated_start_at"] is NSNull)
        #expect(object["estimated_end_at"] is NSNull)
        #expect((object["dependency_ids"] as? [String]) == [dependencyId.uuidString.lowercased()])
    }

    @Test func encodesActionPayloadForDispatchAndReject() throws {
        let assigneeId = UUID(uuidString: "10000000-0000-4000-8000-000000000012")!
        let dispatchData = try DispatchTaskActionInput(assigneeBotId: assigneeId, note: "go").jsonData()
        let dispatchObject = try #require(JSONSerialization.jsonObject(with: dispatchData) as? [String: Any])
        #expect(dispatchObject["assignee_bot_id"] as? String == assigneeId.uuidString.lowercased())
        #expect(dispatchObject["note"] as? String == "go")
        #expect(dispatchObject["latest_status_note"] as? String == "go")

        let rejectData = try DispatchTaskActionInput(note: "needs changes", reason: "needs changes").jsonData()
        let rejectObject = try #require(JSONSerialization.jsonObject(with: rejectData) as? [String: Any])
        #expect(rejectObject["assignee_bot_id"] is NSNull)
        #expect(rejectObject["reason"] as? String == "needs changes")
    }

    @Test func exposesOnlyStateRelevantTaskActions() {
        #expect(DispatchTaskAction.availableActions(for: .pending) == [.dispatch, .cancel])
        #expect(DispatchTaskAction.availableActions(for: .available) == [.dispatch, .cancel])
        #expect(DispatchTaskAction.availableActions(for: .inProgress) == [.cancel])
        #expect(DispatchTaskAction.availableActions(for: .awaitingReview) == [.accept, .reject, .cancel])
        #expect(DispatchTaskAction.availableActions(for: .failed) == [.retry])
        #expect(DispatchTaskAction.availableActions(for: .completed).isEmpty)
    }

    @MainActor
    @Test func fixtureViewModelAppliesCreateUpdateScheduleActionsAndDelete() async throws {
        let viewModel = TasksViewModel(fixture: .sample)
        let dependency = try #require(viewModel.tasks.first)
        let bot = try #require(viewModel.bots.first)

        let created = await viewModel.createTask(DispatchTaskMutation(
            title: "Fixture controlled task",
            description: "created from test",
            priority: .high,
            assigneeBotId: bot.id,
            estimatedStartAt: dependency.createdAt,
            estimatedEndAt: dependency.createdAt.addingTimeInterval(TaskTimelineBuilder.week)
        ))
        #expect(created)

        let task = try #require(viewModel.tasks.first { $0.title == "Fixture controlled task" })
        #expect(task.status == .claimed)
        #expect(task.assigneeBotId == bot.id)
        #expect(task.dependencies.isEmpty)

        let drafted = await viewModel.createTask(DispatchTaskMutation(
            title: "Fixture draft task",
            status: .pending
        ))
        #expect(drafted)
        let draft = try #require(viewModel.tasks.first { $0.title == "Fixture draft task" })
        #expect(draft.status == .pending)

        let movedStart = dependency.createdAt.addingTimeInterval(2 * TaskTimelineBuilder.day)
        let movedEnd = movedStart.addingTimeInterval(2 * TaskTimelineBuilder.week)
        await viewModel.saveSchedule(taskId: task.id, start: movedStart, end: movedEnd)
        let moved = try #require(viewModel.tasks.first { $0.id == task.id })
        #expect(moved.estimatedStartAt == movedStart)
        #expect(moved.estimatedEndAt == movedEnd)

        let updated = await viewModel.updateTask(id: task.id, mutation: DispatchTaskMutation(
            title: "Fixture edited task",
            progress: 42,
            dependencyIds: []
        ))
        #expect(updated)
        let edited = try #require(viewModel.tasks.first { $0.id == task.id })
        #expect(edited.title == "Fixture edited task")
        #expect(edited.progress == 42)
        #expect(edited.dependencies.isEmpty)

        #expect(await viewModel.runAction(.accept, task: edited, assigneeBotId: nil, note: "done"))
        let accepted = try #require(viewModel.tasks.first { $0.id == task.id })
        #expect(accepted.status == .completed)
        #expect(accepted.progress == 100)

        #expect(await viewModel.deleteTask(accepted))
        #expect(!viewModel.tasks.contains { $0.id == task.id })
    }

    @Test func decodesTaskAPIShapeWithDependenciesEventsAndPayloads() throws {
        let data = Data(Self.fixtureJSON.utf8)
        let task = try Self.decoder.decode(DispatchTask.self, from: data)

        #expect(task.title == "Decode task")
        #expect(task.status == .awaitingReview)
        #expect(task.priority == .high)
        #expect(task.assigneeBot?.name == "Decode Bot")
        #expect(task.dependencies.first?.dependsOnTask?.progress == 100)
        #expect(task.events.first?.eventType == "task.updated")
        #expect(task.result?["summary"]?.stringValue == "ok")
        #expect(task.error == nil)
        #expect(task.review?.dictionaryValue?["status"]?.stringValue == "pending")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            guard let date = plain.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad test date")
            }
            return date
        }
        return decoder
    }()

    private static let fixtureJSON = """
    {
      "id": "20000000-0000-4000-8000-000000000001",
      "owner_id": "20000000-0000-4000-8000-000000000002",
      "title": "Decode task",
      "description": null,
      "priority": "high",
      "status": "awaiting_review",
      "parent_task_id": null,
      "assignee_bot_id": "20000000-0000-4000-8000-000000000003",
      "assignee_bot": {
        "id": "20000000-0000-4000-8000-000000000003",
        "owner_id": "20000000-0000-4000-8000-000000000002",
        "name": "Decode Bot",
        "description": null,
        "avatar": null,
        "avatar_url": null,
        "bot_type": "assistant",
        "status": "online",
        "mqtt_topic": null,
        "created_at": "2026-06-01T00:00:00Z",
        "updated_at": "2026-06-01T00:00:00Z"
      },
      "estimated_start_at": "2026-06-01T00:00:00Z",
      "estimated_end_at": "2026-06-08T00:00:00Z",
      "actual_start_at": "2026-06-02T00:00:00Z",
      "actual_end_at": null,
      "progress": 88,
      "latest_status_note": "Ready for review",
      "result": { "summary": "ok" },
      "error": null,
      "review": { "status": "pending" },
      "dispatched_at": "2026-06-01T01:00:00Z",
      "claimed_at": "2026-06-01T02:00:00Z",
      "dependencies": [
        {
          "id": "20000000-0000-4000-8000-000000000004",
          "depends_on_task_id": "20000000-0000-4000-8000-000000000005",
          "depends_on_task": {
            "id": "20000000-0000-4000-8000-000000000005",
            "title": "Dependency",
            "status": "completed",
            "progress": 100
          }
        }
      ],
      "events": [
        {
          "id": "20000000-0000-4000-8000-000000000006",
          "actor_type": "system",
          "actor_id": null,
          "event_type": "task.updated",
          "status": "awaiting_review",
          "progress": 88,
          "note": "moved",
          "payload": { "source": "test" },
          "created_at": "2026-06-01T03:00:00Z"
        }
      ],
      "created_at": "2026-06-01T00:00:00Z",
      "updated_at": "2026-06-01T03:00:00Z"
    }
    """
}

private func makeTask(
    id: UUID = UUID(),
    status: DispatchTaskStatus,
    priority: DispatchTaskPriority = .normal,
    createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> DispatchTask {
    DispatchTask(
        id: id,
        ownerId: UUID(),
        title: "Task \(status.rawValue)",
        description: nil,
        priority: priority,
        status: status,
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
