import SwiftUI
import AppKit

// MARK: - Right Panel Workspace View
public struct RightPanelView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public var showLaps: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddTask = false
    @State private var newTaskTitle = ""
    @State private var newTaskMinutes = 25
    @State private var isCloseHovered = false
    @State private var isAddTaskHovered = false

    public init(viewModel: TimerViewModel, showLaps: Bool = false) {
        self.viewModel = viewModel
        self.showLaps = showLaps
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(showLaps ? "Stopwatch" : "Your workspace")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                        Text(showLaps ? "Record and review your splits" : "A clear plan for this session")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(isCloseHovered ? .white : .gray)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(isCloseHovered ? 0.12 : 0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { isCloseHovered = hovering }
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .help("Close workspace")
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Focus Tasks")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: { showingAddTask = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Task")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(isAddTaskHovered ? 0.14 : 0.06))
                            .cornerRadius(6)
                            .foregroundColor(isAddTaskHovered ? .white : .gray)
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) { isAddTaskHovered = hovering }
                            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                        }
                    }

                    VStack(spacing: 6) {
                        ForEach(Array(viewModel.tasks.enumerated()), id: \.element.id) { index, task in
                            let isActive = index == viewModel.activeTaskIndex && !task.isCompleted
                            let status = task.isCompleted ? "Completed" : (isActive ? "Active" : "Upcoming")
                            Button {
                                viewModel.selectTask(at: index)
                            } label: {
                                TaskRow(
                                    icon: task.icon,
                                    iconColor: isActive ? .orange : task.iconColor,
                                    title: task.title,
                                    time: task.expectedTime,
                                    timeSpent: task.formattedTimeSpent,
                                    progress: task.progress,
                                    status: status,
                                    isActive: isActive,
                                    isLocked: false,
                                    isCompleted: task.isCompleted
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                            .disabled(task.isCompleted)
                            .onHover { hovering in
                                if hovering && !task.isCompleted { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("\(viewModel.tasks.filter(\.isCompleted).count) of \(viewModel.tasks.count) tasks complete")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                        Spacer(minLength: 0)
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                if showLaps {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lap Times")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Newest split at the top")
                                .font(.system(size: 11))
                                .foregroundColor(.gray.opacity(0.8))
                        }
                        if viewModel.laps.isEmpty {
                            emptyState(icon: "flag", title: "No laps yet", detail: "Start the stopwatch and record a split.")
                        } else {
                            VStack(spacing: 7) {
                                ForEach(Array(viewModel.laps.enumerated()), id: \.element.id) { index, lap in
                                    let isFastest = viewModel.fastestLapIndex == index
                                    let isSlowest = viewModel.slowestLapIndex == index
                                    HStack {
                                        HStack(spacing: 6) {
                                            Text("Lap \(lap.lapNumber)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.gray)
                                            if isFastest {
                                                Text("FAST")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundColor(.green)
                                            } else if isSlowest {
                                                Text("SLOW")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        Spacer()
                                        Text("+ \(lap.formattedLapDuration)")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(isFastest ? .green : (isSlowest ? .orange : .gray))
                                        Text(lap.formattedTotalTime)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(isFastest ? Color.green.opacity(0.3) : (isSlowest ? Color.orange.opacity(0.3) : Color.white.opacity(0.08)), lineWidth: 1))
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preset Cards")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Quick Session launches")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            PresetCard(title: "Focus", time: "(25m)", isSelected: viewModel.activePreset == "Focus") { viewModel.requestPresetChange(name: "Focus", minutes: 25) }
                            PresetCard(title: "Short Break", time: "(5m)", isSelected: viewModel.activePreset == "Short Break") { viewModel.requestPresetChange(name: "Short Break", minutes: 5) }
                            PresetCard(title: "Long Break", time: "(15m)", isSelected: viewModel.activePreset == "Long Break") { viewModel.requestPresetChange(name: "Long Break", minutes: 15) }
                            PresetCard(title: "Exam Run", time: "(50m)", isSelected: viewModel.activePreset == "Exam Run", hasSparkle: true) { viewModel.requestPresetChange(name: "Exam Run", minutes: 50) }
                        }
                    }
                }

                if !viewModel.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECENT NOTES")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundColor(.gray)
                        ForEach(viewModel.notes.prefix(3), id: \.self) { note in
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if viewModel.showConflictModal, let pending = viewModel.pendingTimerRequest {
                let targetDuration = pending.seconds > 0 ? "\(pending.minutes)m \(pending.seconds)s" : "\(pending.minutes)m"
                TimerConflictSwitchModal(
                    currentPresetName: viewModel.displayedTimerPreset,
                    currentRemainingTime: viewModel.displayedTimerTimeString,
                    currentElapsedMinutes: viewModel.currentSessionElapsedMinutes,
                    targetPresetName: pending.name,
                    targetDurationString: targetDuration,
                    onContinue: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.continueCurrentTimer()
                        }
                    },
                    onEndAndSwitch: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.endAndSwitch()
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.94).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showConflictModal)
        .sheet(isPresented: $showingAddTask) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create a task").font(.title2.weight(.semibold))
                TextField("Task name", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                Stepper("Estimated time: \(newTaskMinutes) minutes", value: $newTaskMinutes, in: 5...180, step: 5)
                HStack {
                    Button("Cancel") { showingAddTask = false }
                    Spacer()
                    Button("Add task") {
                        viewModel.addTask(title: newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines), expectedMinutes: newTaskMinutes)
                        newTaskTitle = ""
                        newTaskMinutes = 25
                        showingAddTask = false
                    }
                    .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 410)
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(.gray.opacity(0.7))
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            Text(detail).font(.system(size: 11)).foregroundColor(.gray).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
}
