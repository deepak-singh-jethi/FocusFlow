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

    public class Model: ObservableObject {
        @Published public var activeEditingField: TimeInputField? = nil
        @Published public var inputMinutes: String
        @Published public var inputSeconds: String

        public init(totalTime: Int) {
            let m = totalTime >= 60 ? totalTime / 60 : 0
            let s = totalTime % 60
            self.inputMinutes = "\(m)"
            self.inputSeconds = String(format: "%02d", s)
        }
    }

    public enum TimeInputField: Hashable {
        case minutes
        case seconds
    }

    @ObservedObject public var model: Model
    @FocusState var focusedField: TimeInputField?
    @State private var isMinutesHovered: Bool = false
    @State private var isSecondsHovered: Bool = false
    @State private var isSyncingProgrammatically: Bool = false

    public init(viewModel: TimerViewModel, size: CGFloat, accentColor: Color = .orange, isCompact: Bool = false, model: Model? = nil) {
        self.viewModel = viewModel
        self.size = size
        self.accentColor = accentColor
        self.isCompact = isCompact
        self.model = model ?? Model(totalTime: viewModel.totalTime)
    }

    public var activeEditingField: TimeInputField? {
        get { model.activeEditingField }
        nonmutating set { model.activeEditingField = newValue }
    }
    public var inputMinutes: String {
        get { model.inputMinutes }
        nonmutating set { model.inputMinutes = newValue }
    }
    public var inputSeconds: String {
        get { model.inputSeconds }
        nonmutating set { model.inputSeconds = newValue }
    }

    private var activeColor: Color {
        viewModel.isBreakPreset ? .teal : accentColor
    }

    public var body: some View {
        let isStageCompact = isCompact || size < 340
        let digitFontSize = max(32, min(size * 0.125, 48))
        let colonFontSize = max(26, min(size * 0.09, 36))
        let minutesBoxWidth = max(100, min(size * 0.30, 136))
        let secondsBoxWidth = max(100, min(size * 0.30, 136))
        let boxHeight = max(60, min(size * 0.19, 78))
        let stepperSize = max(30, min(size * 0.085, 38))
        let stepperIconSize = max(16, min(size * 0.048, 22))

        VStack(spacing: max(10, size * 0.026)) {
            // MARK: - 1. Time Display & Quick Steppers (Optically Centered)
            VStack(spacing: max(8, size * 0.022)) {
                HStack(alignment: .center, spacing: max(8, size * 0.022)) {
                    // -5m Quick Stepper
                    Button {
                        adjustMinutes(by: -5)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: stepperIconSize, weight: .semibold))
                            .foregroundColor(activeColor.opacity(0.85))
                            .frame(width: stepperSize, height: stepperSize)
                            .background(Color.white.opacity(0.06), in: Circle())
                            .overlay(Circle().stroke(activeColor.opacity(0.30), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Subtract 5 minutes")

                    // Minutes Input Card
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(model.activeEditingField == .minutes ? 0.08 : (isMinutesHovered ? 0.06 : 0.035)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(
                                        model.activeEditingField == .minutes
                                            ? activeColor
                                            : (isMinutesHovered ? Color.white.opacity(0.25) : Color.white.opacity(0.09)),
                                        lineWidth: model.activeEditingField == .minutes ? 2 : 1
                                    )
                            )
                            .shadow(color: model.activeEditingField == .minutes ? activeColor.opacity(0.35) : .clear, radius: 10)

                        if model.activeEditingField == .minutes {
                            TextField("25", text: $model.inputMinutes)
                                .font(.system(size: digitFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .multilineTextAlignment(.center)
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                                .padding(.horizontal, 4)
                                .focused($focusedField, equals: .minutes)
                                .onSubmit {
                                    applyCustomInput()
                                    startEditing(.seconds)
                                }
                                .onChange(of: model.inputMinutes) { _, newVal in
                                    handleMinutesChange(newVal)
                                }
                        } else {
                            Text(model.inputMinutes)
                                .font(.system(size: digitFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(width: minutesBoxWidth, height: boxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onHover { h in isMinutesHovered = h }
                    .onTapGesture {
                        startEditing(.minutes)
                    }

                    // Colon Separator
                    Text(":")
                        .font(.system(size: colonFontSize, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))

                    // Seconds Input Card
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(model.activeEditingField == .seconds ? 0.08 : (isSecondsHovered ? 0.06 : 0.035)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(
                                        model.activeEditingField == .seconds
                                            ? activeColor
                                            : (isSecondsHovered ? Color.white.opacity(0.25) : Color.white.opacity(0.09)),
                                        lineWidth: model.activeEditingField == .seconds ? 2 : 1
                                    )
                            )
                            .shadow(color: model.activeEditingField == .seconds ? activeColor.opacity(0.35) : .clear, radius: 10)

                        if model.activeEditingField == .seconds {
                            TextField("00", text: $model.inputSeconds)
                                .font(.system(size: digitFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .multilineTextAlignment(.center)
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                                .padding(.horizontal, 4)
                                .focused($focusedField, equals: .seconds)
                                .onSubmit {
                                    applyCustomInput()
                                    stopEditing()
                                }
                                .onChange(of: model.inputSeconds) { _, newVal in
                                    handleSecondsChange(newVal)
                                }
                        } else {
                            Text(model.inputSeconds)
                                .font(.system(size: digitFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(width: secondsBoxWidth, height: boxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onHover { h in isSecondsHovered = h }
                    .onTapGesture {
                        startEditing(.seconds)
                    }

                    // +5m Quick Stepper
                    Button {
                        adjustMinutes(by: 5)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: stepperIconSize, weight: .semibold))
                            .foregroundColor(activeColor.opacity(0.85))
                            .frame(width: stepperSize, height: stepperSize)
                            .background(Color.white.opacity(0.06), in: Circle())
                            .overlay(Circle().stroke(activeColor.opacity(0.30), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Add 5 minutes")
                }

                // Sublabels Row (Symmetrically aligned directly beneath the cards)
                HStack(spacing: max(8, size * 0.022)) {
                    Color.clear.frame(width: stepperSize, height: 12)

                    Text("MINUTES")
                        .font(.system(size: max(8, min(size * 0.024, 10)), weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(model.activeEditingField == .minutes ? activeColor : .gray.opacity(0.7))
                        .frame(width: minutesBoxWidth)

                    Text(":")
                        .font(.system(size: colonFontSize, weight: .bold, design: .rounded))
                        .opacity(0)
                        .frame(height: 12)

                    Text("SECONDS")
                        .font(.system(size: max(8, min(size * 0.024, 10)), weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(model.activeEditingField == .seconds ? activeColor : .gray.opacity(0.7))
                        .frame(width: secondsBoxWidth)

                    Color.clear.frame(width: stepperSize, height: 12)
                }
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
                            .padding(.horizontal, isStageCompact ? 6 : (size < 400 ? 8 : 10))
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
        .onExitCommand {
            cancelEditing()
        }
        .onChange(of: viewModel.totalTime) { _, _ in
            if model.activeEditingField == nil {
                syncInputFields()
            }
        }
        .onChange(of: focusedField) { _, newField in
            if newField == nil {
                applyCustomInput()
                model.activeEditingField = nil
                formatAndFinalizeFields()
            } else {
                model.activeEditingField = newField
            }
        }
    }

    public func startEditing(_ field: TimeInputField) {
        model.activeEditingField = field
        focusedField = field
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    public func stopEditing() {
        focusedField = nil
        model.activeEditingField = nil
        formatAndFinalizeFields()
    }

    public func cancelEditing() {
        syncInputFields()
        focusedField = nil
        model.activeEditingField = nil
    }

    private func syncInputFields() {
        isSyncingProgrammatically = true
        let m = viewModel.totalTime / 60
        let s = viewModel.totalTime % 60
        model.inputMinutes = "\(m)"
        model.inputSeconds = String(format: "%02d", s)
        DispatchQueue.main.async {
            isSyncingProgrammatically = false
        }
    }

    private func adjustMinutes(by delta: Int) {
        stopEditing()
        let currentM = Int(model.inputMinutes.filter { $0.isNumber }) ?? (viewModel.totalTime / 60)
        let newM = min(max(currentM + delta, 1), 360)
        model.inputMinutes = "\(newM)"
        model.inputSeconds = "00"
        if viewModel.isBreakPreset {
            viewModel.switchToBreak(minutes: newM)
        } else {
            viewModel.setCustomDuration(minutes: newM, seconds: 0)
        }
    }

    private func selectPreset(minutes: Int) {
        stopEditing()
        model.inputMinutes = "\(minutes)"
        model.inputSeconds = "00"
        if viewModel.isBreakPreset {
            viewModel.switchToBreak(minutes: minutes)
        } else {
            viewModel.setCustomDuration(minutes: minutes, seconds: 0)
        }
    }

    private func handleMinutesChange(_ newVal: String) {
        guard !isSyncingProgrammatically, model.activeEditingField == .minutes else { return }
        let digits = newVal.filter { $0.isNumber }
        if digits.count > 3 {
            model.inputMinutes = String(digits.prefix(3))
            return
        }
        if digits != newVal {
            model.inputMinutes = digits
        }
        if let val = Int(digits), val > 0 {
            let safeM = min(val, 360)
            let s = Int(model.inputSeconds.filter { $0.isNumber }) ?? (viewModel.totalTime % 60)
            if viewModel.isBreakPreset {
                let name = (safeM >= 15) ? "Long Break" : "Short Break"
                viewModel.requestModeOrPresetChange(name: name, minutes: safeM, seconds: s, mode: "Pomodoro", isBreak: true)
            } else {
                viewModel.setCustomDuration(minutes: safeM, seconds: s)
            }
        }
    }

    private func handleSecondsChange(_ newVal: String) {
        guard !isSyncingProgrammatically, model.activeEditingField == .seconds else { return }
        let digits = newVal.filter { $0.isNumber }
        if digits.count > 2 {
            model.inputSeconds = String(digits.prefix(2))
            return
        }
        if digits != newVal {
            model.inputSeconds = digits
        }
        if let val = Int(digits) {
            let safeS = min(val, 59)
            let m = Int(model.inputMinutes.filter { $0.isNumber }) ?? (viewModel.totalTime / 60)
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
        let m = min(max(Int(model.inputMinutes.filter { $0.isNumber }) ?? 0, 0), 360)
        let s = min(max(Int(model.inputSeconds.filter { $0.isNumber }) ?? 0, 0), 59)
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
        let m = max(Int(model.inputMinutes.filter { $0.isNumber }) ?? 0, (viewModel.totalTime >= 60 ? viewModel.totalTime / 60 : 0))
        let s = min(max(Int(model.inputSeconds.filter { $0.isNumber }) ?? 0, 0), 59)
        model.inputMinutes = "\(m)"
        model.inputSeconds = String(format: "%02d", s)
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
                .padding(.horizontal, isStageCompact ? 6 : (size < 400 ? 8 : 12))
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
