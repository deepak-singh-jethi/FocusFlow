import SwiftUI
import AppKit

// MARK: - Tasks View (Generalized Task Manager)
public struct TasksView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public var topPadding: CGFloat
    @State private var showingAddTask = false
    @State private var newTaskTitle = ""
    @State private var expectedMinutes = 25
    @State private var isAddHovered = false

    public init(viewModel: TimerViewModel, topPadding: CGFloat = WindowLayoutMetrics.standardTopClearance) {
        self.viewModel = viewModel
        self.topPadding = topPadding
    }

    private var totalSpentLabel: String {
        let total = viewModel.tasks.reduce(0) { $0 + $1.timeSpentSeconds }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tasks")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                        Text("Choose what to focus on next and track time spent.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button {
                        newTaskTitle = ""
                        expectedMinutes = 25
                        showingAddTask = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .background(Color.orange.opacity(isAddHovered ? 0.26 : 0.16), in: Capsule())
                            .overlay(Capsule().stroke(Color.orange.opacity(isAddHovered ? 0.52 : 0.25), lineWidth: 1))
                            .foregroundColor(.orange)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { isAddHovered = hovering }
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
                .padding(.top, topPadding)

                // Metric Summary Cards
                HStack(spacing: 12) {
                    metricCard(title: "TOTAL TASKS", value: "\(viewModel.tasks.count)", icon: "checklist")
                    metricCard(title: "COMPLETED", value: "\(viewModel.tasks.filter(\.isCompleted).count)", icon: "checkmark.circle")
                    metricCard(title: "TIME LOGGED", value: totalSpentLabel, icon: "clock.arrow.circlepath")
                    metricCard(title: "UP NEXT", value: viewModel.tasks.indices.contains(viewModel.activeTaskIndex) ? viewModel.tasks[viewModel.activeTaskIndex].title : "Nothing queued", icon: "arrow.turn.down.right")
                }

                // Task List Cards
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.tasks.enumerated()), id: \.element.id) { index, task in
                        let active = index == viewModel.activeTaskIndex && !task.isCompleted

                        VStack(spacing: 8) {
                            HStack(spacing: 14) {
                                // Checkbox Toggle
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        viewModel.toggleTaskCompletion(at: index)
                                    }
                                } label: {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(task.isCompleted ? .green : .gray.opacity(0.8))
                                        .frame(width: 32, height: 32)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .contentShape(Circle())
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                }

                                // Task Icon
                                Image(systemName: task.icon)
                                    .font(.system(size: 15))
                                    .foregroundColor(active ? .orange : task.iconColor)
                                    .frame(width: 22)

                                // Title and Time Info
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title)
                                        .font(.system(size: 14, weight: active ? .semibold : .medium))
                                        .foregroundColor(task.isCompleted ? .gray : .white)
                                        .strikethrough(task.isCompleted)

                                    HStack(spacing: 8) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock")
                                                .font(.system(size: 10))
                                            Text("\(task.formattedTimeSpent) spent")
                                                .font(.system(size: 11, weight: task.timeSpentSeconds > 0 ? .semibold : .regular))
                                        }
                                        .foregroundColor(task.timeSpentSeconds > 0 ? .orange : .gray)

                                        Text("·")
                                            .foregroundColor(.gray.opacity(0.5))

                                        Text("\(task.expectedTime) est.")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)

                                        if task.progress >= 1.0 && !task.isCompleted {
                                            Text("· Est. reached")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.green.opacity(0.85))
                                        }
                                    }
                                }

                                Spacer()

                                // Status / Actions
                                if active {
                                    HStack(spacing: 5) {
                                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                                        Text("ACTIVE")
                                            .font(.system(size: 9, weight: .bold))
                                            .tracking(0.8)
                                    }
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                                } else if !task.isCompleted {
                                    Button {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            viewModel.selectTask(at: index)
                                        }
                                    } label: {
                                        Text("Set Active")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.9))
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: 32)
                                            .background(Color.white.opacity(0.08), in: Capsule())
                                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Capsule())
                                    .onHover { hovering in
                                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                    }
                                }

                                // Reset time spent button (if > 0)
                                if task.timeSpentSeconds > 0 && !task.isCompleted {
                                    Button {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            viewModel.resetTaskTime(at: index)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray.opacity(0.7))
                                            .frame(width: 28, height: 28)
                                            .background(Color.white.opacity(0.04), in: Circle())
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Circle())
                                    .onHover { hovering in
                                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                    }
                                    .help("Reset time spent on this task")
                                }

                                // Delete task
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        viewModel.removeTask(at: index)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray.opacity(0.65))
                                        .frame(width: 28, height: 28)
                                        .background(Color.white.opacity(0.04), in: Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .contentShape(Circle())
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                }
                                .help("Delete task")
                            }

                            // Progress Bar for task time
                            if task.progress > 0 {
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.07))
                                        Capsule()
                                            .fill(task.isCompleted ? Color.green : (active ? Color.orange : Color.gray.opacity(0.5)))
                                            .frame(width: bar.size.width * CGFloat(task.progress))
                                    }
                                }
                                .frame(height: 3)
                                .padding(.horizontal, 4)
                            }
                        }
                        .padding(14)
                        .background(Color.white.opacity(active ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.orange.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1))
                    }
                }

                if viewModel.tasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.system(size: 28)).foregroundColor(.gray)
                        Text("Your list is clear").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        Text("Add a task to start planning your next focus session.").font(.system(size: 12)).foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(30)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingAddTask) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a Task")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                    Text("Set a title and estimated focus time.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                TextField("Task name (e.g. Design Spec, Code Review, Reading)", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)

                VStack(alignment: .leading, spacing: 8) {
                    Text("QUICK ESTIMATE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.gray)

                    HStack(spacing: 8) {
                        ForEach([15, 25, 45, 60, 90], id: \.self) { mins in
                            Button {
                                expectedMinutes = mins
                            } label: {
                                Text("\(mins)m")
                                    .font(.system(size: 11, weight: expectedMinutes == mins ? .bold : .medium))
                                    .foregroundColor(expectedMinutes == mins ? .orange : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(expectedMinutes == mins ? Color.orange.opacity(0.2) : Color.white.opacity(0.06), in: Capsule())
                                    .overlay(Capsule().stroke(expectedMinutes == mins ? Color.orange.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Stepper("Estimated time: \(expectedMinutes) minutes", value: $expectedMinutes, in: 5...360, step: 5)

                HStack {
                    Button("Cancel") { showingAddTask = false }
                    Spacer()
                    Button("Add Task", action: addTask)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        viewModel.addTask(title: title, expectedMinutes: expectedMinutes)
        showingAddTask = false
    }

    private func metricCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(.orange)
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

public typealias StudyTasksView = TasksView
