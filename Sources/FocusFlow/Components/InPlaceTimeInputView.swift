import SwiftUI
import AppKit

// MARK: - In-Place Interactive Time Input View
/// Allows the user to directly click and edit minutes/seconds right inside the time display area,
/// and provides 1-click shortcut chips for effortless duration selection.
/// Built on a deterministic Draft -> Validate -> Commit transaction model with zero layout shift.
public struct InPlaceTimeInputView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public var size: CGFloat
    public var accentColor: Color = .orange
    public var isCompact: Bool = false

    // MARK: - Model Type Compatibility Wrapper
    public class Model: TimeInputController {
        public override init(totalTime: Int = 25 * 60) {
            super.init(totalTime: totalTime)
        }
    }

    public typealias TimeInputField = FocusFlow.TimeInputField

    @ObservedObject public var model: TimeInputController
    @State private var isMinutesHovered: Bool = false
    @State private var isSecondsHovered: Bool = false
    @State private var isMinusHovered: Bool = false
    @State private var isPlusHovered: Bool = false
    @State private var isPlus15Hovered: Bool = false

    public init(
        viewModel: TimerViewModel,
        size: CGFloat,
        accentColor: Color = .orange,
        isCompact: Bool = false,
        model: TimeInputController? = nil
    ) {
        self.viewModel = viewModel
        self.size = size
        self.accentColor = accentColor
        self.isCompact = isCompact
        // Stable ownership: default to viewModel's persistent controller to survive view reconstruction
        self.model = model ?? viewModel.customTimeInputController
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

    private func cardStrokeColor(for field: TimeInputField, isHovered: Bool) -> Color {
        if model.hasInvalidDraft {
            if model.validationErrorField == nil || model.validationErrorField == field {
                return Color(red: 1.0, green: 0.35, blue: 0.35)
            }
            return Color.white.opacity(isHovered ? 0.20 : 0.08)
        }
        if model.activeEditingField == field {
            return activeColor
        }
        return isHovered ? Color.white.opacity(0.24) : Color.white.opacity(0.09)
    }

    private func cardShadowColor(for field: TimeInputField) -> Color {
        if model.hasInvalidDraft {
            if model.validationErrorField == nil || model.validationErrorField == field {
                return Color.red.opacity(0.35)
            }
            return .clear
        }
        return model.activeEditingField == field ? activeColor.opacity(0.35) : .clear
    }

    public var body: some View {
        let isStageCompact = isCompact || size < 340
        // Desktop idle digits: prominent ~72-92pt with responsive scaling
        let digitFontSize: CGFloat = isStageCompact ? max(48, min(size * 0.17, 64)) : max(72, min(size * 0.21, 92))
        let colonFontSize: CGFloat = isStageCompact ? max(38, min(size * 0.13, 50)) : max(60, min(size * 0.175, 76))
        // Box widths: minutes fits up to 360 with generous margins; seconds fits 59 comfortably
        let minutesBoxWidth: CGFloat = isStageCompact ? max(120, min(size * 0.40, 150)) : max(176, min(size * 0.46, 196))
        let secondsBoxWidth: CGFloat = isStageCompact ? max(96, min(size * 0.30, 120)) : max(136, min(size * 0.35, 154))
        let boxHeight: CGFloat = isStageCompact ? max(72, min(size * 0.22, 84)) : max(96, min(size * 0.25, 110))
        let stepperSize: CGFloat = isStageCompact ? 36 : 42
        let stepperIconSize: CGFloat = isStageCompact ? 20 : 24

        VStack(spacing: max(10, size * 0.026)) {
            // MARK: - 1. Time Display & Quick Steppers (Optically & Vertically Centered)
            VStack(spacing: max(8, size * 0.020)) {
                HStack(alignment: .center, spacing: max(8, size * 0.022)) {
                    // -5m Quick Stepper (Seconds-Preserving, with boundary disable)
                    Button {
                        model.adjustMinutes(by: -5)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: stepperIconSize, weight: .semibold))
                            .foregroundColor(model.canAdjustMinus5 ? activeColor.opacity(0.90) : Color.white.opacity(0.20))
                            .frame(width: stepperSize, height: stepperSize)
                            .background(Color.white.opacity(isMinusHovered && model.canAdjustMinus5 ? 0.10 : 0.05), in: Circle())
                            .overlay(Circle().stroke(model.canAdjustMinus5 ? activeColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAdjustMinus5)
                    .onHover { h in isMinusHovered = h }
                    .accessibilityLabel("Subtract 5 minutes")
                    .help("Subtract 5 minutes (preserves seconds)")

                    // Minutes Input Card
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(model.activeEditingField == .minutes ? 0.09 : (isMinutesHovered ? 0.06 : 0.035)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(
                                        cardStrokeColor(for: .minutes, isHovered: isMinutesHovered),
                                        lineWidth: (model.activeEditingField == .minutes || (model.hasInvalidDraft && (model.validationErrorField == .minutes || model.validationErrorField == nil))) ? 2 : 1
                                    )
                            )
                            .shadow(color: cardShadowColor(for: .minutes), radius: 10)

                        if model.activeEditingField == .minutes {
                            TimeDigitField(
                                text: $model.inputMinutes,
                                placeholder: "MM",
                                fontSize: digitFontSize,
                                maxLength: 3,
                                onTab: {
                                    model.commitAndSwitchField(to: .seconds)
                                },
                                onBacktab: {
                                    model.commitEditing()
                                },
                                onReturn: {
                                    model.commitEditing()
                                },
                                onEscape: {
                                    model.cancelEditing()
                                },
                                onFocusLost: {
                                    DispatchQueue.main.async {
                                        if model.activeEditingField == .minutes {
                                            model.commitEditing()
                                        }
                                    }
                                }
                            )
                            .padding(.horizontal, 4)
                        } else {
                            Button {
                                if model.activeEditingField == .seconds {
                                    model.commitAndSwitchField(to: .minutes)
                                } else if model.activeEditingField != .minutes {
                                    model.startEditing(.minutes)
                                }
                            } label: {
                                Text(model.inputMinutes.isEmpty ? "MM" : model.inputMinutes)
                                    .font(.system(size: model.inputMinutes.isEmpty ? max(14, digitFontSize * 0.78) : digitFontSize, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(model.inputMinutes.isEmpty ? Color.white.opacity(0.30) : .white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.70)
                                    .padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    .frame(width: minutesBoxWidth, height: boxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onHover { h in isMinutesHovered = h }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Minutes, \(model.inputMinutes.isEmpty ? "empty" : model.inputMinutes)")
                    .accessibilityHint("Click to edit minutes")

                    // Colon Separator
                    Text(":")
                        .font(.system(size: colonFontSize, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: max(16, colonFontSize * 0.35))

                    // Seconds Input Card
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(model.activeEditingField == .seconds ? 0.09 : (isSecondsHovered ? 0.06 : 0.035)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(
                                        cardStrokeColor(for: .seconds, isHovered: isSecondsHovered),
                                        lineWidth: (model.activeEditingField == .seconds || (model.hasInvalidDraft && (model.validationErrorField == .seconds || model.validationErrorField == nil))) ? 2 : 1
                                    )
                            )
                            .shadow(color: cardShadowColor(for: .seconds), radius: 10)

                        if model.activeEditingField == .seconds {
                            TimeDigitField(
                                text: $model.inputSeconds,
                                placeholder: "SS",
                                fontSize: digitFontSize,
                                maxLength: 2,
                                onTab: {
                                    model.commitEditing()
                                },
                                onBacktab: {
                                    model.commitAndSwitchField(to: .minutes)
                                },
                                onReturn: {
                                    model.commitEditing()
                                },
                                onEscape: {
                                    model.cancelEditing()
                                },
                                onFocusLost: {
                                    DispatchQueue.main.async {
                                        if model.activeEditingField == .seconds {
                                            model.commitEditing()
                                        }
                                    }
                                }
                            )
                            .padding(.horizontal, 4)
                        } else {
                            Button {
                                if model.activeEditingField == .minutes {
                                    model.commitAndSwitchField(to: .seconds)
                                } else if model.activeEditingField != .seconds {
                                    model.startEditing(.seconds)
                                }
                            } label: {
                                Text(model.inputSeconds.isEmpty ? "SS" : model.inputSeconds)
                                    .font(.system(size: model.inputSeconds.isEmpty ? max(14, digitFontSize * 0.78) : digitFontSize, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(model.inputSeconds.isEmpty ? Color.white.opacity(0.30) : .white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.70)
                                    .padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    .frame(width: secondsBoxWidth, height: boxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onHover { h in isSecondsHovered = h }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Seconds, \(model.inputSeconds.isEmpty ? "empty" : model.inputSeconds)")
                    .accessibilityHint("Click to edit seconds")

                    // +5m Quick Stepper (Seconds-Preserving, with boundary disable)
                    Button {
                        model.adjustMinutes(by: 5)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: stepperIconSize, weight: .semibold))
                            .foregroundColor(model.canAdjustPlus5 ? activeColor.opacity(0.90) : Color.white.opacity(0.20))
                            .frame(width: stepperSize, height: stepperSize)
                            .background(Color.white.opacity(isPlusHovered && model.canAdjustPlus5 ? 0.10 : 0.05), in: Circle())
                            .overlay(Circle().stroke(model.canAdjustPlus5 ? activeColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAdjustPlus5)
                    .onHover { h in isPlusHovered = h }
                    .accessibilityLabel("Add 5 minutes")
                    .help("Add 5 minutes (preserves seconds)")
                }

                // Sublabels Row (Symmetrically aligned directly beneath the cards)
                HStack(spacing: max(8, size * 0.022)) {
                    Color.clear.frame(width: stepperSize, height: 12)

                    Text("MINUTES")
                        .font(.system(size: max(9, min(size * 0.024, 11)), weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(model.activeEditingField == .minutes ? activeColor : .gray.opacity(0.7))
                        .frame(width: minutesBoxWidth)

                    Text(":")
                        .font(.system(size: colonFontSize, weight: .bold, design: .rounded))
                        .opacity(0)
                        .frame(width: max(16, colonFontSize * 0.35), height: 12)

                    Text("SECONDS")
                        .font(.system(size: max(9, min(size * 0.024, 11)), weight: .bold))
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
                                model.selectPreset(minutes: chipM)
                            }
                        }
                    }

                    // +15m Quick Boost (Seconds-Preserving, with dedicated '+' icon)
                    let canPlus15 = model.canAdjustPlus15
                    Button {
                        model.adjustMinutes(by: 15)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: max(9, min(size * 0.024, 11)), weight: .bold))
                            Text("15m")
                                .font(.system(size: max(10, min(size * 0.026, 12)), weight: .semibold))
                        }
                        .foregroundColor(canPlus15 ? activeColor.opacity(0.95) : Color.white.opacity(0.20))
                        .padding(.horizontal, isStageCompact ? 6 : (size < 400 ? 8 : 10))
                        .frame(height: max(28, min(size * 0.070, 34)))
                        .background(Color.white.opacity(isPlus15Hovered && canPlus15 ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(canPlus15 ? activeColor.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPlus15)
                    .onHover { h in isPlus15Hovered = h }
                    .accessibilityLabel("Add 15 minutes")
                    .accessibilityHint(canPlus15 ? "Add 15 minutes to timer" : "Maximum timer limit reached")
                    .help(canPlus15 ? "Add 15 minutes to timer (preserves seconds)" : "Cannot add 15 minutes: reaches maximum duration (360:59)")
                }

                // MARK: - 3. Reserved 32pt Helper / Validation Row (Zero Layout Shift!)
                ZStack {
                    if let error = model.validationError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.40, blue: 0.40))
                            Text(error.localizedDescription)
                                .font(.system(size: max(10, min(size * 0.026, 12)), weight: .semibold))
                                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.25, green: 0.08, blue: 0.08).opacity(0.85), in: Capsule())
                        .overlay(Capsule().stroke(Color.red.opacity(0.35), lineWidth: 1))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Validation Error: \(error.localizedDescription)")
                    } else if model.activeEditingField != nil {
                        HStack(spacing: 10) {
                            Text("Enter to apply · Esc to cancel")
                                .font(.system(size: max(10, min(size * 0.026, 11)), weight: .medium))
                                .foregroundColor(activeColor.opacity(0.85))

                            Button {
                                model.commitEditing()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Apply")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(activeColor.opacity(0.30), in: Capsule())
                                .overlay(Capsule().stroke(activeColor.opacity(0.60), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Apply changes (Return)")

                            Button {
                                model.cancelEditing()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Cancel")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(.gray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.06), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("Cancel editing (Esc)")
                        }
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.gray.opacity(0.7))
                            Text("Click the time to edit · Enter to apply")
                                .font(.system(size: max(10, min(size * 0.026, 12)), weight: .medium))
                                .foregroundColor(.gray.opacity(0.8))
                        }
                    }
                }
                .frame(height: 32)
            }
            .padding(.top, 2)
        }
        .onExitCommand {
            model.cancelEditing()
        }
    }

    public func startEditing(_ field: TimeInputField) {
        model.startEditing(field)
    }

    public func stopEditing() {
        model.stopEditing()
    }

    public func cancelEditing() {
        model.cancelEditing()
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
                .frame(height: max(28, min(size * 0.070, 34)))
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
