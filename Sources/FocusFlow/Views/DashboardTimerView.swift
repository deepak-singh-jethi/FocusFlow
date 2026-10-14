import SwiftUI
import AppKit

// MARK: - Dashboard Timer View
public struct DashboardTimerView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public let gradient: LinearGradient
    @Binding public var clockStyle: String
    @Binding public var isFocusState: Bool
    @Binding public var showingWorkspace: Bool
    public var isStopwatchMode: Bool = false
    public var onSwitchToStopwatch: (() -> Void)? = nil
    public var onSwitchToTimer: (() -> Void)? = nil

    @State private var isPresetHovered = false
    @State private var showingCustomPicker = false
    @State private var isCustomPillHovered = false

    public init(
        viewModel: TimerViewModel,
        gradient: LinearGradient,
        clockStyle: Binding<String>,
        isFocusState: Binding<Bool>,
        showingWorkspace: Binding<Bool>,
        isStopwatchMode: Bool = false,
        onSwitchToStopwatch: (() -> Void)? = nil,
        onSwitchToTimer: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.gradient = gradient
        self._clockStyle = clockStyle
        self._isFocusState = isFocusState
        self._showingWorkspace = showingWorkspace
        self.isStopwatchMode = isStopwatchMode
        self.onSwitchToStopwatch = onSwitchToStopwatch
        self.onSwitchToTimer = onSwitchToTimer
    }

    private var primaryActionTitle: String {
        if isStopwatchMode {
            if viewModel.isStopwatchRunning { return "Pause" }
            return viewModel.stopwatchTime == 0 ? "Start" : "Resume"
        } else {
            if viewModel.isTimerRunning { return "Pause" }
            return viewModel.timeRemaining == viewModel.totalTime ? "Start" : "Resume"
        }
    }

    private var sessionTitle: String {
        if isStopwatchMode { return "Stopwatch" }
        if viewModel.activeMode == "Custom Timer" { return "Custom · \(viewModel.formattedCustomDuration)" }
        return "\(viewModel.activePreset) · \(viewModel.formattedCustomDuration)"
    }

    private var sessionIcon: String {
        isStopwatchMode ? "stopwatch" : "timer"
    }

    private var pageTitle: String {
        if isStopwatchMode { return "Stopwatch" }
        if viewModel.activeMode == "Custom Timer" { return "Custom timer" }
        if viewModel.activePreset == "Short Break" || viewModel.activePreset == "Long Break" { return "Break timer" }
        return "Focus timer"
    }

    private var pageSubtitle: String {
        if isStopwatchMode {
            return viewModel.isStopwatchRunning ? "Stopwatch in progress" : "Track exact split times & laps"
        } else {
            return viewModel.isTimerRunning ? "Session in progress" : "Make space for your next session"
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 720
            let availableW = geometry.size.width
            let availableH = geometry.size.height

            // Generous responsive container width
            let stageMaxWidth: CGFloat = min(availableW - (compact ? 32 : 64), max(680, min(availableW * 0.90, 1340)))

            // Smooth responsive clock size
            let rawClockSize = min(availableW * 0.52, availableH * 0.46)
            let clockSize: CGFloat = max(255, min(rawClockSize, 520))

            // Normalized stage height
            let rawStageHeight = availableH * 0.48
            let clockStageHeight: CGFloat = max(290, min(rawStageHeight, 540))

            VStack(spacing: compact ? 12 : 20) {
                // Top Header: Page Title and Navigation Shortcuts
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pageTitle)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(pageSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                            showingWorkspace = true
                        }
                    } label: {
                        Label("Workspace", systemImage: "rectangle.rightthird.inset.filled")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 104, minHeight: 38)
                    }
                    .buttonStyle(DashboardButtonStyle())

                    Button {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
                            isFocusState = true
                        }
                    } label: {
                        Label("Focus State", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 114, minHeight: 38)
                    }
                    .buttonStyle(DashboardButtonStyle())
                }
                .frame(maxWidth: stageMaxWidth)

                // Persistent Cross-Mode Floating Mini Bar
                if isStopwatchMode {
                    if viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime {
                        PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer) {
                            onSwitchToTimer?()
                        }
                        .frame(maxWidth: stageMaxWidth)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                } else {
                    if viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0 {
                        PersistentCrossModeMiniBar(viewModel: viewModel, type: .stopwatch) {
                            onSwitchToStopwatch?()
                        }
                        .frame(maxWidth: stageMaxWidth)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                Spacer(minLength: 4)

                // The Focus Stage Card: Houses the clock, preset toggles, and unified controls dock
                VStack(spacing: compact ? 16 : 24) {
                    // Stage Header: Preset selector (or Stopwatch Mode Pill) & Style segmented pills
                    HStack(spacing: 12) {
                        if isStopwatchMode {
                            HStack(spacing: 8) {
                                Image(systemName: "stopwatch.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.cyan)
                                Text("STOPWATCH MODE")
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(1.0)
                                    .foregroundColor(.cyan)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 38)
                            .background(Color.cyan.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.32), lineWidth: 1))
                        } else {
                            Menu {
                                Section("Timer sessions") {
                                    ForEach([("Focus", 25), ("Short Break", 5), ("Long Break", 15), ("Exam Run", 50)], id: \.0) { preset in
                                        Button { viewModel.requestPresetChange(name: preset.0, minutes: preset.1) } label: {
                                            Label("\(preset.0) · \(preset.1) min", systemImage: viewModel.activeMode == "Pomodoro" && viewModel.activePreset == preset.0 ? "checkmark" : "timer")
                                        }
                                    }
                                    Button {
                                        viewModel.changeMode(to: "Custom Timer")
                                        showingCustomPicker = true
                                    } label: {
                                        Label("Custom duration...", systemImage: "slider.horizontal.3")
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: sessionIcon)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.orange)
                                    Text(sessionTitle)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.gray)
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 38)
                                .background(
                                    Color.orange.opacity(isPresetHovered ? 0.20 : 0.12),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange.opacity(isPresetHovered ? 0.55 : 0.32), lineWidth: 1)
                                )
                                .contentShape(Capsule())
                            }
                            .menuStyle(.borderlessButton)
                            .contentShape(Capsule())
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isPresetHovered = hovering
                                }
                                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                            .accessibilityLabel("Session: \(sessionTitle)")

                            if viewModel.activeMode == "Custom Timer" {
                                HStack(spacing: 6) {
                                    Button {
                                        showingCustomPicker = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 11, weight: .bold))
                                            Text("Set time")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 38)
                                        .background(
                                            Color.white.opacity(isCustomPillHovered ? 0.16 : 0.08),
                                            in: Capsule()
                                        )
                                        .overlay(
                                            Capsule().stroke(Color.white.opacity(isCustomPillHovered ? 0.35 : 0.16), lineWidth: 1)
                                        )
                                        .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Capsule())
                                    .onHover { hovering in
                                        isCustomPillHovered = hovering
                                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                    }
                                    .popover(isPresented: $showingCustomPicker, arrowEdge: .bottom) {
                                        CustomDurationPopover(viewModel: viewModel, isPresented: $showingCustomPicker)
                                    }

                                    Button { viewModel.adjustCustomDuration(by: -1) } label: {
                                        Image(systemName: "minus")
                                            .font(.system(size: 12, weight: .bold))
                                            .frame(width: 38, height: 38)
                                            .contentShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .disabled(viewModel.isTimerRunning || viewModel.totalTime <= 10)
                                    .buttonStyle(DashboardButtonStyle())
                                    .help("Decrease by 1 minute")

                                    Button { viewModel.adjustCustomDuration(by: 1) } label: {
                                        Image(systemName: "plus")
                                            .font(.system(size: 12, weight: .bold))
                                            .frame(width: 38, height: 38)
                                            .contentShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .disabled(viewModel.isTimerRunning || viewModel.totalTime >= 360 * 60)
                                    .buttonStyle(DashboardButtonStyle())
                                    .help("Increase by 1 minute")
                                }
                            }
                        }

                        Spacer()

                        // Style Segmented Control with Full-Area Hit Testing & Hover States
                        HStack(spacing: 3) {
                            ForEach(["Digital", "Ring", "Analog"], id: \.self) { style in
                                StyleSegmentButton(
                                    title: style,
                                    icon: style == "Digital" ? "textformat.123" : (style == "Ring" ? "circle" : "clock"),
                                    isSelected: clockStyle == style
                                ) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        clockStyle = style
                                    }
                                }
                            }
                        }
                        .padding(4)
                        .background(Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }

                    // Main Clock Stage with Stable Height & Smooth Scaling
                    ClockFaceView(viewModel: viewModel, style: clockStyle, size: clockSize, isStopwatch: isStopwatchMode)
                        .frame(height: clockStageHeight)
                        .frame(maxWidth: .infinity)

                    // Unified Action Button Dock with Tactile Hover & 100% Hit Testing
                    HStack(spacing: 12) {
                        CapsuleActionButton(
                            icon: (isStopwatchMode ? viewModel.isStopwatchRunning : viewModel.isTimerRunning) ? "pause.fill" : "play.fill",
                            title: primaryActionTitle,
                            isPrimary: true,
                            isCyan: isStopwatchMode
                        ) {
                            if isStopwatchMode {
                                viewModel.toggleStopwatch()
                            } else {
                                viewModel.toggleTimer()
                            }
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .frame(minWidth: 145)

                        CapsuleActionButton(
                            icon: "arrow.counterclockwise",
                            title: "Reset",
                            isPrimary: false
                        ) {
                            viewModel.requestReset(isStopwatch: isStopwatchMode)
                        }
                        .frame(minWidth: 95)

                        if !isStopwatchMode {
                            CapsuleActionButton(
                                icon: "forward.end.fill",
                                title: "Skip",
                                isPrimary: false
                            ) {
                                viewModel.skipSession()
                            }
                            .frame(minWidth: 90)
                        }

                        CapsuleActionButton(
                            icon: isStopwatchMode ? "flag" : "square.and.pencil",
                            title: isStopwatchMode ? "Lap" : "Note",
                            isPrimary: false
                        ) {
                            viewModel.recordLapOrNote(isStopwatch: isStopwatchMode)
                        }
                        .frame(minWidth: 90)
                    }
                    .frame(maxWidth: .infinity)

                    // Integrated Stopwatch Laps View
                    if isStopwatchMode {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("LAPS & SPLITS")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundColor(.gray)
                                Spacer()
                                if !viewModel.lapTimes.isEmpty {
                                    Text("\(viewModel.lapTimes.count) recorded")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.cyan)
                                }
                            }
                            .frame(maxWidth: min(560, stageMaxWidth))

                            if viewModel.lapTimes.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "flag")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray.opacity(0.6))
                                    Text("Press 'Lap' to record splits (or Space to pause)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray.opacity(0.7))
                                }
                                .frame(maxWidth: min(560, stageMaxWidth))
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
                            } else {
                                ScrollView {
                                    VStack(spacing: 6) {
                                        ForEach(Array(viewModel.lapTimes.enumerated()), id: \.offset) { index, lapTime in
                                            HStack {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "flag.fill")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(index == 0 ? .cyan : .gray.opacity(0.5))
                                                    Text("Lap \(viewModel.lapTimes.count - index)")
                                                        .font(.system(size: 12, weight: index == 0 ? .semibold : .medium))
                                                        .foregroundColor(index == 0 ? .white : .gray)
                                                }
                                                Spacer()
                                                Text(lapTime)
                                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                    .foregroundColor(index == 0 ? .cyan : .white.opacity(0.85))
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color.white.opacity(index == 0 ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 0 ? Color.cyan.opacity(0.25) : Color.white.opacity(0.04), lineWidth: 1))
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .frame(maxWidth: min(560, stageMaxWidth), maxHeight: compact ? 110 : 140)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(compact ? 20 : 28)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.02))
                        .background(
                            RadialGradient(
                                colors: [(isStopwatchMode ? Color.cyan : Color.orange).opacity((isStopwatchMode ? viewModel.isStopwatchRunning : viewModel.isTimerRunning) ? 0.038 : 0.015), Color.clear],
                                center: .center,
                                startRadius: 40,
                                endRadius: 460
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.11), Color.white.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 24, y: 10)
                .frame(maxWidth: stageMaxWidth)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, compact ? 14 : 22)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockSize)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: stageMaxWidth)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockStageHeight)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockStyle)
        }
        .overlay {
            if viewModel.showPresetAlert {
                CustomConfirmModal(
                    title: "Change Preset?",
                    message: "Changing to \(viewModel.pendingPreset?.name ?? "a new preset") will end your current session progress.",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    confirmTitle: "Change Preset",
                    isDestructive: true,
                    onConfirm: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.applyPendingPreset()
                            viewModel.showPresetAlert = false
                        }
                    },
                    onCancel: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.cancelPendingPreset()
                            viewModel.showPresetAlert = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.94).combined(with: .opacity)
                ))
            }
            if viewModel.showResetAlert {
                CustomConfirmModal(
                    title: isStopwatchMode ? "Reset Stopwatch?" : "Reset Focus Timer?",
                    message: isStopwatchMode ? "This will reset your stopwatch and clear all recorded lap splits." : "This will reset your active focus session back to the beginning.",
                    icon: "arrow.counterclockwise.circle.fill",
                    iconColor: .red,
                    confirmTitle: "Reset Session",
                    isDestructive: true,
                    onConfirm: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            if isStopwatchMode {
                                viewModel.resetStopwatch()
                            } else {
                                viewModel.resetFocusTimer()
                            }
                            viewModel.showResetAlert = false
                        }
                    },
                    onCancel: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.showResetAlert = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.94).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showPresetAlert)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showResetAlert)
        .sheet(isPresented: $viewModel.showNoteEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a focus note").font(.title2.weight(.semibold))
                TextField("What do you want to remember?", text: $viewModel.noteDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.saveNote() }
                HStack {
                    Button("Cancel") { viewModel.showNoteEditor = false }
                    Spacer()
                    Button("Save Note") { viewModel.saveNote() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
    }
}
