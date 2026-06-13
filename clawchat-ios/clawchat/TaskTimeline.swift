import Foundation
import CoreGraphics

struct TaskTimelineRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case group
        case task
    }

    let id: String
    let kind: Kind
    let top: CGFloat
    let height: CGFloat
    let lane: DispatchTaskLane
    let task: DispatchTask?
    let taskNumber: Int?
}

struct TaskTimelineBar: Identifiable, Equatable {
    let id: UUID
    let task: DispatchTask
    let lane: DispatchTaskLane
    let left: CGFloat
    let top: CGFloat
    let width: CGFloat
    let start: Date
    let end: Date
}

struct TaskTimelineArrow: Identifiable, Equatable {
    let id: UUID
    let x1: CGFloat
    let y1: CGFloat
    let x2: CGFloat
    let y2: CGFloat
}

struct TaskTimelineMonth: Identifiable, Equatable {
    let id: String
    let label: String
    let width: CGFloat
}

struct TaskTimelineWeek: Identifiable, Equatable {
    let id: String
    let date: Date
}

struct TaskTimelineDragPreview: Equatable {
    let taskId: UUID
    let start: Date
    let end: Date
}

struct TaskTimeline: Equatable {
    let arrows: [TaskTimelineArrow]
    let bars: [TaskTimelineBar]
    let groupCounts: [DispatchTaskFilter: Int]
    let height: CGFloat
    let months: [TaskTimelineMonth]
    let rows: [TaskTimelineRow]
    let todayLeft: CGFloat
    let weeks: [TaskTimelineWeek]
    let width: CGFloat
    let rangeStart: Date
}

enum TaskTimelineBuilder {
    static let day: TimeInterval = 24 * 60 * 60
    static let week: TimeInterval = 7 * day
    static let groupHeight: CGFloat = 36
    static let taskHeight: CGFloat = 38
    static let visibleWeeks = 14

    static func build(
        tasks: [DispatchTask],
        weekWidth: CGFloat,
        collapsedGroups: Set<DispatchTaskFilter> = [],
        dragPreview: TaskTimelineDragPreview? = nil,
        referenceDate: Date = Date()
    ) -> TaskTimeline {
        let rangeStart = startOfWeek(Date(timeInterval: -2 * week, since: referenceDate))
        let width = CGFloat(visibleWeeks) * weekWidth
        let weeks = (0..<visibleWeeks).map { index -> TaskTimelineWeek in
            let date = Date(timeInterval: TimeInterval(index) * week, since: rangeStart)
            return TaskTimelineWeek(id: isoWeekKey(date), date: date)
        }
        let months = monthSegments(weeks: weeks, weekWidth: weekWidth)
        let grouped = Dictionary(grouping: tasks, by: { DispatchTaskLanes.lane(for: $0).id })

        var rows: [TaskTimelineRow] = []
        var groupCounts: [DispatchTaskFilter: Int] = [:]
        var taskNumber = 0
        var top: CGFloat = 0

        for lane in DispatchTaskLanes.lanes {
            let laneTasks = grouped[lane.id] ?? []
            groupCounts[lane.id] = laneTasks.count
            rows.append(TaskTimelineRow(id: "group-\(lane.id.rawValue)", kind: .group, top: top, height: groupHeight, lane: lane, task: nil, taskNumber: nil))
            top += groupHeight
            guard !collapsedGroups.contains(lane.id) else { continue }
            for task in laneTasks {
                taskNumber += 1
                rows.append(TaskTimelineRow(id: task.id.uuidString, kind: .task, top: top, height: taskHeight, lane: lane, task: task, taskNumber: taskNumber))
                top += taskHeight
            }
        }

        let taskRows = rows.filter { $0.task != nil }
        let bars = taskRows.enumerated().compactMap { index, row -> TaskTimelineBar? in
            guard let task = row.task else { return nil }
            let preview = dragPreview?.taskId == task.id ? dragPreview : nil
            let start = preview?.start ?? taskStart(task, index: index, rangeStart: rangeStart)
            let end = preview?.end ?? taskEnd(task, start: start)
            let rawLeft = CGFloat((start.timeIntervalSince(rangeStart) / week) * Double(weekWidth))
            let rawRight = CGFloat((end.timeIntervalSince(rangeStart) / week) * Double(weekWidth))
            let left = clamp(rawLeft, min: 4, max: width - 34)
            return TaskTimelineBar(
                id: task.id,
                task: task,
                lane: row.lane,
                left: left,
                top: row.top + 8,
                width: clamp(rawRight - rawLeft, min: 52, max: width - left - 4),
                start: start,
                end: end
            )
        }

        let barsByTaskId = Dictionary(uniqueKeysWithValues: bars.map { ($0.task.id, $0) })
        let arrows = taskRows.flatMap { row -> [TaskTimelineArrow] in
            guard let targetTask = row.task, let target = barsByTaskId[targetTask.id] else { return [] }
            return targetTask.dependencies.compactMap { dependency in
                guard let source = barsByTaskId[dependency.dependsOnTaskId] else { return nil }
                return TaskTimelineArrow(
                    id: dependency.id,
                    x1: source.left + source.width,
                    y1: source.top + 11,
                    x2: target.left,
                    y2: target.top + 11
                )
            }
        }

        return TaskTimeline(
            arrows: arrows,
            bars: bars,
            groupCounts: groupCounts,
            height: top,
            months: months,
            rows: rows,
            todayLeft: CGFloat((referenceDate.timeIntervalSince(rangeStart) / week) * Double(weekWidth)),
            weeks: weeks,
            width: width,
            rangeStart: rangeStart
        )
    }

