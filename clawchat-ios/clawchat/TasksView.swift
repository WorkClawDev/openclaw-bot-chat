import SwiftUI

struct TasksView: View {
    @StateObject private var viewModel: TasksViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var taskForDeletion: DispatchTask?

    init() {
        _viewModel = StateObject(wrappedValue: TasksViewModel())
    }

    init(viewModel: TasksViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                VStack(alignment: .leading, spacing: 14) {
                    header
                    statsRow
                    modePicker
                    toolbar
                    content
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await viewModel.load()
                viewModel.startAutoRefresh()
            }
            .onDisappear {
                viewModel.stopAutoRefresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.startAutoRefresh()
                } else {
                    viewModel.stopAutoRefresh()
                }
            }
            .sheet(isPresented: $viewModel.isCreatingTask) {
                TaskCreateSheet(viewModel: viewModel)
            }
            .sheet(isPresented: selectedTaskSheetBinding) {
                if let task = viewModel.selectedTask {
                    TaskInspectorSheet(
                        viewModel: viewModel,
                        task: task,
                        requestDelete: { taskForDeletion = task }
                    )
                }
            }
            .confirmationDialog(
                L10n.t("删除这个任务？", "Delete this task?"),
                isPresented: Binding(
                    get: { taskForDeletion != nil },
                    set: { if !$0 { taskForDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let task = taskForDeletion {
                    Button(L10n.t("删除", "Delete"), role: .destructive) {
                        Swift.Task { await viewModel.deleteTask(task) }
                    }
                }
                Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(taskForDeletion?.title ?? "")
            }
        }
    }

    private var selectedTaskSheetBinding: Binding<Bool> {
        Binding {
            viewModel.selectedTask != nil
        } set: { isPresented in
            if !isPresented {
                viewModel.selectedTaskId = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("任务", "Tasks"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rcmsTextStrong)
                    .accessibilityIdentifier("tasks-title")
                Text(L10n.t("调度、排期和审核机器人工作", "Dispatch, schedule, and review bot work"))
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }
            Spacer()
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                viewModel.isCreatingTask = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(Color.rcmsAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .accessibilityIdentifier("tasks-create-button")
            .accessibilityLabel(L10n.t("新建任务", "New task"))
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            TaskStatCard(title: L10n.t("就绪", "Ready"), value: viewModel.readyCount, systemImage: "checklist", tint: Color(hex: "#1682f0"))
            TaskStatCard(title: L10n.t("运行", "Running"), value: viewModel.runningCount, systemImage: "chart.line.uptrend.xyaxis", tint: Color(hex: "#7c3aed"))
            TaskStatCard(title: L10n.t("审核", "Review"), value: viewModel.reviewCount, systemImage: "target", tint: Color(hex: "#10a878"))
        }
    }

    private var modePicker: some View {
        Picker(L10n.t("视图", "View"), selection: $viewModel.viewMode) {
            ForEach(DispatchTaskViewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("tasks-view-mode-picker")
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.rcmsTextSecondary)
                TextField(L10n.t("搜索任务", "Search dispatch tasks"), text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.rcmsFieldSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.rcmsHairline, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Menu {
                    ForEach(DispatchTaskFilter.allCases) { filter in
                        Button(filter.label) { viewModel.filter = filter }
                    }
                } label: {
                    Label(viewModel.filter.label, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TaskToolbarButtonStyle())

                Picker(L10n.t("缩放", "Zoom"), selection: $viewModel.zoomMode) {
                    ForEach(DispatchTaskZoomMode.allCases) { zoom in
                        Text(zoom.label).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Button {
                    Swift.Task { await viewModel.load(showLoading: false) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(TaskToolbarButtonStyle())
                .accessibilityLabel(L10n.t("刷新任务", "Refresh tasks"))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage, viewModel.tasks.isEmpty {
            TaskStateView(systemImage: "exclamationmark.triangle.fill", title: L10n.t("任务加载失败", "Could not load tasks"), message: error)
        } else if viewModel.isLoading && viewModel.tasks.isEmpty {
            TaskStateView(systemImage: "hourglass", title: L10n.t("正在加载任务", "Loading tasks"), message: L10n.t("正在同步调度控制台。", "Syncing the dispatch console."))
        } else {
            switch viewModel.viewMode {
            case .timeline:
                TaskGanttBoard(viewModel: viewModel)
            case .board:
                TaskBoardView(viewModel: viewModel)
            case .list:
                TaskListView(viewModel: viewModel)
            case .calendar:
                TaskCalendarView(viewModel: viewModel)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(DispatchTaskLanes.lanes) { lane in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(lane.color)
                                .frame(width: 8, height: 8)
                            Text(lane.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.rcmsTextSecondary)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            Spacer(minLength: 0)
            if ChatRoomV2FeatureFlag.uiTestMode == "tasksConsole", let firstTask = viewModel.filteredTasks.first {
                Button {
                    viewModel.selectedTaskId = firstTask.id
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tasks-fixture-open-first-task")
            }
            Text(L10n.t("更新 \(relativeTime(viewModel.lastUpdated))", "Updated \(relativeTime(viewModel.lastUpdated))"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.rcmsTextSecondary)
                .lineLimit(1)
        }
    }
}

private struct TaskGanttBoard: View {
    @ObservedObject var viewModel: TasksViewModel
    @State private var collapsedGroups: Set<DispatchTaskFilter> = []
    @State private var dragPreview: TaskTimelineDragPreview?

    private var timeline: TaskTimeline {
        TaskTimelineBuilder.build(
            tasks: viewModel.filteredTasks,
            weekWidth: viewModel.zoomMode.weekWidth,
            collapsedGroups: collapsedGroups,
            dragPreview: dragPreview
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                    chart
                }
            }
            .frame(minWidth: 430 + timeline.width, alignment: .topLeading)
            .background(Color.rcmsSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.rcmsHairline, lineWidth: 1)
            )
            .accessibilityIdentifier("tasks-gantt-board-content")
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityIdentifier("tasks-gantt-board")
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack {
                Text(L10n.t("任务", "Task"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.t("执行者", "Executor"))
                    .frame(width: 82, alignment: .leading)
                Text(L10n.t("日期", "Dates"))
                    .frame(width: 102, alignment: .leading)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.rcmsTextSecondary)
            .padding(.horizontal, 12)
            .frame(width: 430, height: 64)
            .background(Color.rcmsSurfaceElevated)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(timeline.months) { month in
                        Text(month.label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.rcmsTextPrimary)
                            .frame(width: month.width, height: 30)
                            .overlay(alignment: .trailing) { Divider().overlay(Color.rcmsDivider) }
                    }
                }
                HStack(spacing: 0) {
                    ForEach(timeline.weeks) { week in
                        Text(weekLabel(week.date))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.rcmsTextSecondary)
                            .frame(width: viewModel.zoomMode.weekWidth, height: 34)
                            .overlay(alignment: .trailing) { Divider().overlay(Color.rcmsDivider) }
                    }
                }
            }
            .frame(width: timeline.width, height: 64)
            .background(Color.rcmsSurfaceElevated)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ForEach(timeline.rows) { row in
                if row.kind == .group {
                    Button {
                        if collapsedGroups.contains(row.lane.id) {
                            collapsedGroups.remove(row.lane.id)
                        } else {
                            collapsedGroups.insert(row.lane.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: collapsedGroups.contains(row.lane.id) ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.bold))
                            Circle()
                                .fill(row.lane.color)
                                .frame(width: 9, height: 9)
                            Text(row.lane.label)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.rcmsTextPrimary)
                            Spacer()
                            Text(L10n.t("\(timeline.groupCounts[row.lane.id] ?? 0) 项", "\(timeline.groupCounts[row.lane.id] ?? 0) tasks"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.rcmsTextSecondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 430, height: row.height)
                        .background(Color.rcmsSurfaceMuted.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                } else if let task = row.task {
                    Button {
                        viewModel.selectedTaskId = task.id
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(row.taskNumber ?? 0)")
                                .font(.caption2)
                                .foregroundStyle(Color.rcmsTextSecondary)
                                .frame(width: 18, alignment: .trailing)
                            Circle()
                                .fill(Color(hex: DispatchTaskLanes.statusColorHex(task.status)))
                                .frame(width: 7, height: 7)
                            Text(task.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.rcmsTextPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TaskBotMiniBadge(bot: task.activeExecutorBot)
                                .frame(width: 82, alignment: .leading)
                            Text(dateRange(task))
                                .font(.caption2)
                                .foregroundStyle(Color.rcmsTextSecondary)
                                .frame(width: 102, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: 430, height: row.height)
                        .background(viewModel.selectedTaskId == task.id ? Color.rcmsAccentSoft.opacity(0.8) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(row.taskNumber == 1 ? "tasks-first-task-row" : "tasks-row-\(task.id.uuidString)")
                }
            }
        }
        .overlay(alignment: .trailing) { Divider().overlay(Color.rcmsDivider) }
    }

    private var chart: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(timeline.weeks.enumerated()), id: \.element.id) { index, _ in
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: viewModel.zoomMode.weekWidth, height: timeline.height)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.rcmsDivider)
                            .frame(width: 1)
                    }
                    .offset(x: CGFloat(index) * viewModel.zoomMode.weekWidth)
            }

            ForEach(timeline.rows) { row in
                Rectangle()
                    .fill(row.kind == .group ? Color.rcmsSurfaceMuted.opacity(0.5) : Color.clear)
                    .frame(width: timeline.width, height: row.height)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.rcmsDivider)
                            .frame(height: 1)
                    }
                    .offset(y: row.top)
            }

            if timeline.todayLeft >= 0 && timeline.todayLeft <= timeline.width {
                Rectangle()
                    .fill(Color.rcmsAccent)
                    .frame(width: 1, height: timeline.height)
                    .offset(x: timeline.todayLeft)
                    .overlay(alignment: .top) {
                        Text("TODAY")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.rcmsAccent)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .offset(x: timeline.todayLeft - 18, y: 4)
                    }
            }

            TaskDependencyArrowLayer(arrows: timeline.arrows)

            ForEach(timeline.bars) { bar in
                TaskGanttBar(
                    bar: bar,
                    selected: viewModel.selectedTaskId == bar.task.id,
                    weekWidth: viewModel.zoomMode.weekWidth,
                    onPreview: { preview in dragPreview = preview },
                    onEnd: { start, end in
                        dragPreview = nil
                        Swift.Task { await viewModel.saveSchedule(taskId: bar.task.id, start: start, end: end) }
                    },
                    onSelect: {
                        viewModel.selectedTaskId = bar.task.id
                    }
                )
            }

            if viewModel.filteredTasks.isEmpty {
                TaskStateView(systemImage: "tray", title: L10n.t("没有匹配任务", "No matching tasks"), message: L10n.t("新建任务或调整筛选条件。", "Create a task or change the active state filter."))
                    .frame(width: min(timeline.width, 360), height: 220)
                    .offset(x: max(20, timeline.width / 2 - 180), y: 80)
            }
        }
        .frame(width: timeline.width, height: max(timeline.height, 260), alignment: .topLeading)
        .background(Color.rcmsFieldSurface.opacity(0.48))
    }
}

private struct TaskGanttBar: View {
    let bar: TaskTimelineBar
    let selected: Bool
    let weekWidth: CGFloat
    let onPreview: (TaskTimelineDragPreview) -> Void
    let onEnd: (Date, Date) -> Void
    let onSelect: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(bar.lane.softColor)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(bar.lane.color.opacity(0.22))
                .frame(width: max(0, bar.width * CGFloat(min(max(bar.task.progress, 0), 100)) / 100))
            HStack(spacing: 6) {
                Text(bar.task.title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(bar.task.progress)%")
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(bar.lane.color)
            .padding(.horizontal, 8)
            Rectangle()
                .fill(bar.lane.color.opacity(0.14))
                .frame(width: 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gesture(resizeGesture)
        }
        .frame(width: bar.width, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Color.rcmsAccent : bar.lane.color, lineWidth: selected ? 2 : 1)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
        .offset(x: bar.left, y: bar.top)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tasks-gantt-bar-\(bar.task.id.uuidString)")
        .accessibilityLabel(bar.task.title)
        .accessibilityValue("\(bar.task.progress)% \(bar.lane.label)")
        .accessibilityAddTraits(.isButton)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let deltaX = horizontalDelta(for: value) else { return }
                let next = TaskTimelineBuilder.draggedDates(start: bar.start, end: bar.end, deltaX: deltaX, weekWidth: weekWidth, mode: .move)
                onPreview(TaskTimelineDragPreview(taskId: bar.task.id, start: next.start, end: next.end))
            }
            .onEnded { value in
                guard let deltaX = horizontalDelta(for: value) else { return }
                let next = TaskTimelineBuilder.draggedDates(start: bar.start, end: bar.end, deltaX: deltaX, weekWidth: weekWidth, mode: .move)
                onEnd(next.start, next.end)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let deltaX = horizontalDelta(for: value) else { return }
                let next = TaskTimelineBuilder.draggedDates(start: bar.start, end: bar.end, deltaX: deltaX, weekWidth: weekWidth, mode: .resize)
                onPreview(TaskTimelineDragPreview(taskId: bar.task.id, start: next.start, end: next.end))
            }
            .onEnded { value in
                guard let deltaX = horizontalDelta(for: value) else { return }
                let next = TaskTimelineBuilder.draggedDates(start: bar.start, end: bar.end, deltaX: deltaX, weekWidth: weekWidth, mode: .resize)
                onEnd(next.start, next.end)
            }
    }

    private func horizontalDelta(for value: DragGesture.Value) -> CGFloat? {
        let translation = value.translation
        guard abs(translation.width) >= abs(translation.height) else { return nil }
        return translation.width
    }
}

private struct TaskDependencyArrowLayer: View {
    let arrows: [TaskTimelineArrow]

    var body: some View {
        Canvas { context, _ in
            for arrow in arrows {
                var path = Path()
                path.move(to: CGPoint(x: arrow.x1, y: arrow.y1))
                path.addCurve(
                    to: CGPoint(x: arrow.x2, y: arrow.y2),
                    control1: CGPoint(x: arrow.x1 + 16, y: arrow.y1),
                    control2: CGPoint(x: arrow.x2 - 16, y: arrow.y2)
                )
                context.stroke(path, with: .color(Color(hex: "#7890a9")), lineWidth: 1.25)
                var head = Path()
                head.move(to: CGPoint(x: arrow.x2, y: arrow.y2))
                head.addLine(to: CGPoint(x: arrow.x2 - 6, y: arrow.y2 - 4))
                head.addLine(to: CGPoint(x: arrow.x2 - 6, y: arrow.y2 + 4))
                head.closeSubpath()
                context.fill(head, with: .color(Color(hex: "#7890a9")))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TaskBoardView: View {
    @ObservedObject var viewModel: TasksViewModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(DispatchTaskLanes.lanes) { lane in
                    let laneTasks = viewModel.filteredTasks.filter { $0.lane.id == lane.id }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle().fill(lane.color).frame(width: 10, height: 10)
                            Text(lane.label)
                                .font(.headline)
                                .foregroundStyle(Color.rcmsTextStrong)
                            Spacer()
                            Text("\(laneTasks.count)")
                                .font(.caption.bold())
                                .foregroundStyle(Color.rcmsTextSecondary)
                        }
                        ForEach(laneTasks) { task in
                            TaskCardButton(task: task, selected: viewModel.selectedTaskId == task.id) {
                                viewModel.selectedTaskId = task.id
                            }
                        }
                        if laneTasks.isEmpty {
                            Text(L10n.t("没有任务", "No tasks"))
                                .font(.subheadline)
                                .foregroundStyle(Color.rcmsTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(12)
                    .background(Color.rcmsSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.rcmsHairline, lineWidth: 1)
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct TaskListView: View {
    @ObservedObject var viewModel: TasksViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.filteredTasks) { task in
                    TaskCardButton(task: task, selected: viewModel.selectedTaskId == task.id) {
                        viewModel.selectedTaskId = task.id
                    }
                }
                if viewModel.filteredTasks.isEmpty {
                    TaskStateView(systemImage: "tray", title: L10n.t("没有匹配任务", "No matching tasks"), message: L10n.t("调整搜索或筛选条件。", "Change the search or filter."))
                }
            }
        }
    }
}

private struct TaskCalendarView: View {
    @ObservedObject var viewModel: TasksViewModel

    private var groups: [(String, [DispatchTask])] {
        let grouped = Dictionary(grouping: viewModel.filteredTasks) { task in
            task.lane.label
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(groups, id: \.0) { label, tasks in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(label)
                            .font(.headline)
                            .foregroundStyle(Color.rcmsTextStrong)
                        Text(L10n.t("\(tasks.count) 个任务", "\(tasks.count) tasks"))
                            .font(.caption)
                            .foregroundStyle(Color.rcmsTextSecondary)
                        ForEach(tasks) { task in
                            TaskCardButton(task: task, selected: viewModel.selectedTaskId == task.id) {
                                viewModel.selectedTaskId = task.id
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.rcmsSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.rcmsHairline, lineWidth: 1)
                    )
                }
            }
        }
    }
}

private struct TaskCardButton: View {
    let task: DispatchTask
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(task.lane.color)
                        .frame(width: 8, height: 8)
                    Text(task.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.rcmsTextStrong)
                        .lineLimit(1)
                    Spacer()
                    Text("\(task.progress)%")
                        .font(.caption.bold())
                        .foregroundStyle(task.lane.color)
                }
                ProgressView(value: Double(task.progress), total: 100)
                    .tint(task.lane.color)
                HStack {
                    Label(task.executorLabel, systemImage: "cpu")
                    Spacer()
                    Text(dateRange(task))
                }
                .font(.caption)
                .foregroundStyle(Color.rcmsTextSecondary)
                if let note = task.latestStatusNote, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(selected ? Color.rcmsAccentSoft.opacity(0.78) : Color.rcmsSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.rcmsAccent.opacity(0.55) : Color.rcmsHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TaskCreateSheet: View {
    @ObservedObject var viewModel: TasksViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var priority: DispatchTaskPriority = .normal
    @State private var assigneeBotId: UUID?
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date(timeIntervalSinceNow: TaskTimelineBuilder.week)
    @State private var dependencyIds: Set<UUID> = []
    @State private var queueImmediately = true
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("任务", "Task")) {
                    TextField(L10n.t("任务标题", "Task title"), text: $title)
                    TextField(L10n.t("描述", "Description"), text: $description, axis: .vertical)
                        .lineLimit(3...5)
                    Picker(L10n.t("优先级", "Priority"), selection: $priority) {
                        ForEach(DispatchTaskPriority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                }
                Section(L10n.t("调度", "Schedule")) {
                    Picker(L10n.t("执行者", "Assignee"), selection: $assigneeBotId) {
                        Text(L10n.t("共享池", "Shared pool")).tag(UUID?.none)
                        ForEach(viewModel.bots) { bot in
                            Text(bot.name).tag(UUID?.some(bot.id))
                        }
                    }
                    Toggle(L10n.t("设置开始时间", "Set start"), isOn: $hasStart)
                    if hasStart {
                        DatePicker(L10n.t("开始", "Start"), selection: $start)
                    }
                    Toggle(L10n.t("设置结束时间", "Set end"), isOn: $hasEnd)
                    if hasEnd {
                        DatePicker(L10n.t("结束", "End"), selection: $end)
                    }
                }
                Section(L10n.t("执行", "Execution")) {
                    Toggle(L10n.t("创建后立即入队", "Queue immediately"), isOn: $queueImmediately)
                    Text(queueImmediately
                        ? L10n.t("任务会立即进入机器人运行时队列；真正执行取决于对应机器人是否在线并轮询队列。", "The task becomes runnable immediately. Actual execution still depends on an online bot runtime polling the queue.")
                        : L10n.t("任务会保存为草稿，稍后可在详情里手动入队。", "The task is saved as a draft and can be queued later from the detail sheet."))
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }
                Section(L10n.t("依赖", "Dependencies")) {
                    ForEach(viewModel.tasks) { task in
                        Toggle(task.title, isOn: binding(for: task.id))
                    }
                }
            }
            .accessibilityIdentifier("tasks-create-sheet")
            .navigationTitle(L10n.t("新建任务", "Create task"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("tasks-create-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? L10n.t("创建中", "Creating...") : L10n.t("创建", "Create")) {
                        Swift.Task { await submit() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding {
            dependencyIds.contains(id)
        } set: { isOn in
            if isOn { dependencyIds.insert(id) }
            else { dependencyIds.remove(id) }
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await viewModel.createTask(DispatchTaskMutation(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            priority: priority,
            status: queueImmediately ? nil : .pending,
            assigneeBotId: assigneeBotId,
            estimatedStartAt: hasStart ? start : nil,
            estimatedEndAt: hasEnd ? end : nil,
            dependencyIds: Array(dependencyIds)
        ))
        if ok { dismiss() }
    }
}

private struct TaskInspectorSheet: View {
    @ObservedObject var viewModel: TasksViewModel
    let task: DispatchTask
    let requestDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String
    @State private var priority: DispatchTaskPriority
    @State private var assigneeBotId: UUID?
    @State private var hasStart: Bool
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var dependencyIds: Set<UUID>
    @State private var note = ""
    @State private var isSaving = false
    @State private var actionToConfirm: DispatchTaskAction?

    init(viewModel: TasksViewModel, task: DispatchTask, requestDelete: @escaping () -> Void) {
        self.viewModel = viewModel
        self.task = task
        self.requestDelete = requestDelete
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _priority = State(initialValue: task.priority)
        _assigneeBotId = State(initialValue: task.assigneeBotId ?? task.executorId)
        _hasStart = State(initialValue: task.estimatedStartAt != nil)
        _start = State(initialValue: task.estimatedStartAt ?? Date())
        _hasEnd = State(initialValue: task.estimatedEndAt != nil)
        _end = State(initialValue: task.estimatedEndAt ?? Date(timeInterval: TaskTimelineBuilder.week, since: task.estimatedStartAt ?? Date()))
        _dependencyIds = State(initialValue: Set(task.dependencyIds))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.lane.label)
                            .font(.caption.bold())
                            .foregroundStyle(task.lane.color)
                        Text(task.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Color.rcmsTextStrong)
                        Text(executionStateLabel(task))
                            .font(.caption)
                            .foregroundStyle(Color.rcmsTextSecondary)
                    }
                    ProgressView(value: Double(task.progress), total: 100)
                        .tint(task.lane.color)
                }

                TaskExecutionResultSection(task: task)

                Section(L10n.t("编辑", "Edit")) {
                    TextField(L10n.t("标题", "Title"), text: $title)
                    TextField(L10n.t("描述", "Description"), text: $description, axis: .vertical)
                        .lineLimit(3...6)
                    Picker(L10n.t("优先级", "Priority"), selection: $priority) {
                        ForEach(DispatchTaskPriority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                    Picker(L10n.t("执行者", "Assignee"), selection: $assigneeBotId) {
                        Text(L10n.t("共享池", "Shared pool")).tag(UUID?.none)
                        ForEach(viewModel.bots) { bot in
                            Text(bot.name).tag(UUID?.some(bot.id))
                        }
                    }
                    Toggle(L10n.t("估算开始", "Estimated start"), isOn: $hasStart)
                    if hasStart {
                        DatePicker(L10n.t("开始", "Start"), selection: $start)
                    }
                    Toggle(L10n.t("估算结束", "Estimated end"), isOn: $hasEnd)
                    if hasEnd {
                        DatePicker(L10n.t("结束", "End"), selection: $end)
                    }
                    TextField(L10n.t("操作备注", "Action note"), text: $note)
                    Button(isSaving ? L10n.t("保存中", "Saving...") : L10n.t("保存", "Save")) {
                        Swift.Task { await save() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(L10n.t("任务控制", "Task controls")) {
                    Text(taskControlHint(task))
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                    let actions = DispatchTaskAction.availableActions(for: task.status)
                    if actions.isEmpty {
                        Label(L10n.t("没有可用动作", "No available actions"), systemImage: "checkmark.seal")
                            .foregroundStyle(Color.rcmsTextSecondary)
                    } else {
                        ForEach(actions) { action in
                            TaskActionRow(action: action) {
                                actionToConfirm = action
                            }
                        }
                    }
                    Button(L10n.t("删除任务", "Delete task"), role: .destructive) {
                        dismiss()
                        requestDelete()
                    }
                }

                Section(L10n.t("依赖", "Dependencies")) {
                    ForEach(viewModel.tasks.filter { $0.id != task.id }) { candidate in
                        Toggle(candidate.title, isOn: binding(for: candidate.id))
                    }
                }

                Section(L10n.t("执行者", "Current executor")) {
                    Label(task.executorLabel, systemImage: "cpu")
                    Text(L10n.t("分派 \(formatDate(task.dispatchedAt)) · 认领 \(formatDate(task.claimedAt))", "Dispatched \(formatDate(task.dispatchedAt)) · Claimed \(formatDate(task.claimedAt))"))
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }

                Section(L10n.t("排期", "Schedule")) {
                    InspectorValueRow(label: L10n.t("估算", "Estimated"), value: "\(formatDate(task.estimatedStartAt)) - \(formatDate(task.estimatedEndAt))")
                    InspectorValueRow(label: L10n.t("实际", "Actual"), value: "\(formatDate(task.actualStartAt)) - \(formatDate(task.actualEndAt))")
                    InspectorValueRow(label: L10n.t("最新备注", "Latest note"), value: task.latestStatusNote ?? L10n.t("无备注", "No status note."))
                }

                Section(L10n.t("原始载荷", "Raw payloads")) {
                    DisclosureGroup("Result JSON") {
                        TaskPayloadText(object: task.result?.mapValues(\.jsonObject))
                    }
                    DisclosureGroup("Error JSON") {
                        TaskPayloadText(object: task.error?.mapValues(\.jsonObject))
                    }
                    DisclosureGroup("Review JSON") {
                        TaskPayloadText(object: task.review?.jsonObject)
                    }
                }

                Section(L10n.t("子任务", "Bot spawned work")) {
                    let children = viewModel.tasks.filter { $0.parentTaskId == task.id }
                    if children.isEmpty {
                        Text(L10n.t("没有子任务", "No child tasks created by the runtime."))
                            .foregroundStyle(Color.rcmsTextSecondary)
                    } else {
                        ForEach(children) { child in
                            Text("\(child.title) · \(child.status.label) · \(child.progress)%")
                        }
                    }
                }

                Section(L10n.t("事件历史", "Event history")) {
                    if task.events.isEmpty {
                        Text(L10n.t("暂无事件", "No events yet."))
                            .foregroundStyle(Color.rcmsTextSecondary)
                    } else {
                        ForEach(task.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.eventType ?? event.type ?? "status_changed")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(event.actorType) · \(event.status.label) · \(event.progress)%")
                                    .font(.caption)
                                    .foregroundStyle(Color.rcmsTextSecondary)
                                if let note = event.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("tasks-inspector-sheet")
            .navigationTitle(L10n.t("任务详情", "Task detail"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭", "Close")) { dismiss() }
                }
            }
            .confirmationDialog(
                actionToConfirm?.confirmationTitle ?? "",
                isPresented: Binding(get: { actionToConfirm != nil }, set: { if !$0 { actionToConfirm = nil } }),
                titleVisibility: .visible
            ) {
                if let action = actionToConfirm {
                    Button(action.label, role: action.isDestructive ? .destructive : nil) {
                        Swift.Task { await run(action) }
                    }
                }
                Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            } message: {
                if let action = actionToConfirm {
                    Text(action.description)
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding {
            dependencyIds.contains(id)
        } set: { isOn in
            if isOn { dependencyIds.insert(id) }
            else { dependencyIds.remove(id) }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let ok = await viewModel.updateTask(id: task.id, mutation: DispatchTaskMutation(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.isEmpty ? nil : description,
            priority: priority,
            assigneeBotId: assigneeBotId,
            estimatedStartAt: hasStart ? start : nil,
            estimatedEndAt: hasEnd ? end : nil,
            dependencyIds: Array(dependencyIds),
            latestStatusNote: note,
            clearDescription: description.isEmpty,
            clearAssignee: assigneeBotId == nil,
            clearEstimatedStart: !hasStart,
            clearEstimatedEnd: !hasEnd
        ))
        if ok { dismiss() }
    }

    private func run(_ action: DispatchTaskAction) async {
        let ok = await viewModel.runAction(action, task: task, assigneeBotId: assigneeBotId, note: note)
        actionToConfirm = nil
        if ok { dismiss() }
    }
}

private struct TaskActionRow: View {
    let action: DispatchTaskAction
    let run: () -> Void

    var body: some View {
        Button(role: action.isDestructive ? .destructive : nil, action: run) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.label)
                        .font(.subheadline.weight(.semibold))
                    Text(action.description)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }
            }
        }
    }
}

private struct TaskExecutionResultSection: View {
    let task: DispatchTask

    var body: some View {
        Section(L10n.t("执行结果", "Execution result")) {
            Label(outcomeTitle, systemImage: outcomeImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(outcomeColor)
            Text(outcomeMessage)
                .font(.caption)
                .foregroundStyle(Color.rcmsTextSecondary)
            if let summary = payloadSummary(task.result) {
                InspectorValueRow(label: L10n.t("结果摘要", "Result summary"), value: summary)
            }
            if let error = payloadSummary(task.error) {
                InspectorValueRow(label: L10n.t("错误", "Error"), value: error)
            }
        }
    }

    private var outcomeTitle: String {
        switch task.status {
        case .awaitingReview:
            return task.result == nil ? L10n.t("等待审核", "Waiting for review") : L10n.t("机器人已提交结果", "Bot result submitted")
        case .completed:
            return L10n.t("结果已通过", "Result approved")
        case .failed:
            return L10n.t("执行失败", "Execution failed")
        case .claimed, .inProgress:
            return L10n.t("机器人执行中", "Bot is working")
        case .pending:
            return L10n.t("草稿任务", "Draft task")
        case .available, .blocked:
            return L10n.t("等待机器人执行", "Waiting for bot execution")
        case .rejected:
            return L10n.t("结果被退回", "Result needs changes")
        case .cancelled:
            return L10n.t("任务已取消", "Task cancelled")
        }
    }

    private var outcomeMessage: String {
        switch task.status {
        case .awaitingReview:
            return L10n.t("请查看结果摘要，然后通过或要求修改。", "Review the submitted result, then approve it or request changes.")
        case .completed:
            return L10n.t("机器人结果已经被人工确认。", "The bot result has been approved by a human reviewer.")
        case .failed:
            return L10n.t("机器人回传了错误信息，可以修正后重新入队。", "The bot returned an error. Fix the issue and retry when ready.")
        case .claimed, .inProgress:
            return L10n.t("任务已在运行时队列中，等待机器人回传进度或结果。", "The task is in the runtime queue. Wait for the bot to post progress or a result.")
        case .pending:
            return L10n.t("这是草稿任务，尚未进入机器人运行时队列。", "This is a draft task and is not visible to the bot runtime queue yet.")
        case .available:
            return L10n.t("任务可被任意在线机器人领取。", "Any online bot runtime can pick up this task.")
        case .blocked:
            return L10n.t("依赖完成后才会进入可执行队列。", "The task becomes runnable after its dependencies complete.")
        case .rejected:
            return L10n.t("结果被退回，重新入队后机器人可再次处理。", "The result was rejected. Retry to let the bot work on it again.")
        case .cancelled:
            return L10n.t("任务已停止；需要继续时请重新入队。", "The task has been stopped. Retry it if work should continue.")
        }
    }

    private var outcomeImage: String {
        switch task.status {
        case .completed:
            return "checkmark.seal.fill"
        case .failed, .rejected, .cancelled:
            return "exclamationmark.triangle.fill"
        case .awaitingReview:
            return "doc.text.magnifyingglass"
        case .claimed, .inProgress:
            return "gearshape.2.fill"
        default:
            return "tray.and.arrow.down.fill"
        }
    }

    private var outcomeColor: Color {
        switch task.status {
        case .completed:
            return Color(hex: "#10a878")
        case .failed, .rejected, .cancelled:
            return Color(hex: "#ef5a74")
        case .awaitingReview:
            return Color(hex: "#0f9f8f")
        default:
            return Color.rcmsAccent
        }
    }
}

private struct TaskPayloadText: View {
    let object: Any?

    var body: some View {
        Text(jsonString(object))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color.rcmsTextSecondary)
            .textSelection(.enabled)
    }
}

private func taskControlHint(_ task: DispatchTask) -> String {
    switch task.status {
    case .pending:
        return L10n.t("任务是草稿；入队后才会被机器人运行时看到。", "This task is a draft. Queue it before a bot runtime can see it.")
    case .available:
        return L10n.t("任务已在共享队列中；在线机器人轮询队列后会开始处理。", "This task is in the shared queue. An online bot starts it after polling the queue.")
    case .blocked:
        return L10n.t("任务被依赖阻塞；可以取消，也可以等待依赖完成。", "This task is blocked by dependencies. You can cancel it or wait for dependencies to finish.")
    case .claimed:
        return L10n.t("任务已分配给执行者，等待机器人开始或回传进度。", "This task is assigned to an executor and is waiting for bot progress.")
    case .inProgress:
        return L10n.t("机器人正在执行；结果会由运行时回传。", "The bot is working. The runtime will post the result.")
    case .awaitingReview:
        return L10n.t("机器人已提交结果，请人工通过或要求修改。", "The bot submitted a result. Approve it or request changes.")
    case .completed:
        return L10n.t("任务已完成，没有后续执行动作。", "This task is complete and has no follow-up execution actions.")
    case .failed:
        return L10n.t("任务失败；重新入队会清空旧错误并再次执行。", "This task failed. Retry clears the old error and queues it again.")
    case .rejected:
        return L10n.t("结果已被退回；重新入队可让机器人修正。", "The result was rejected. Retry lets the bot revise it.")
    case .cancelled:
        return L10n.t("任务已取消；重新入队可恢复执行。", "This task was cancelled. Retry queues it again.")
    }
}

private func payloadSummary(_ payload: [String: AnyCodable]?) -> String? {
    guard let payload else { return nil }
    let preferredKeys = ["summary", "message", "text", "output", "title", "error"]
    for key in preferredKeys {
        if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
    }
    return payload.values.compactMap { value in
        value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }.first { !$0.isEmpty }
}

private struct TaskStatCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.rcmsTextStrong)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: 62)
        .background(Color.rcmsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }
}

private struct TaskBotMiniBadge: View {
    let bot: Bot?

    var body: some View {
        if let bot {
            Text(initials(bot.name))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(hex: colorHex(for: bot.id)), in: Circle())
                .accessibilityLabel(bot.name)
        } else {
            Text("-")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.rcmsTextSecondary)
        }
    }
}

private struct TaskStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.rcmsAccent)
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.rcmsTextStrong)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.rcmsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }
}

private struct InspectorValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(Color.rcmsTextSecondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
    }
}

private struct TaskJSONSection: View {
    let label: String
    let value: [String: AnyCodable]?

    var body: some View {
        Section(label) {
            Text(jsonString(value?.mapValues(\.jsonObject)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.rcmsTextSecondary)
                .textSelection(.enabled)
        }
    }
}

private struct TaskAnyJSONSection: View {
    let label: String
    let value: AnyCodable?

    var body: some View {
        Section(label) {
            Text(jsonString(value?.jsonObject))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.rcmsTextSecondary)
                .textSelection(.enabled)
        }
    }
}

private struct TaskToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.rcmsTextPrimary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.rcmsFieldSurface.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.rcmsHairline, lineWidth: 1)
            )
    }
}

