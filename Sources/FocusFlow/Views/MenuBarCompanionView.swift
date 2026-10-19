import SwiftUI
import AppKit

// MARK: - Menu Bar Label (System Status Bar Item)
public struct MenuBarLabelView: View {
    @ObservedObject public var viewModel: TimerViewModel

    public init(viewModel: TimerViewModel) {
        self.viewModel = viewModel
    }

    private var statusIcon: String {
        switch viewModel.selectedCompanionMode {
        case .stopwatch:
            return viewModel.isStopwatchRunning ? "stopwatch.fill" : "stopwatch"
        case .timer:
            if viewModel.isTimerRunning {
                return viewModel.isBreakPreset ? "cup.and.saucer.fill" : "flame.fill"
            } else if viewModel.isTimerActive {
                return viewModel.isBreakPreset ? "cup.and.saucer" : "flame"
            } else {
                return "timer"
            }
        }
    }

    private var displayTime: String {
        switch viewModel.selectedCompanionMode {
        case .stopwatch:
            return viewModel.stopwatchTimeString
        case .timer:
            return viewModel.timerTimeString
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
            Text(displayTime)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }
}

// MARK: - Redesigned Menu Bar Companion Popover
public struct MenuBarCompanionView: View {
    @ObservedObject public var viewModel: TimerViewModel
    @ObservedObject public var audioPlayer: AmbientAudioPlayer

    private var selectedMode: TimerViewModel.CompanionMode {
        viewModel.selectedCompanionMode
    }
    @StateObject private var companionController = TimeInputController()

    @State private var isPlayHovered: Bool = false
    @State private var isLapHovered: Bool = false
    @State private var isResetHovered: Bool = false
    @State private var isSkipHovered: Bool = false
    @State private var isOpenHovered: Bool = false
    @State private var isQuitHovered: Bool = false
    @State private var isMusicPlayHovered: Bool = false
    @State private var hoveredSound: String? = nil
    @State private var isConflictPrimaryHovered: Bool = false
    @State private var isConflictSecondaryHovered: Bool = false
    @State private var isConflictCloseHovered: Bool = false

    public init(viewModel: TimerViewModel, audioPlayer: AmbientAudioPlayer) {
        self.viewModel = viewModel
        self.audioPlayer = audioPlayer
    }

    private var isBreak: Bool {
        viewModel.isBreakPreset
    }

    public var body: some View {
        VStack(spacing: 12) {
            headerRow

            if viewModel.isPersistenceBlocked {
                storageErrorBanner
            } else if viewModel.isSaveFailed {
                saveFailureBanner
            } else if viewModel.didRecoverFromBackup && viewModel.showRecoveryNotice {
                recoverySuccessBanner
            }

            Group {
                modeSegmentedControl

                VStack(spacing: 12) {
                    if selectedMode == .timer {
                        if viewModel.showConflictModal && viewModel.conflictOrigin == .menuBar, let pending = viewModel.pendingTimerRequest {
                            compactConflictConfirmationCard(pending: pending)
                        } else {
                            interactiveTimerCard
                            timerActionButtonsRow
                            quickPresetRow
                        }
                    } else {
                        stopwatchDisplayCard
                        stopwatchActionButtonsRow
                        stopwatchLapsSection
                    }
                }
                .frame(minHeight: 172, alignment: .top)
            }
            .disabled(viewModel.isPersistenceBlocked)

            musicControlSection

            footerRow
        }
        .padding(14)
        .frame(width: 316)
        .background(Color(red: 0.08, green: 0.09, blue: 0.13))
        .onAppear {
            companionController.sync(from: viewModel.totalTime)
            companionController.onCommit = { [weak targetVM = viewModel] minutes, seconds in
                guard let viewModel = targetVM else { return }
                if viewModel.isBreakPreset {
                    let name = (minutes >= 15) ? "Long Break" : "Short Break"
                    viewModel.requestModeOrPresetChange(name: name, minutes: minutes, seconds: seconds, mode: "Pomodoro", isBreak: true, origin: .menuBar)
                } else {
                    viewModel.setCustomDuration(minutes: minutes, seconds: seconds, origin: .menuBar)
                }
            }
            if viewModel.isStopwatchRunning && !viewModel.isTimerRunning && !viewModel.isTimerActive {
                viewModel.selectedCompanionMode = .stopwatch
            } else if viewModel.isTimerRunning && !viewModel.isStopwatchRunning {
                viewModel.selectedCompanionMode = .timer
            }
        }
        .onChange(of: viewModel.totalTime) { _, _ in
            companionController.sync(from: viewModel.totalTime)
        }
        .onExitCommand {
            companionController.cancelEditing()
        }
    }