    static func taskStart(_ task: DispatchTask, index: Int, rangeStart: Date) -> Date {
        if let date = task.estimatedStartAt ?? task.dispatchedAt {
            return date
        }
        return task.createdAt
    }

    static func taskEnd(_ task: DispatchTask, start: Date) -> Date {
        if let date = task.estimatedEndAt ?? task.actualEndAt, date > start {
            return date
        }
        let durationWeeks: Double
        switch task.priority {
        case .critical:
            durationWeeks = 3
        case .high:
            durationWeeks = 2.4
        case .low:
            durationWeeks = 1.2
        case .normal:
            durationWeeks = 1.8
        }
        return Date(timeInterval: durationWeeks * week, since: start)
    }

    static func draggedDates(start: Date, end: Date, deltaX: CGFloat, weekWidth: CGFloat, mode: TaskTimelineDragMode) -> (start: Date, end: Date) {
        let deltaMs = round((Double(deltaX / weekWidth) * week) / day) * day
        switch mode {
        case .resize:
            return (start, Date(timeIntervalSince1970: max(start.timeIntervalSince1970 + day, end.timeIntervalSince1970 + deltaMs)))
        case .move:
            let duration = end.timeIntervalSince(start)
            let nextStart = Date(timeInterval: deltaMs, since: start)
            return (nextStart, Date(timeInterval: duration, since: nextStart))
        }
    }

    static func startOfWeek(_ value: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: value)
        return calendar.date(from: components) ?? value
    }

    private static func monthSegments(weeks: [TaskTimelineWeek], weekWidth: CGFloat) -> [TaskTimelineMonth] {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "LLLL"
        var segments: [TaskTimelineMonth] = []
        for week in weeks {
            let label = formatter.string(from: week.date)
            if let last = segments.last, last.label == label {
                segments[segments.count - 1] = TaskTimelineMonth(id: last.id, label: label, width: last.width + weekWidth)
            } else {
                segments.append(TaskTimelineMonth(id: week.id, label: label, width: weekWidth))
            }
        }
        return segments
    }

    private static func isoWeekKey(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}

enum TaskTimelineDragMode {
    case move
    case resize
}

