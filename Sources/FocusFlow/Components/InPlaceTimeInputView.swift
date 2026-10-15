import SwiftUI
import AppKit

// MARK: - In-Place Interactive Time Input View
/// Allows the user to directly click and edit minutes/seconds right inside the time display area,
/// and provides 1-click shortcut chips ("click put time") for effortless duration selection.
public struct InPlaceTimeInputView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public var size: CGFloat
    public var accentColor: Color = .orange
    public var isCompact: Bool = false

    @State private var inputMinutes: String = "25"
    @State private var inputSeconds: String = "00"
    @FocusState private var focusedField: TimeInputField?
    @State private var isMinutesHovered: Bool = false
    @State private var isSecondsHovered: Bool = false
    @State private var isSyncingProgrammatically: Bool = false

    private enum TimeInputField: Hashable {
        case minutes
        case seconds
    }

    public init(viewModel: TimerViewModel, size: CGFloat, accentColor: Color = .orange, isCompact: Bool = false) {
        self.viewModel = viewModel
        self.size = size
        self.accentColor = accentColor
        self.isCompact = isCompact
    }

    private var activeColor: Color {
        viewModel.isBreakPreset ? .teal : accentColor
    }

    public var body: some View {
        let isStageCompact = isCompact || size < 340
        let digitFontSize = max(38, min(size * 0.20, 84))
        let colonFontSize = max(32, min(size * 0.17, 72))
        let minutesBoxWidth = max(86, min(size * 0.29, 142))
        let secondsBoxWidth = max(78, min(size * 0.26, 126))
        let boxHeight = max(52, min(size * 0.17, 78))
        let stepperSize = max(28, min(size * 0.08, 38))
        let stepperIconSize = max(15, min(size * 0.045, 22))

        VStack(spacing: max(10, size * 0.026)) {
            // MARK: - 1. Interactive Digits Row
            HStack(alignment: .center, spacing: max(6, size * 0.022)) {
                // -5m Quick Stepper
                Button {
                    adjustMinutes(by: -5)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: stepperIconSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.70))
                        .frame(width: stepperSize, height: stepperSize)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Subtract 5 minutes")

                // Minutes Input Card
                VStack(spacing: 3) {
                    TextField("25", text: $inputMinutes)
                        .font(.system(size: digitFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .focused($focusedField, equals: .minutes)
                        .frame(width: minutesBoxWidth, height: boxHeight)
                        .background(
                            Color.white.opacity(focusedField == .minutes ? 0.08 : (isMinutesHovered ? 0.06 : 0.035)),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    focusedField == .minutes
                                        ? activeColor
                                        : (isMinutesHovered ? Color.white.opacity(0.25) : Color.white.opacity(0.09)),
                                    lineWidth: focusedField == .minutes ? 2 : 1
                                )
                        )
                        .shadow(color: focusedField == .minutes ? activeColor.opacity(0.35) : .clear, radius: 10)
                        .onHover { h in isMinutesHovered = h }
                        .onSubmit {
                            applyCustomInput()
                            focusedField = .seconds
                        }
                        .onChange(of: inputMinutes) { _, newVal in
                            handleMinutesChange(newVal)
                        }

                    Text("MINUTES")
                        .font(.system(size: max(8, min(size * 0.024, 10)), weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(focusedField == .minutes ? activeColor : .gray.opacity(0.7))
                }

                // Colon Separator
                Text(":")
                    .font(.system(size: colonFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .offset(y: -6)

                // Seconds Input Card
                VStack(spacing: 3) {
                    TextField("00", text: $inputSeconds)
                        .font(.system(size: digitFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .focused($focusedField, equals: .seconds)
                        .frame(width: secondsBoxWidth, height: boxHeight)
                        .background(
                            Color.white.opacity(focusedField == .seconds ? 0.08 : (isSecondsHovered ? 0.06 : 0.035)),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(
                                    focusedField == .seconds
                                        ? activeColor
                                        : (isSecondsHovered ? Color.white.opacity(0.25) : Color.white.opacity(0.09)),
                                    lineWidth: focusedField == .seconds ? 2 : 1
                                )
                        )
                        .shadow(color: focusedField == .seconds ? activeColor.opacity(0.35) : .clear, radius: 10)
                        .onHover { h in isSecondsHovered = h }
                        .onSubmit {
                            applyCustomInput()
                            focusedField = nil
                        }
                        .onChange(of: inputSeconds) { _, newVal in
                            handleSecondsChange(newVal)
                        }

                    Text("SECONDS")
                        .font(.system(size: max(8, min(size * 0.024, 10)), weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(focusedField == .seconds ? activeColor : .gray.opacity(0.7))
                }

                // +5m Quick Stepper
                Button {
                    adjustMinutes(by: 5)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: stepperIconSize, weight: .semibold))
                        .foregroundColor(activeColor)
                        .frame(width: stepperSize, height: stepperSize)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(activeColor.opacity(0.30), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Add 5 minutes")
            }

            // MARK: - 2. Shortcut Inputs Bar ("Click Put Time")
            let shortcutDurations: [Int] = viewModel.isBreakPreset
                ? (isStageCompact ? [3, 5, 10, 15, 20] : [3, 5, 10, 15, 20, 30])
                : (isStageCompact ? [5, 10, 15, 25, 30, 45, 60] : [5, 10, 15, 20, 25, 30, 45, 60, 90])

            VStack(spacing: 8) {
                HStack(spacing: isStageCompact ? 5 : 8) {
                    ForEach(shortcutDurations, id: \.self) { chipM in
                        let isCurrent = (viewModel.totalTime / 60) == chipM && (viewModel.totalTime % 60) == 0

                        ShortcutChipButton(
                            minutes: chipM,
                            isCurrent: isCurrent,
                            accentColor: activeColor,
                            isStageCompact: isStageCompact,
                            size: size
                        ) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                selectPreset(minutes: chipM)
                            }
                        }
                    }

                    // +15m Quick Boost
                    Button {
                        adjustMinutes(by: 15)
                    } label: {
                        Text("+15m")
                            .font(.system(size: max(10, min(size * 0.026, 12)), weight: .semibold))
                            .foregroundColor(activeColor.opacity(0.95))
                            .padding(.horizontal, isStageCompact ? 6 : 10)
                            .frame(height: max(26, min(size * 0.066, 32)))
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(activeColor.opacity(0.30), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Add 15 minutes to timer")
                }

                // Helper Microcopy
                HStack(spacing: 5) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.7))
                    Text("Click numbers above to type custom time, or click a shortcut chip")
                        .font(.system(size: max(10, min(size * 0.026, 12)), weight: .medium))
                        .foregroundColor(.gray.opacity(0.8))
                }
            }
            .padding(.top, 2)
        }
        .onAppear {
            syncInputFields()
        }
        .onChange(of: viewModel.totalTime) { _, _ in
            if focusedField == nil {
                syncInputFields()
            }
        }
        .onChange(of: focusedField) { _, newField in
            if newField == nil {
                formatAndFinalizeFields()
            }
        }
    }

    private func syncInputFields() {
        isSyncingProgrammatically = true
        let m = viewModel.totalTime / 60
        let s = viewModel.totalTime % 60
        inputMinutes = "\(m)"
        inputSeconds = String(format: "%02d", s)
        DispatchQueue.main.async {
            isSyncingProgrammatically = false
        }
    }

    private func adjustMinutes(by delta: Int) {
        let currentM = Int(inputMinutes.filter { $0.isNumber }) ?? (viewModel.totalTime / 60)
        let newM = min(max(currentM + delta, 1), 360)
        inputMinutes = "\(newM)"
        inputSeconds = "00"
        if viewModel.isBreakPreset {
            viewModel.switchToBreak(minutes: newM)
        } else {
            viewModel.setCustomDuration(minutes: newM, seconds: 0)
        }
    }

    private func selectPreset(minutes: Int) {
        inputMinutes = "\(minutes)"
        inputSeconds = "00"
        if viewModel.isBreakPreset {
            viewModel.switchToBreak(minutes: minutes)
        } else {
            viewModel.setCustomDuration(minutes: minutes, seconds: 0)
        }
        focusedField = nil
    }

    private func handleMinutesChange(_ newVal: String) {
        guard !isSyncingProgrammatically, focusedField == .minutes else { return }
        let digits = newVal.filter { $0.isNumber }
        if digits.count > 3 {
            inputMinutes = String(digits.prefix(3))
            return
        }
        if digits != newVal {
            inputMinutes = digits
        }
        if let val = Int(digits), val > 0 {
            let safeM = min(val, 360)
            let s = Int(inputSeconds.filter { $0.isNumber }) ?? (viewModel.totalTime % 60)
            if viewModel.isBreakPreset {
                let name = (safeM >= 15) ? "Long Break" : "Short Break"
                viewModel.requestModeOrPresetChange(name: name, minutes: safeM, seconds: s, mode: "Pomodoro", isBreak: true)
            } else {
                viewModel.setCustomDuration(minutes: safeM, seconds: s)
            }
        }
    }

    private func handleSecondsChange(_ newVal: String) {
        guard !isSyncingProgrammatically, focusedField == .seconds else { return }
        let digits = newVal.filter { $0.isNumber }
        if digits.count > 2 {
            inputSeconds = String(digits.prefix(2))
            return
        }
        if digits != newVal {
            inputSeconds = digits
        }
        if let val = Int(digits) {
            let safeS = min(val, 59)
            let m = Int(inputMinutes.filter { $0.isNumber }) ?? (viewModel.totalTime / 60)
            let total = m * 60 + safeS
            if total >= 5 {
                if viewModel.isBreakPreset {
                    let name = (m >= 15) ? "Long Break" : "Short Break"
                    viewModel.requestModeOrPresetChange(name: name, minutes: m, seconds: safeS, mode: "Pomodoro", isBreak: true)
                } else {
                    viewModel.setCustomDuration(minutes: m, seconds: safeS)
                }
            }
        }
    }

    private func applyCustomInput() {
        guard !isSyncingProgrammatically else { return }
        let m = min(max(Int(inputMinutes.filter { $0.isNumber }) ?? 0, 0), 360)
        let s = min(max(Int(inputSeconds.filter { $0.isNumber }) ?? 0, 0), 59)
        let total = m * 60 + s
        if total >= 5 {
            if viewModel.isBreakPreset {
                let name = (m >= 15) ? "Long Break" : "Short Break"
                viewModel.requestModeOrPresetChange(name: name, minutes: m, seconds: s, mode: "Pomodoro", isBreak: true)
            } else {
                viewModel.setCustomDuration(minutes: m, seconds: s)
            }
        }
        formatAndFinalizeFields()
    }

    private func formatAndFinalizeFields() {
        let m = max(Int(inputMinutes.filter { $0.isNumber }) ?? 0, (viewModel.totalTime >= 60 ? viewModel.totalTime / 60 : 0))
        let s = min(max(Int(inputSeconds.filter { $0.isNumber }) ?? 0, 0), 59)
        inputMinutes = "\(m)"
        inputSeconds = String(format: "%02d", s)
    }
}

// MARK: - Shortcut Chip Subview
struct ShortcutChipButton: View {
    let minutes: Int
    let isCurrent: Bool
    let accentColor: Color
    let isStageCompact: Bool
    let size: CGFloat
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            Text("\(minutes)m")
                .font(.system(size: max(11, min(size * 0.028, 13)), weight: isCurrent ? .bold : .medium))
                .foregroundColor(textColor)
                .padding(.horizontal, isStageCompact ? 8 : 12)
                .frame(height: max(26, min(size * 0.066, 32)))
                .background(bgColor, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
                .shadow(color: isCurrent ? accentColor.opacity(0.35) : Color.clear, radius: 6)
        }
        .buttonStyle(.plain)
        .onHover { h in isHovered = h }
        .help("Set duration to \(minutes) minutes")
    }

    private var textColor: Color {
        if isCurrent || isHovered { return .white }
        return .white.opacity(0.75)
    }

    private var bgColor: Color {
        if isCurrent { return accentColor.opacity(0.28) }
        if isHovered { return Color.white.opacity(0.10) }
        return Color.white.opacity(0.04)
    }

    private var borderColor: Color {
        if isCurrent { return accentColor.opacity(0.65) }
        if isHovered { return Color.white.opacity(0.20) }
        return Color.white.opacity(0.08)
    }
}
