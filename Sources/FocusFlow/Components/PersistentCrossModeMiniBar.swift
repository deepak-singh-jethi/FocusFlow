import SwiftUI
import AppKit

// MARK: - Persistent Cross-Mode Mini Bar
public struct PersistentCrossModeMiniBar: View {
    public enum BarType {
        case focusTimer
        case stopwatch
        case preservedSession
    }

    @ObservedObject public var viewModel: TimerViewModel
    public let type: BarType
    public var onSwitch: () -> Void

    @State private var isBarHovered = false
    @State private var isPlayHovered = false
    @State private var isSwitchHovered = false

    public init(viewModel: TimerViewModel, type: BarType, onSwitch: @escaping () -> Void) {
        self.viewModel = viewModel
        self.type = type
        self.onSwitch = onSwitch
    }

    private var barColor: Color {
        switch type {
        case .focusTimer:
            return viewModel.displayedTimerPreset.contains("Break") ? .teal : .orange
        case .stopwatch:
            return .cyan
        case .preservedSession:
            return (viewModel.preservedSession?.isBreakSession == true) ? .teal : .orange
        }
    }

    private var icon: String {
        switch type {
        case .focusTimer:
            return viewModel.displayedTimerPreset.contains("Break") ? "cup.and.saucer.fill" : "flame.fill"
        case .stopwatch:
            return "stopwatch.fill"
        case .preservedSession:
            return (viewModel.preservedSession?.isBreakSession == true) ? "cup.and.saucer.fill" : "flame.fill"
        }
    }

    private var label: String {
        switch type {
        case .focusTimer:
            let status = isRunning ? "ACTIVE" : "PAUSED"
            return "\(viewModel.displayedTimerPreset.uppercased()) SESSION \(status)"
        case .stopwatch:
            return viewModel.isStopwatchRunning ? "STOPWATCH ACTIVE" : "STOPWATCH PAUSED"
        case .preservedSession:
            let name = viewModel.preservedSession?.activePreset.uppercased() ?? "FOCUS"
            return "\(name) SESSION PAUSED"
        }
    }

    private var timeText: String {
        switch type {
        case .focusTimer:
            return viewModel.displayedTimerTimeString
        case .stopwatch:
            return viewModel.stopwatchTimeString
        case .preservedSession:
            return viewModel.preservedSession?.timeString ?? "00:00"
        }
    }

    private var isRunning: Bool {
        switch type {
        case .focusTimer:
            return viewModel.isDisplayedTimerRunning
        case .stopwatch:
            return viewModel.isStopwatchRunning
        case .preservedSession:
            return false
        }
    }

    private var switchButtonText: String {
        switch type {
        case .focusTimer:
            return viewModel.hasPreservedSession ? "Return to \(viewModel.displayedTimerPreset)" : "Open Focus Timer"
        case .stopwatch:
            return "Open Stopwatch"
        case .preservedSession:
            return "Return to \(viewModel.preservedSession?.activePreset ?? "Focus")"
        }
    }

    private var progressValue: Double {
        switch type {
        case .focusTimer:
            return viewModel.displayedTimerProgress
        case .stopwatch:
            return 0.0
        case .preservedSession:
            return viewModel.preservedSession?.preciseProgress ?? 1.0
        }
    }

    private func triggerSwitch() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            if type == .preservedSession {
                viewModel.restorePreservedSession()
            } else {
                viewModel.restorePreservedSessionIfNeeded()
            }
            onSwitch()
        }
    }

    public var body: some View {
        HStack(spacing: 14) {
            // Live Status Indicator & Session Label
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isRunning ? barColor.opacity(0.3) : Color.gray.opacity(0.15))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(isRunning ? barColor : Color.gray)
                        .frame(width: 8, height: 8)
                }

                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(barColor)
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(barColor)
                }
            }

            Spacer()

            // Big Live Time Display + Mini Progress if timer
            HStack(spacing: 12) {
                Text(timeText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)

                if type == .focusTimer || type == .preservedSession {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [barColor, .pink], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * max(0.001, progressValue))
                                .animation(.linear(duration: 0.025), value: progressValue)
                        }
                    }
                    .frame(width: 70, height: 5)
                }
            }

            Spacer()

            // Play / Pause Toggle
            Button {
                if type == .preservedSession {
                    viewModel.restorePreservedSession()
                    viewModel.startTimer()
                } else if type == .focusTimer {
                    if !viewModel.isTimerActive && viewModel.hasPreservedSession {
                        viewModel.restorePreservedSession()
                        viewModel.startTimer()
                    } else {
                        viewModel.toggleTimer()
                    }
                } else {
                    viewModel.toggleStopwatch()
                }
            } label: {
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(isPlayHovered ? 0.22 : 0.09), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(isPlayHovered ? 0.45 : 0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .onHover { h in
                isPlayHovered = h
                if h { NSCursor.pointingHand.set() } else if !isBarHovered { NSCursor.arrow.set() }
            }
            .help(isRunning ? "Pause" : "Resume")

            // Switch to full screen button
            Button(action: triggerSwitch) {
                HStack(spacing: 5) {
                    Text(switchButtonText)
                        .font(.system(size: 11, weight: .bold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(
                    LinearGradient(colors: [barColor, barColor.opacity(0.75)], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(Color.white.opacity(isSwitchHovered ? 0.55 : 0.22), lineWidth: 1))
                .shadow(color: barColor.opacity(isSwitchHovered ? 0.55 : 0.25), radius: 6)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .onHover { h in
                isSwitchHovered = h
                if h { NSCursor.pointingHand.set() } else if !isBarHovered { NSCursor.arrow.set() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color(red: isBarHovered ? 0.14 : 0.118, green: isBarHovered ? 0.15 : 0.128, blue: isBarHovered ? 0.21 : 0.178),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [
                            barColor.opacity(isBarHovered ? 0.65 : 0.38),
                            Color.white.opacity(isBarHovered ? 0.20 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isBarHovered ? 1.5 : 1
                )
        )
        .shadow(color: barColor.opacity(isBarHovered ? 0.28 : 0.10), radius: isBarHovered ? 12 : 6, y: 2)
        .scaleEffect(isBarHovered ? 1.004 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isBarHovered)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { h in
            isBarHovered = h
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onTapGesture {
            triggerSwitch()
        }
        .help(type == .focusTimer ? "Click anywhere to open Focus Timer" : "Click anywhere to open Stopwatch")
    }
}

// Legacy wrapper
public struct PersistentMiniTimerBar: View {
    @ObservedObject public var viewModel: TimerViewModel
    public var onReturn: () -> Void

    public init(viewModel: TimerViewModel, onReturn: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onReturn = onReturn
    }

    public var body: some View {
        PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer, onSwitch: onReturn)
    }
}
