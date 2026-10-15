import SwiftUI

// MARK: - Clock Face Dispatcher
public struct ClockFaceView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public let style: String
    public let size: CGFloat
    public var minimal: Bool = false
    public var isStopwatch: Bool = false

    public init(viewModel: TimerViewModel, style: String, size: CGFloat, minimal: Bool = false, isStopwatch: Bool = false) {
        self.viewModel = viewModel
        self.style = style
        self.size = size
        self.minimal = minimal
        self.isStopwatch = isStopwatch
    }

    public var body: some View {
        Group {
            switch style {
            case "Analog":
                AnalogDialView(viewModel: viewModel, size: size, minimal: minimal, isStopwatch: isStopwatch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case "Ring":
                RingClockView(viewModel: viewModel, size: size, minimal: minimal, isStopwatch: isStopwatch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            default:
                DigitalClockView(viewModel: viewModel, size: size, minimal: minimal, isStopwatch: isStopwatch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.84), value: style)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isStopwatch ? "Stopwatch, \(viewModel.stopwatchTimeString)" : "\(viewModel.activePreset), \(viewModel.timerTimeString)")
    }
}

// MARK: - Digital Clock Face with Smooth Scaling for Fullscreen
public struct DigitalClockView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public let size: CGFloat
    public var minimal: Bool = false
    public var isStopwatch: Bool = false

    public init(viewModel: TimerViewModel, size: CGFloat, minimal: Bool = false, isStopwatch: Bool = false) {
        self.viewModel = viewModel
        self.size = size
        self.minimal = minimal
        self.isStopwatch = isStopwatch
    }

    private var subtitle: String {
        if isStopwatch { return "STOPWATCH" }
        return viewModel.activePreset.uppercased()
    }

    private var timeDisplay: String {
        isStopwatch ? viewModel.stopwatchTimeString : viewModel.timerTimeString
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    private var isPaused: Bool {
        !isStopwatch && !viewModel.isTimerRunning && (viewModel.timeRemaining < viewModel.totalTime)
    }

    private var isSettingTime: Bool {
        !minimal && !isStopwatch && !viewModel.isTimerRunning && (viewModel.timeRemaining == viewModel.totalTime)
    }

    public var body: some View {
        VStack(spacing: max(10, size * 0.03)) {
            if !minimal {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isStopwatch ? Color.cyan : (isPaused ? Color.yellow : Color.orange))
                        .frame(width: 6, height: 6)
                    Text(isPaused ? "PAUSED" : subtitle)
                        .font(.system(size: max(11, min(16, size * 0.032)), weight: .bold))
                        .tracking(2.2)
                        .foregroundColor(isStopwatch ? .cyan : (isPaused ? .yellow : .orange))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background((isStopwatch ? Color.cyan : (isPaused ? Color.yellow : Color.orange)).opacity(0.12), in: Capsule())
            }

            if isSettingTime {
                // Interactive In-Place Time Input & Shortcut Chips ("Click Put Time")
                InPlaceTimeInputView(
                    viewModel: viewModel,
                    size: size,
                    accentColor: viewModel.isBreakPreset ? .teal : .orange,
                    isCompact: minimal
                )
            } else {
                // Live running display / Paused display / Stopwatch display
                Text(timeDisplay)
                    .font(.system(size: min(size * 0.38, 205), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(isRunning ? 0.35 : 0.0), radius: 28)

                if !minimal && !isStopwatch && viewModel.tasks.indices.contains(viewModel.activeTaskIndex) {
                    let task = viewModel.tasks[viewModel.activeTaskIndex]
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: max(11, min(14, size * 0.026))))
                            .foregroundColor(.orange)
                        Text(task.title)
                            .font(.system(size: max(12, min(17, size * 0.034)), weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Text("·")
                            .foregroundColor(.gray.opacity(0.6))
                        Text("\(task.formattedTimeSpent) spent")
                            .font(.system(size: max(11, min(14, size * 0.026)), weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: min(size * 1.4, 720))
                }

                if !minimal && !isStopwatch {
                    VStack(spacing: 8) {
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: bar.size.width * max(0.001, viewModel.preciseProgress))
                                    .shadow(color: .orange.opacity(0.4), radius: 4)
                                    .animation(.linear(duration: 0.1), value: viewModel.preciseProgress)
                            }
                        }
                        .frame(width: min(size * 1.30, 720), height: max(6, min(10, size * 0.018)))

                        HStack {
                            Text("\(Int(viewModel.preciseProgress * 100))% completed")
                                .font(.system(size: max(11, min(14, size * 0.026)), weight: .semibold))
                                .foregroundColor(.gray)
                            Spacer()
                            Text(viewModel.timeRemaining >= 60 ? "\(viewModel.timeRemaining / 60) min remaining" : "\(viewModel.timeRemaining)s remaining")
                                .font(.system(size: max(11, min(14, size * 0.026)), weight: .semibold))
                                .foregroundColor(.gray)
                        }
                        .frame(width: min(size * 1.30, 720))
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: size)
    }
}

// MARK: - Ring Clock Face with Smooth Continuous Sweep
public struct RingClockView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public let size: CGFloat
    public var minimal: Bool = false
    public var isStopwatch: Bool = false

    public init(viewModel: TimerViewModel, size: CGFloat, minimal: Bool = false, isStopwatch: Bool = false) {
        self.viewModel = viewModel
        self.size = size
        self.minimal = minimal
        self.isStopwatch = isStopwatch
    }

    private var subtitle: String {
        if isStopwatch { return "STOPWATCH" }
        return viewModel.activePreset.uppercased()
    }

    private var timeDisplay: String {
        isStopwatch ? viewModel.stopwatchTimeString : viewModel.timerTimeString
    }

    private var progress: Double {
        isStopwatch ? viewModel.preciseStopwatchProgress : viewModel.preciseProgress
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    private var isPaused: Bool {
        !isStopwatch && !viewModel.isTimerRunning && (viewModel.timeRemaining < viewModel.totalTime)
    }

    public var body: some View {
        let strokeWidth: CGFloat = max(12, min(28, size * 0.045))
        let ringDiameter = size * 0.85

        ZStack {
            // Background track
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: strokeWidth)
                .frame(width: ringDiameter, height: ringDiameter)

            // Dynamic progress ring with continuous flowing sweep
            Circle()
                .trim(from: 0, to: max(0.0008, progress))
                .stroke(
                    LinearGradient(
                        colors: isStopwatch ? [Color.cyan, Color.blue] : [Color.orange, Color.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: ringDiameter, height: ringDiameter)
                .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(isRunning ? 0.45 : 0.2), radius: 8)
                .animation(.linear(duration: 0.1), value: progress)

            // Center Content (Always Clean & Distraction-Free)
            VStack(spacing: max(6, size * 0.022)) {
                if !minimal {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isStopwatch ? Color.cyan : (isPaused ? Color.yellow : Color.orange))
                            .frame(width: 6, height: 6)
                        Text(isPaused ? "PAUSED" : subtitle)
                            .font(.system(size: max(11, min(15, size * 0.032)), weight: .bold))
                            .tracking(2)
                            .foregroundColor(isStopwatch ? .cyan : (isPaused ? .yellow : .orange))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background((isStopwatch ? Color.cyan : (isPaused ? Color.yellow : Color.orange)).opacity(0.12), in: Capsule())
                }

                Text(timeDisplay)
                    .font(.system(size: min(size * 0.24, 135), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if !minimal && !isStopwatch && viewModel.tasks.indices.contains(viewModel.activeTaskIndex) {
                    let task = viewModel.tasks[viewModel.activeTaskIndex]
                    VStack(spacing: 2) {
                        Text(task.title)
                            .font(.system(size: max(11, min(15, size * 0.030)), weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                        Text("\(task.formattedTimeSpent) spent · \(task.expectedTime) est.")
                            .font(.system(size: max(10, min(12, size * 0.024)), weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    .frame(maxWidth: size * 0.68)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: size)
    }
}

// MARK: - Precision Horology Analog Dial with Continuous Sweep
public struct AnalogDialView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public let size: CGFloat
    public var minimal: Bool = false
    public var isStopwatch: Bool = false

    public init(viewModel: TimerViewModel, size: CGFloat, minimal: Bool = false, isStopwatch: Bool = false) {
        self.viewModel = viewModel
        self.size = size
        self.minimal = minimal
        self.isStopwatch = isStopwatch
    }

    private var scaleMinutes: Int {
        isStopwatch ? 60 : max(60, Int(ceil(Double(viewModel.totalTime) / 3600)) * 60)
    }

    private var progress: Double {
        if isStopwatch {
            return viewModel.preciseStopwatchProgress
        }
        let total = Double(max(scaleMinutes * 60, 1))
        guard let target = viewModel.targetEndDate, viewModel.isTimerRunning else {
            return min(max(Double(viewModel.timeRemaining) / total, 0), 1)
        }
        return min(max(target.timeIntervalSinceNow / total, 0), 1)
    }

    private var timeDisplay: String {
        isStopwatch ? viewModel.stopwatchTimeString : viewModel.timerTimeString
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    private var isPaused: Bool {
        !isStopwatch && !viewModel.isTimerRunning && (viewModel.timeRemaining < viewModel.totalTime)
    }

    public var body: some View {
        let dialDiameter = size * 0.88

        VStack(spacing: max(10, size * 0.024)) {
            ZStack {
                // Outer Bezel & Subtle Depth
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.12, green: 0.13, blue: 0.18), Color(red: 0.07, green: 0.075, blue: 0.10)],
                            center: .center,
                            startRadius: 0,
                            endRadius: dialDiameter * 0.5
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.20), Color.white.opacity(0.04), Color.white.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(2, dialDiameter * 0.006)
                            )
                    )
                    .frame(width: dialDiameter, height: dialDiameter)

                // Concentric Interior Track Grooves
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .frame(width: dialDiameter * 0.84, height: dialDiameter * 0.84)
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    .frame(width: dialDiameter * 0.44, height: dialDiameter * 0.44)

                // Luminous Active Countdown / Elapsed Arc along Track
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        LinearGradient(
                            colors: isStopwatch ? [Color.cyan, Color.blue] : [Color.orange, Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: max(3.5, dialDiameter * 0.012), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: dialDiameter * 0.84, height: dialDiameter * 0.84)
                    .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(0.45), radius: 6)
                    .animation(.linear(duration: 0.1), value: progress)

                // 60-Minute Precision Tick Marks
                ForEach(0..<60, id: \.self) { mark in
                    let isMajor = mark.isMultiple(of: 5)
                    Capsule()
                        .fill(isMajor ? Color.white.opacity(0.85) : Color.white.opacity(0.25))
                        .frame(
                            width: isMajor ? max(2, dialDiameter * 0.006) : max(1, dialDiameter * 0.003),
                            height: isMajor ? max(8, dialDiameter * 0.026) : max(4, dialDiameter * 0.013)
                        )
                        .offset(y: -dialDiameter * 0.42)
                        .rotationEffect(.degrees(Double(mark) * 6))
                }

                // 12-Position Numerals
                ForEach(0..<12, id: \.self) { label in
                    let angle = Double(label) * .pi / 6
                    let numRadius = dialDiameter * 0.34
                    let minuteVal = label * scaleMinutes / 12
                    Text("\(minuteVal)")
                        .font(.system(size: max(10, dialDiameter * 0.035), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(label == 0 ? (isStopwatch ? .cyan : .orange) : Color.white.opacity(0.75))
                        .position(
                            x: dialDiameter * 0.5 + sin(angle) * numRadius,
                            y: dialDiameter * 0.5 - cos(angle) * numRadius
                        )
                }

                // Horological Needle Pointer
                Group {
                    // Counterweight tail
                    Capsule()
                        .fill(Color(red: 0.18, green: 0.19, blue: 0.26))
                        .frame(width: max(3.5, dialDiameter * 0.013), height: dialDiameter * 0.08)
                        .offset(y: dialDiameter * 0.04)

                    // Slender Tapered Pointer Hand
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: isStopwatch ? [Color.cyan, Color.blue] : [Color.orange, Color(red: 1.0, green: 0.4, blue: 0.25)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: max(3, dialDiameter * 0.011), height: dialDiameter * 0.25)
                        .offset(y: -dialDiameter * 0.125)
                        .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(0.4), radius: 6)

                    // Outer Track Pip Indicator
                    Circle()
                        .fill(isStopwatch ? Color.cyan : Color.orange)
                        .frame(width: max(6, dialDiameter * 0.018), height: max(6, dialDiameter * 0.018))
                        .offset(y: -dialDiameter * 0.42)
                        .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(0.6), radius: 4)
                }
                .rotationEffect(.degrees(progress * 360))
                .animation(.linear(duration: 0.1), value: progress)

                // Precision Dual-Ring Center Hub
                Circle()
                    .fill(Color(red: 0.14, green: 0.15, blue: 0.20))
                    .frame(width: max(14, dialDiameter * 0.06), height: max(14, dialDiameter * 0.06))
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                Circle()
                    .fill(isStopwatch ? Color.cyan : Color.orange)
                    .frame(width: max(6, dialDiameter * 0.024), height: max(6, dialDiameter * 0.024))
            }
            .frame(width: dialDiameter, height: dialDiameter)

            // Integrated Readout Pill
            if !minimal {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isRunning ? (isStopwatch ? Color.cyan : Color.orange) : (isPaused ? Color.yellow : Color.gray))
                        .frame(width: 6, height: 6)
                    Text(timeDisplay)
                        .font(.system(size: max(18, dialDiameter * 0.055), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                    Text(isStopwatch ? "ELAPSED" : (isPaused ? "PAUSED" : "REMAINING"))
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(isPaused ? .yellow : .gray)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: size)
    }
}