    // MARK: - 1. Top Header Row
    private var headerRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image(systemName: selectedMode == .stopwatch ? "stopwatch.fill" : "flame.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(selectedMode == .stopwatch ? .cyan : .orange)

                Text("FocusFlow")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Text(statusPillText)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusPillColor.opacity(0.18), in: Capsule())
                    .foregroundColor(statusPillColor)
            }

            Spacer()

            Button {
                openAndFocusMainWindow()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Open Main Window")
        }
    }

    private var statusPillText: String {
        if selectedMode == .stopwatch {
            return viewModel.isStopwatchRunning ? "RUNNING" : (viewModel.stopwatchTime > 0 ? "PAUSED" : "STOPWATCH")
        } else if viewModel.isTimerRunning {
            return isBreak ? "BREAK" : "RUNNING"
        } else if viewModel.isTimerActive {
            return "PAUSED"
        } else {
            return viewModel.activePreset.uppercased()
        }
    }

    private var statusPillColor: Color {
        if selectedMode == .stopwatch {
            return viewModel.isStopwatchRunning ? .cyan : (viewModel.stopwatchTime > 0 ? .yellow : .cyan)
        } else if isBreak {
            return .teal
        } else if viewModel.isTimerRunning {
            return .orange
        } else if viewModel.isTimerActive {
            return .yellow
        } else {
            return .orange
        }
    }

    // MARK: - 2. Mode Segmented Switcher (Timer vs Stopwatch)
    private var modeSegmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(TimerViewModel.CompanionMode.allCases, id: \.self) { mode in
                let isSelected = selectedMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.selectedCompanionMode = mode
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode == .timer ? "timer" : "stopwatch")
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                    }
                    .foregroundColor(isSelected ? .white : .gray)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.001),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - 3. Interactive In-Place Timer Card (Direct Input Time Area!)
    private var interactiveTimerCard: some View {
        VStack(spacing: 6) {
            if viewModel.isTimerRunning {
                // Live running view
                VStack(spacing: 5) {
                    Text(viewModel.timerTimeString)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .shadow(color: isBreak ? Color.teal.opacity(0.25) : Color.orange.opacity(0.30), radius: 8, y: 2)

                    // Running progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 4)

                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: isBreak
                                            ? [Color.teal, Color.cyan]
                                            : [Color.orange, Color(red: 1.0, green: 0.40, blue: 0.35)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(viewModel.fillAmount)), height: 4)
                                .animation(.linear(duration: 0.1), value: viewModel.fillAmount)
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 16)

                    HStack(spacing: 4) {
                        Text(isBreak ? "Break Session" : "Session \(viewModel.currentSession) of \(viewModel.totalSessions)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 2)
                }
            } else if viewModel.isTimerActive {
                // Paused view (exact remaining countdown)
                VStack(spacing: 5) {
                    Text(viewModel.timerTimeString)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .shadow(color: isBreak ? Color.teal.opacity(0.20) : Color.orange.opacity(0.20), radius: 6, y: 2)

                    // Paused progress bar (retains exact fill amount)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 4)

                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: isBreak
                                            ? [Color.teal.opacity(0.85), Color.cyan.opacity(0.85)]
                                            : [Color.orange.opacity(0.85), Color(red: 1.0, green: 0.40, blue: 0.35).opacity(0.85)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(viewModel.fillAmount)), height: 4)
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 16)

                    HStack(spacing: 4) {
                        Text(isBreak ? "Break Session • Paused" : "Session \(viewModel.currentSession) of \(viewModel.totalSessions) • Paused")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 2)
                }
            } else {
                // Direct Input Area: Click/type right inside where time is shown!
                VStack(spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        // -5m quick stepper (seconds-preserving)
                        Button {
                            companionController.adjustMinutes(by: -5)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.gray.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Subtract 5 minutes")
                        .help("Subtract 5 minutes (preserves seconds)")

                        // Minutes Direct Input Field
                        ZStack {
                            let isInvalid = companionController.hasInvalidDraft
                            let strokeColor = isInvalid ? Color(red: 1.0, green: 0.35, blue: 0.35) : (companionController.activeEditingField == .minutes ? Color.orange : Color.orange.opacity(0.40))
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(companionController.activeEditingField == .minutes ? 0.12 : 0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(strokeColor, lineWidth: (companionController.activeEditingField == .minutes || isInvalid) ? 2 : 1)
                                )

                            if companionController.activeEditingField == .minutes {
                                TimeDigitField(
                                    text: $companionController.inputMinutes,
                                    placeholder: "25",
                                    fontSize: 24,
                                    maxLength: 3,
                                    onTab: {
                                        companionController.commitAndSwitchField(to: .seconds)
                                    },
                                    onBacktab: {
                                        companionController.commitEditing()
                                    },
                                    onReturn: {
                                        companionController.commitEditing()
                                    },
                                    onEscape: {
                                        companionController.cancelEditing()
                                    },
                                    onFocusLost: {
                                        DispatchQueue.main.async {
                                            if companionController.activeEditingField == .minutes {
                                                companionController.commitEditing()
                                            }
                                        }
                                    }
                                )
                                .padding(.horizontal, 2)
                            } else {
                                Text(companionController.inputMinutes)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .padding(.horizontal, 2)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .onTapGesture {
                                        if companionController.activeEditingField == .seconds {
                                            companionController.commitAndSwitchField(to: .minutes)
                                        } else if companionController.activeEditingField != .minutes {
                                            companionController.startEditing(.minutes)
                                        }
                                    }
                            }
                        }
                        .frame(width: 68, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Minutes, \(companionController.inputMinutes)")
                        .accessibilityHint("Click to edit minutes")

                        Text(":")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.gray.opacity(0.7))

                        // Seconds Direct Input Field
                        ZStack {
                            let isInvalid = companionController.hasInvalidDraft
                            let strokeColor = isInvalid ? Color(red: 1.0, green: 0.35, blue: 0.35) : (companionController.activeEditingField == .seconds ? Color.orange : Color.white.opacity(0.15))
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(companionController.activeEditingField == .seconds ? 0.12 : 0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(strokeColor, lineWidth: (companionController.activeEditingField == .seconds || isInvalid) ? 2 : 1)
                                )

                            if companionController.activeEditingField == .seconds {
                                TimeDigitField(
                                    text: $companionController.inputSeconds,
                                    placeholder: "00",
                                    fontSize: 24,
                                    maxLength: 2,
                                    onTab: {
                                        companionController.commitEditing()
                                    },
                                    onBacktab: {
                                        companionController.commitAndSwitchField(to: .minutes)
                                    },
                                    onReturn: {
                                        companionController.commitEditing()
                                    },
                                    onEscape: {
                                        companionController.cancelEditing()
                                    },
                                    onFocusLost: {
                                        DispatchQueue.main.async {
                                            if companionController.activeEditingField == .seconds {
                                                companionController.commitEditing()
                                            }
                                        }
                                    }
                                )
                                .padding(.horizontal, 2)
                            } else {
                                Text(companionController.inputSeconds)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .padding(.horizontal, 2)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .onTapGesture {
                                        if companionController.activeEditingField == .minutes {
                                            companionController.commitAndSwitchField(to: .seconds)
                                        } else if companionController.activeEditingField != .seconds {
                                            companionController.startEditing(.seconds)
                                        }
                                    }
                            }
                        }
                        .frame(width: 68, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Seconds, \(companionController.inputSeconds)")
                        .accessibilityHint("Click to edit seconds")

                        // +5m quick stepper (seconds-preserving)
                        Button {
                            companionController.adjustMinutes(by: 5)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add 5 minutes")
                        .help("Add 5 minutes (preserves seconds)")
                    }

                    // Validation Error Banner (if invalid draft)
                    if let error = companionController.validationError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Color(red: 1.0, green: 0.40, blue: 0.40))
                            Text(error.localizedDescription)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                                .lineLimit(1)
                                .minimumScaleFactor(0.80)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.25, green: 0.08, blue: 0.08).opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red.opacity(0.30), lineWidth: 1))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Validation Error: \(error.localizedDescription)")
                    }

                    // Quick Chips directly inside the time input area
                    HStack(spacing: 5) {
                        ForEach([10, 15, 25, 30, 45, 60], id: \.self) { chipM in
                            let isCurrent = (viewModel.totalTime / 60) == chipM && (viewModel.totalTime % 60) == 0
                            Button {
                                companionController.selectPreset(minutes: chipM)
                            } label: {
                                Text("\(chipM)m")
                                    .font(.system(size: 10, weight: isCurrent ? .bold : .medium))
                                    .foregroundColor(isCurrent ? .white : .gray)
                                    .frame(maxWidth: .infinity, minHeight: 22)
                                    .background(
                                        isCurrent ? Color.orange.opacity(0.25) : Color.white.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(isCurrent ? Color.orange.opacity(0.5) : Color.white.opacity(0.05), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - 4. Timer Action Buttons
    private var timerActionButtonsRow: some View {
        HStack(spacing: 8) {
            // Start / Pause
            Button {
                if companionController.isEditing || companionController.hasInvalidDraft {
                    guard companionController.commitEditing() else { return }
                }
                viewModel.toggleTimer()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.isTimerRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(viewModel.isTimerRunning ? "Pause" : (viewModel.isTimerActive ? "Resume" : "Start"))
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(Color(red: 0.10, green: 0.05, blue: 0.05))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    LinearGradient(
                        colors: [.orange, Color(red: 1.0, green: 0.42, blue: 0.30)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(Color.white.opacity(isPlayHovered ? 0.35 : 0.20), lineWidth: 1))
                .shadow(color: Color.orange.opacity(isPlayHovered ? 0.45 : 0.25), radius: 6, y: 2)
                .scaleEffect(isPlayHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { h in
                isPlayHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            // Reset
            Button {
                viewModel.resetFocusTimer()
                companionController.cancelEditing()
                companionController.sync(from: viewModel.totalTime)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 72, height: 34)
                .background(Color.white.opacity(isResetHovered ? 0.10 : 0.05), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(isResetHovered ? 0.16 : 0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { h in
                isResetHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            // Skip
            Button {
                viewModel.skipSession()
                companionController.cancelEditing()
                companionController.sync(from: viewModel.totalTime)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Skip")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 68, height: 34)
                .background(Color.white.opacity(isSkipHovered ? 0.10 : 0.05), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(isSkipHovered ? 0.16 : 0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { h in
                isSkipHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }

    // MARK: - 5. Quick Preset Bar
    private var quickPresetRow: some View {
        HStack(spacing: 5) {
            presetButton(name: "Focus", minutes: 25, icon: "flame")
            presetButton(name: "Short Break", minutes: 5, icon: "cup.and.saucer")
            presetButton(name: "Long Break", minutes: 15, icon: "figure.walk")
            presetButton(name: "Custom", minutes: viewModel.customMinutes, icon: "slider.horizontal.3")
        }
    }

    private func presetButton(name: String, minutes: Int, icon: String) -> some View {
        let isSelected = viewModel.activePreset == name
        return Button {
            if name == "Custom" {
                viewModel.setCustomDuration(minutes: viewModel.customMinutes, seconds: 0, origin: .menuBar)
            } else {
                viewModel.requestPresetChange(name: name, minutes: minutes, origin: .menuBar)
            }
            companionController.sync(from: viewModel.totalTime)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text("\(minutes)m")
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : .gray)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(
                isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.orange.opacity(0.35) : Color.white.opacity(0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Compact Conflict Confirmation Card (Menu Bar)
    private func compactConflictConfirmationCard(pending: (name: String, minutes: Int, seconds: Int, mode: String, isBreak: Bool)) -> some View {
        let targetDuration = pending.seconds > 0 ? "\(pending.minutes)m \(pending.seconds)s" : "\(pending.minutes)m"
        return VStack(spacing: 9) {
            // Header with warning icon and close button
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)

                Text("Switch Active Session?")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Button {
                    viewModel.continueCurrentTimer()
                    companionController.sync(from: viewModel.totalTime)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(4)
                        .background(Color.white.opacity(isConflictCloseHovered ? 0.14 : 0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in isConflictCloseHovered = h }
                .help("Keep Current Session")
            }

            // Current vs Requested comparison
            HStack(alignment: .center, spacing: 6) {
                // Current session pill
                VStack(alignment: .leading, spacing: 2) {
                    Text("CURRENT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.gray)

                    Text(viewModel.displayedTimerPreset)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(viewModel.timerTimeString)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isBreak ? .teal : .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray.opacity(0.8))

                // Requested session pill
                VStack(alignment: .leading, spacing: 2) {
                    Text("REQUESTED")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.gray)

                    Text(pending.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(targetDuration)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(pending.isBreak ? .teal : .orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }

            // Explanatory warning note
            Text("Switching presets will end your current session.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // Action Buttons Row: Keep Current Session vs End & Switch
            HStack(spacing: 8) {
                Button {
                    viewModel.continueCurrentTimer()
                    companionController.sync(from: viewModel.totalTime)
                } label: {
                    Text("Keep Current Session")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                        .foregroundColor(.white.opacity(0.90))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(Color.white.opacity(isConflictSecondaryHovered ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(isConflictSecondaryHovered ? 0.20 : 0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .onHover { h in isConflictSecondaryHovered = h }
                .help("Cancel and keep running current session")

                Button {
                    viewModel.endAndSwitch()
                    companionController.sync(from: viewModel.totalTime)
                } label: {
                    Text("End & Switch")
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                        .foregroundColor(Color(red: 0.10, green: 0.05, blue: 0.05))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(
                            LinearGradient(
                                colors: [.orange, Color(red: 1.0, green: 0.42, blue: 0.30)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(isConflictPrimaryHovered ? 0.35 : 0.20), lineWidth: 1))
                        .shadow(color: Color.orange.opacity(isConflictPrimaryHovered ? 0.35 : 0.15), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .onHover { h in isConflictPrimaryHovered = h }
                .help("End current session and switch")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    // MARK: - 6. Stopwatch Display Card
    private var stopwatchDisplayCard: some View {
        VStack(spacing: 5) {
            Text(viewModel.stopwatchTimeString)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
                .shadow(color: Color.cyan.opacity(0.30), radius: 8, y: 2)

            HStack(spacing: 5) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan)

                Text("Stopwatch • \(viewModel.lapTimes.count) Laps Recorded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - 7. Stopwatch Action Buttons (Balanced & Functional!)
    private var stopwatchActionButtonsRow: some View {
        HStack(spacing: 8) {
            // Start / Pause (Stopwatch)
            Button {
                viewModel.toggleStopwatch()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.isStopwatchRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(viewModel.isStopwatchRunning ? "Pause" : "Start")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(Color(red: 0.05, green: 0.10, blue: 0.12))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(
                    LinearGradient(
                        colors: [.cyan, Color(red: 0.20, green: 0.65, blue: 0.95)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(Color.white.opacity(isPlayHovered ? 0.35 : 0.20), lineWidth: 1))
                .shadow(color: Color.cyan.opacity(isPlayHovered ? 0.45 : 0.25), radius: 6, y: 2)
                .scaleEffect(isPlayHovered ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { h in
                isPlayHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            // Lap (Stopwatch)
            Button {
                viewModel.recordLap()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Lap")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(viewModel.isStopwatchRunning ? .white.opacity(0.85) : .gray.opacity(0.4))
                .frame(width: 72, height: 34)
                .background(Color.white.opacity(isLapHovered ? 0.10 : 0.05), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(isLapHovered ? 0.16 : 0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isStopwatchRunning)
            .onHover { h in
                isLapHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            // Reset (Stopwatch)
            Button {
                viewModel.resetStopwatch()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(viewModel.stopwatchTime > 0 || !viewModel.lapTimes.isEmpty ? .white.opacity(0.85) : .gray.opacity(0.4))
                .frame(width: 72, height: 34)
                .background(Color.white.opacity(isResetHovered ? 0.10 : 0.05), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(isResetHovered ? 0.16 : 0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.stopwatchTime == 0 && viewModel.lapTimes.isEmpty)
            .onHover { h in
                isResetHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }

    // MARK: - 8. Stopwatch Laps List (Clean & Minimal)
    private var stopwatchLapsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.laps.isEmpty {
                HStack {
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("Tap \"Lap\" while running to record split times")
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.6))
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                HStack {
                    Text("RECENT LAPS")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.gray)

                    Spacer()

                    Text("\(viewModel.laps.count) total")
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .padding(.horizontal, 2)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(Array(viewModel.laps.enumerated()), id: \.element.id) { index, lap in
                            HStack {
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(index == 0 ? .cyan : .gray.opacity(0.5))

                                Text("Lap \(lap.lapNumber)")
                                    .font(.system(size: 11, weight: index == 0 ? .semibold : .medium))
                                    .foregroundColor(index == 0 ? .white : .gray)

                                Spacer()

                                Text("+ \(lap.formattedLapDuration)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.8))

                                Text(lap.formattedTotalTime)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(index == 0 ? .cyan : .white.opacity(0.8))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(index == 0 ? 0.06 : 0.02), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 76)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }

    // MARK: - 9. Ambient Music & Soundscape Controls
    private var musicControlSection: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: audioPlayer.isPlaying ? "waveform" : "headphones")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(audioPlayer.isPlaying ? .teal : .gray)

                    Text("SOUNDSCAPE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.gray)

                    if audioPlayer.isPlaying {
                        Text(audioPlayer.selectedSound.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.teal.opacity(0.18), in: Capsule())
                            .foregroundColor(.teal)
                    }
                }

                Spacer()

                // Play / Pause Toggle Button
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        if audioPlayer.isPlaying {
                            audioPlayer.stop()
                        } else {
                            audioPlayer.toggle(audioPlayer.selectedSound)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(audioPlayer.isPlaying ? "Pause" : "Play")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(audioPlayer.isPlaying ? Color(red: 0.05, green: 0.10, blue: 0.12) : .white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(
                        audioPlayer.isPlaying
                            ? LinearGradient(colors: [.teal, Color(red: 0.2, green: 0.85, blue: 0.8)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color.white.opacity(isMusicPlayHovered ? 0.16 : 0.10), Color.white.opacity(isMusicPlayHovered ? 0.12 : 0.06)], startPoint: .top, endPoint: .bottom),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().stroke(audioPlayer.isPlaying ? Color.teal.opacity(0.4) : Color.white.opacity(isMusicPlayHovered ? 0.25 : 0.12), lineWidth: 1)
                    )
                    .shadow(color: audioPlayer.isPlaying ? Color.teal.opacity(0.3) : Color.clear, radius: 4)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    isMusicPlayHovered = h
                    if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .help(audioPlayer.isPlaying ? "Pause ambient music" : "Play \(audioPlayer.selectedSound)")
            }

            // 1-Click Track Switcher: Rain, Ocean, Forest
            HStack(spacing: 6) {
                musicTrackPill(name: "Rain", icon: "cloud.rain.fill")
                musicTrackPill(name: "Ocean", icon: "water.waves")
                musicTrackPill(name: "Forest", icon: "leaf.fill")
            }

            if let errorMsg = audioPlayer.playbackError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    Text(errorMsg)
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(audioPlayer.isPlaying ? Color.teal.opacity(0.24) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func pillBackgroundColor(isPlayingThis: Bool, isSelected: Bool, isHovered: Bool) -> Color {
        if isPlayingThis {
            return Color.teal.opacity(0.32)
        } else if isSelected {
            return Color.white.opacity(0.12)
        } else if isHovered {
            return Color.white.opacity(0.07)
        } else {
            return Color.white.opacity(0.025)
        }
    }

    private func pillBorderColor(isPlayingThis: Bool, isSelected: Bool, isHovered: Bool) -> Color {
        if isPlayingThis {
            return Color.teal.opacity(0.50)
        } else if isSelected {
            return Color.white.opacity(0.22)
        } else if isHovered {
            return Color.white.opacity(0.14)
        } else {
            return Color.white.opacity(0.04)
        }
    }

    private func musicTrackPill(name: String, icon: String) -> some View {
        let isSelected = audioPlayer.selectedSound == name
        let isPlayingThis = isSelected && audioPlayer.isPlaying
        let isHovered = hoveredSound == name

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                audioPlayer.toggle(name)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(name)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isPlayingThis ? .white : (isSelected ? .white.opacity(0.9) : (isHovered ? .white : .gray)))
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                pillBackgroundColor(isPlayingThis: isPlayingThis, isSelected: isSelected, isHovered: isHovered),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        pillBorderColor(isPlayingThis: isPlayingThis, isSelected: isSelected, isHovered: isHovered),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            hoveredSound = h ? name : nil
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help(isPlayingThis ? "Pause \(name)" : "Switch to \(name)")
    }

    // MARK: - 10. Footer Row
    private var footerRow: some View {
        HStack {
            Button {
                openAndFocusMainWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10))
                    Text("Open Window")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(isOpenHovered ? .white : .gray)
            }
            .buttonStyle(.plain)
            .onHover { h in
                isOpenHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isQuitHovered ? .red.opacity(0.9) : .gray.opacity(0.75))
            }
            .buttonStyle(.plain)
            .onHover { h in
                isQuitHovered = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Window Management Helper
    private func openAndFocusMainWindow() {
        FocusFlowAppDelegate.shared?.showMainWindow()
    }

    // MARK: - Storage Safety Banners
    @ViewBuilder
    private var storageErrorBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.yellow)
            Text("Storage Error — Saving Blocked")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
        .help("Saved data could not be loaded. Saving is blocked to protect your existing file.")
    }

    @ViewBuilder
    private var recoverySuccessBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.green)
            Text("Recovered From Backup")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    viewModel.dismissRecoveryNotice()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var saveFailureBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.orange)
            Text("Changes Not Saved")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Button {
                viewModel.retrySave()
            } label: {
                Text("Retry")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .help(viewModel.saveErrorMessage ?? "Recent changes may not have been saved due to a storage error.")
    }
}