private func weekLabel(_ date: Date) -> String {
    let end = Date(timeInterval: 6 * TaskTimelineBuilder.day, since: date)
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateFormat = "MMM d"
    let startText = formatter.string(from: date)
    formatter.dateFormat = "d"
    return "\(startText)-\(formatter.string(from: end))"
}

private func dateRange(_ task: DispatchTask) -> String {
    let start = task.estimatedStartAt ?? task.dispatchedAt ?? task.createdAt
    let end = task.estimatedEndAt ?? task.actualEndAt
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateFormat = "MMM d"
    if let end {
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
    return formatter.string(from: start)
}

private func formatDate(_ date: Date?) -> String {
    guard let date else { return L10n.t("未设置", "Not set") }
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func relativeTime(_ date: Date?) -> String {
    guard let date else { return L10n.t("从未", "never") }
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 10 { return L10n.t("刚刚", "just now") }
    if seconds < 60 { return "\(seconds)s ago" }
    return "\(seconds / 60)m ago"
}

private func executionStateLabel(_ task: DispatchTask) -> String {
    "\(task.status.label) · \(task.progress)% · \(task.executorLabel)"
}

private func initials(_ name: String) -> String {
    let words = name.split(separator: " ")
    let letters = words.prefix(2).compactMap(\.first)
    let value = String(letters).uppercased()
    return value.isEmpty ? "SP" : value
}

private func colorHex(for id: UUID) -> String {
    let palette = ["#0875df", "#8b5cf6", "#10a878", "#f97316", "#ef5a74"]
    return palette[abs(id.uuidString.hashValue) % palette.count]
}

private func jsonString(_ object: Any?) -> String {
    guard let object else { return "None" }
    if JSONSerialization.isValidJSONObject(object),
       let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let value = String(data: data, encoding: .utf8) {
        return value
    }
    return String(describing: object)
}

#Preview {
    TasksView(viewModel: TasksViewModel(fixture: .sample))
}
