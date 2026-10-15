import SwiftUI
import AppKit

// MARK: - Dashboard Timer View (Decomposed for Fast Swift Type-Checking)
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
    @State private var isFocusHovered = false
    @State private var isBreakHovered = false

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

    private var pageTitle: String {
        if isStopwatchMode { return "Stopwatch" }
        if viewModel.isBreakPreset { return "Break Timer" }
        if viewModel.activeMode == "Custom Timer" { return "Custom Timer" }
        return "Focus Timer"
    }

    private var pageSubtitle: String {
        if isStopwatchMode {
            return viewModel.isStopwatchRunning ? "Stopwatch in progress" : "Track exact split times & laps"
        } else if viewModel.isBreakPreset {
            return viewModel.isTimerRunning ? "Break in progress · Rest and recharge" : "Step away from the screen for a quick refresh"
        } else {
            return viewModel.isTimerRunning ? "Session in progress" : "Set duration directly on clock or click a shortcut"
        }
    }

    private var isClockStyleSwitchable: Bool {
        if isStopwatchMode {
            return viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0
        }
        return viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime
    }

    private var effectiveClockStyle: String {
        isClockStyleSwitchable ? clockStyle : "Digital"
    }

    // MARK: - Subviews (Extracted to guarantee instant compilation & avoid type-checker timeouts)
    @ViewBuilder
    private func headerSection(isCompact: Bool, stageMaxWidth: CGFloat) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pageTitle)
                    .font(.system(size: isCompact ? 20 : 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(pageSubtitle)
                    .font(.system(size: isCompact ? 11 : 12))
                    .foregroundColor(.gray)
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                    showingWorkspace = true
                }
            } label: {
                Label("Workspace", systemImage: "rectangle.rightthird.inset.filled")
                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                    .frame(minWidth: isCompact ? 86 : 104, minHeight: isCompact ? 34 : 38)
            }
            .buttonStyle(DashboardButtonStyle())

            Button {
                withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
                    isFocusState = true
                }
            } label: {
                Label("Focus State", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                    .frame(minWidth: isCompact ? 96 : 114, minHeight: isCompact ? 34 : 38)
            }
            .buttonStyle(DashboardButtonStyle())
        }
        .frame(maxWidth: stageMaxWidth)
    }

    @ViewBuilder
    private func crossModeMiniBarSection(stageMaxWidth: CGFloat) -> some View {
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
    }

    @ViewBuilder
    private func stageHeaderSection(isCompact: Bool, showPresetFullTitles: Bool, showStyleLabels: Bool, availableW: CGFloat) -> some View {
        HStack(spacing: 12) {
            if isStopwatchMode {
                HStack(spacing: 8) {
                    Image(systemName: "stopwatch.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                    Text(isCompact ? "STOPWATCH" : "STOPWATCH MODE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.cyan)
                }
                .padding(.horizontal, isCompact ? 12 : 16)
                .frame(minHeight: 36)
                .background(Color.cyan.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Color.cyan.opacity(0.32), lineWidth: 1))
            } else {
                HStack(spacing: 3) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            viewModel.switchToFocus(minutes: 25)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(showPresetFullTitles ? "Focus Session" : "Focus")
                                .font(.system(size: 11, weight: viewModel.isFocusPreset ? .bold : .medium))
                        }
                        .foregroundColor(
                            viewModel.isFocusPreset
                                ? .white
                                : (isFocusHovered ? .white.opacity(0.95) : .gray)
                        )
                        .padding(.horizontal, isCompact ? 10 : 14)
                        .frame(height: 32)
                        .background(
                            viewModel.isFocusPreset
                                ? Color.orange.opacity(0.24)
                                : (isFocusHovered ? Color.white.opacity(0.08) : Color.clear),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                viewModel.isFocusPreset
                                    ? Color.orange.opacity(0.40)
                                    : (isFocusHovered ? Color.white.opacity(0.18) : Color.clear),
                                lineWidth: 1
                            )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isFocusHovered = h
                        }
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .help(viewModel.isTimerActive && !viewModel.isFocusPreset ? "Switch to Focus Session (confirms ending break)" : "Switch to Focus Session")

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            viewModel.switchToBreak(minutes: 5)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "cup.and.saucer.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(showPresetFullTitles ? "Break" : "Break")
                                .font(.system(size: 11, weight: viewModel.isBreakPreset ? .bold : .medium))
                        }
                        .foregroundColor(
                            viewModel.isBreakPreset
                                ? .white
                                : (isBreakHovered ? .white.opacity(0.95) : .gray)
                        )
                        .padding(.horizontal, isCompact ? 10 : 14)
                        .frame(height: 32)
                        .background(
                            viewModel.isBreakPreset
                                ? Color.teal.opacity(0.24)
                                : (isBreakHovered ? Color.white.opacity(0.08) : Color.clear),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(
                                viewModel.isBreakPreset
                                    ? Color.teal.opacity(0.40)
                                    : (isBreakHovered ? Color.white.opacity(0.18) : Color.clear),
                                lineWidth: 1
                            )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isBreakHovered = h
                        }
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .help(viewModel.isTimerActive && viewModel.isFocusPreset ? "Switch to Break (confirms ending focus session)" : "Switch to Break Session")
                }
                .padding(3)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }

            Spacer()

            if availableW < 520 {
                Menu {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            clockStyle = "Digital"
                        }
                    } label: {
                        Label("Digital", systemImage: "textformat.123")
                    }
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            clockStyle = "Ring"
                        }
                    } label: {
                        Label("Ring", systemImage: "circle")
                    }
                    .disabled(!isClockStyleSwitchable)

                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            clockStyle = "Analog"
                        }
                    } label: {
                        Label("Analog", systemImage: "clock")
                    }
                    .disabled(!isClockStyleSwitchable)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: effectiveClockStyle == "Digital" ? "textformat.123" : (effectiveClockStyle == "Ring" ? "circle" : "clock"))
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.gray)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Change Clock Style")
            } else {
                HStack(spacing: 3) {
                    ForEach(["Digital", "Ring", "Analog"], id: \.self) { style in
                        let isStyleAvailable = (style == "Digital") || isClockStyleSwitchable
                        StyleSegmentButton(
                            title: showStyleLabels ? style : "",
                            icon: style == "Digital" ? "textformat.123" : (style == "Ring" ? "circle" : "clock"),
                            isSelected: effectiveClockStyle == style,
                            isEnabled: isStyleAvailable
                        ) {
                            guard isStyleAvailable else { return }
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                clockStyle = style
                            }
                        }
                        .help(isStyleAvailable ? "\(style) Style" : "\(style) is enabled while timer is running or paused")
                    }
                }
                .padding(4)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func actionDockSection(isCompact: Bool) -> some View {
        let dockButtonWidth: CGFloat = isCompact ? 86 : 108
        let dockSpacing: CGFloat = isCompact ? 8 : 12

        HStack(spacing: dockSpacing) {
            CapsuleActionButton(
                icon: (isStopwatchMode ? viewModel.isStopwatchRunning : viewModel.isTimerRunning) ? "pause.fill" : "play.fill",
                title: primaryActionTitle,
                isPrimary: true,
                isCyan: isStopwatchMode,
                isTeal: viewModel.isBreakPreset && !isStopwatchMode,
                compact: isCompact,
                buttonWidth: dockButtonWidth
            ) {
                if isStopwatchMode {
                    viewModel.toggleStopwatch()
                } else {
                    viewModel.toggleTimer()
                }
            }
            .keyboardShortcut(.space, modifiers: [])

            CapsuleActionButton(
                icon: "arrow.counterclockwise",
                title: "Reset",
                isPrimary: false,
                compact: isCompact,
                buttonWidth: dockButtonWidth
            ) {
                viewModel.requestReset(isStopwatch: isStopwatchMode)
            }

            if !isStopwatchMode {
                CapsuleActionButton(
                    icon: "forward.end.fill",
                    title: "Skip",
                    isPrimary: false,
                    compact: isCompact,
                    buttonWidth: dockButtonWidth
                ) {
                    viewModel.skipSession()
                }
            }

            CapsuleActionButton(
                icon: isStopwatchMode ? "flag" : "square.and.pencil",
                title: isStopwatchMode ? "Lap" : "Note",
                isPrimary: false,
                compact: isCompact,
                buttonWidth: dockButtonWidth
            ) {
                viewModel.recordLapOrNote(isStopwatch: isStopwatchMode)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stopwatchLapsSection(isCompact: Bool, stageMaxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LAPS & SPLITS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(.gray)
                Spacer()
                if !viewModel.laps.isEmpty {
                    Text("\(viewModel.laps.count) recorded")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                }
            }
            .frame(maxWidth: min(560, stageMaxWidth))

            if viewModel.laps.isEmpty {
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
                        ForEach(Array(viewModel.laps.enumerated()), id: \.element.id) { index, lap in
                            LapRowView(
                                index: index,
                                lap: lap,
                                isFastest: viewModel.fastestLapIndex == index,
                                isSlowest: viewModel.slowestLapIndex == index
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: min(560, stageMaxWidth), maxHeight: isCompact ? 110 : 140)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var confirmModalsOverlay: some View {
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
        if viewModel.showConflictModal, let pending = viewModel.pendingTimerRequest {
            let targetDuration = pending.seconds > 0 ? "\(pending.minutes)m \(pending.seconds)s" : "\(pending.minutes)m"
            TimerConflictSwitchModal(
                currentPresetName: viewModel.displayedTimerPreset,
                currentRemainingTime: viewModel.displayedTimerTimeString,
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

    public var body: some View {
        GeometryReader { geometry in
            let availableW = geometry.size.width
            let availableH = geometry.size.height
            let isCompact = availableW < 680 || availableH < 720
            let showPresetFullTitles = availableW >= 820
            let showStyleLabels = availableW >= 820

            // Responsive stage container width
            let stageHorizontalMargin: CGFloat = isCompact ? 16 : 24
            let stageMaxWidth: CGFloat = min(availableW - (stageHorizontalMargin * 2), 1160)

            // Smooth responsive clock size
            let rawClockSize = min(availableW * 0.48, availableH * 0.44)
            let clockSize: CGFloat = max(220, min(rawClockSize, 490))

            // Normalized stage height
            let rawStageHeight = availableH * 0.46
            let clockStageHeight: CGFloat = max(260, min(rawStageHeight, 520))

            VStack(spacing: isCompact ? 12 : 18) {
                // 1. Top Header Section
                headerSection(isCompact: isCompact, stageMaxWidth: stageMaxWidth)

                // 2. Persistent Cross-Mode Floating Mini Bar
                crossModeMiniBarSection(stageMaxWidth: stageMaxWidth)

                Spacer(minLength: 4)

                // 3. The Focus Stage Card
                VStack(spacing: isCompact ? 14 : 22) {
                    stageHeaderSection(
                        isCompact: isCompact,
                        showPresetFullTitles: showPresetFullTitles,
                        showStyleLabels: showStyleLabels,
                        availableW: availableW
                    )

                    ClockFaceView(viewModel: viewModel, style: effectiveClockStyle, size: clockSize, isStopwatch: isStopwatchMode)
                        .frame(height: clockStageHeight)
                        .frame(maxWidth: .infinity)

                    actionDockSection(isCompact: isCompact)

                    if isStopwatchMode {
                        stopwatchLapsSection(isCompact: isCompact, stageMaxWidth: stageMaxWidth)
                    }
                }
                .padding(isCompact ? 16 : 24)
                .frame(maxWidth: stageMaxWidth)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Color.white.opacity(0.02))
                        .background(
                            RadialGradient(
                                colors: [(isStopwatchMode ? Color.cyan : (viewModel.isBreakPreset ? Color.teal : Color.orange)).opacity((isStopwatchMode ? viewModel.isStopwatchRunning : viewModel.isTimerRunning) ? 0.045 : 0.015), Color.clear],
                                center: .center,
                                startRadius: 40,
                                endRadius: 460
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
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

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, stageHorizontalMargin)
            .padding(.vertical, isCompact ? 10 : 20)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockSize)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: stageMaxWidth)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockStageHeight)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockStyle)
            .onAppear {
                if !isClockStyleSwitchable && clockStyle != "Digital" {
                    clockStyle = "Digital"
                }
            }
            .onChange(of: isClockStyleSwitchable) { _, switchable in
                if !switchable && clockStyle != "Digital" {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        clockStyle = "Digital"
                    }
                }
            }
        }
        .overlay {
            confirmModalsOverlay
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showPresetAlert)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showResetAlert)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showConflictModal)
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

// MARK: - Precision Lap Row Subview (Priority 5)
struct LapRowView: View {
    let index: Int
    let lap: StopwatchLap
    let isFastest: Bool
    let isSlowest: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9))
                    .foregroundColor(isFastest ? .green : (isSlowest ? .orange : (index == 0 ? .cyan : .gray.opacity(0.5))))
                Text("Lap \(lap.lapNumber)")
                    .font(.system(size: 12, weight: index == 0 ? .semibold : .medium))
                    .foregroundColor(index == 0 ? .white : .gray)
                if isFastest {
                    Text("FASTEST")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundColor(.green)
                } else if isSlowest {
                    Text("SLOWEST")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            // Individual lap split duration
            Text("+ \(lap.formattedLapDuration)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(isFastest ? .green : (isSlowest ? .orange : .gray.opacity(0.8)))
            // Cumulative split time
            Text(lap.formattedTotalTime)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(index == 0 ? .cyan : .white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(index == 0 ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFastest ? Color.green.opacity(0.3) : (isSlowest ? Color.orange.opacity(0.3) : (index == 0 ? Color.cyan.opacity(0.25) : Color.white.opacity(0.04))), lineWidth: 1)
        )
    }
}
