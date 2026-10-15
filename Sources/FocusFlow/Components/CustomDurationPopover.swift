import SwiftUI
import AppKit

// MARK: - Custom Duration Modal View (Centered Obsidian Overlay)
public struct CustomDurationModalView: View {
    @ObservedObject public var viewModel: TimerViewModel
    @Binding public var isPresented: Bool

    @State private var minutes: Int = 25
    @State private var seconds: Int = 0
    @State private var minutesString: String = "25"
    @State private var secondsString: String = "00"
    @State private var isSetHovered: Bool = false
    @State private var isCancelHovered: Bool = false

    public init(viewModel: TimerViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
    }

    private var totalSeconds: Int {
        minutes * 60 + seconds
    }

    private var formattedDisplay: String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private let quickPresetRows: [[(String, Int)]] = [
        [("5m", 5), ("10m", 10), ("15m", 15), ("20m", 20), ("25m", 25)],
        [("30m", 30), ("45m", 45), ("60m", 60), ("90m", 90), ("120m", 120)]
    ]

    public var body: some View {
        ZStack {
            // Dark scrim that dims background and catches background taps
            Color.black.opacity(0.74)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                        isPresented = false
                    }
                }

            // Obsidian Card
            VStack(spacing: 20) {
                // Header
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.orange)
                        Text("Custom Duration")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundColor(.gray.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }

                // Big Live Timer Display
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(formattedDisplay)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
                .padding(.vertical, 2)

                // Quick Preset Chips (Two balanced rows)
                VStack(alignment: .leading, spacing: 8) {
                    Text("QUICK PRESETS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.gray)

                    VStack(spacing: 7) {
                        ForEach(0..<quickPresetRows.count, id: \.self) { rowIndex in
                            HStack(spacing: 8) {
                                ForEach(quickPresetRows[rowIndex], id: \.0) { chip in
                                    QuickPresetChipView(
                                        title: chip.0,
                                        isSelected: minutes == chip.1 && seconds == 0
                                    ) {
                                        updateMinutes(to: chip.1)
                                        updateSeconds(to: 0)
                                    }
                                }
                            }
                        }
                    }
                }

                // Direct Inputs & Steppers
                HStack(spacing: 20) {
                    // Minutes Box
                    VStack(spacing: 6) {
                        Text("MINUTES")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.gray)

                        HStack(spacing: 5) {
                            stepperButton(label: "-5", disabled: minutes < 5) {
                                updateMinutes(to: max(0, minutes - 5))
                            }
                            stepperButton(icon: "minus", disabled: minutes <= 0 && seconds <= 10) {
                                updateMinutes(to: max(0, minutes - 1))
                            }

                            TextField("25", text: $minutesString)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 32)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .onSubmit { applyDuration() }
                                .onChange(of: minutesString) { _, newVal in
                                    let digits = newVal.filter { $0.isNumber }
                                    let val = min(Int(digits) ?? 0, 360)
                                    minutes = val
                                    if digits != newVal {
                                        minutesString = "\(val)"
                                    }
                                }

                            stepperButton(icon: "plus", disabled: minutes >= 360) {
                                updateMinutes(to: min(360, minutes + 1))
                            }
                            stepperButton(label: "+5", disabled: minutes >= 355) {
                                updateMinutes(to: min(360, minutes + 5))
                            }
                        }
                    }

                    Divider().frame(height: 48).overlay(Color.white.opacity(0.1))

                    // Seconds Box
                    VStack(spacing: 6) {
                        Text("SECONDS")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.0)
                            .foregroundColor(.gray)

                        HStack(spacing: 5) {
                            stepperButton(label: "-15", disabled: seconds < 15 && minutes == 0) {
                                updateSeconds(to: max(0, seconds - 15))
                            }

                            TextField("00", text: $secondsString)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .frame(width: 48, height: 32)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .onSubmit { applyDuration() }
                                .onChange(of: secondsString) { _, newVal in
                                    let digits = newVal.filter { $0.isNumber }
                                    let val = min(Int(digits) ?? 0, 59)
                                    seconds = val
                                    if digits != newVal {
                                        secondsString = String(format: "%02d", val)
                                    }
                                }

                            stepperButton(label: "+15", disabled: seconds >= 45) {
                                updateSeconds(to: min(59, seconds + 15))
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))

                if viewModel.isTimerRunning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("Setting a new duration will end your current session.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange.opacity(0.9))
                    }
                }

                // Actions
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                            isPresented = false
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isCancelHovered ? .white : .white.opacity(0.8))
                            .frame(minWidth: 84, minHeight: 38)
                            .background(Color.white.opacity(isCancelHovered ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .onHover { h in
                        isCancelHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }

                    Spacer()

                    Button {
                        applyDuration()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                            Text("Set Timer")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(Color(red: 0.10, green: 0.05, blue: 0.05))
                        .padding(.horizontal, 22)
                        .frame(minHeight: 38)
                        .background(
                            LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.42, blue: 0.30)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(isSetHovered ? 0.35 : 0.20), lineWidth: 1))
                        .shadow(color: Color.orange.opacity(isSetHovered ? 0.50 : 0.30), radius: 8, y: 2)
                        .scaleEffect(isSetHovered ? 1.02 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(totalSeconds < 5)
                    .onHover { h in
                        isSetHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
            }
            .padding(26)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.11, green: 0.12, blue: 0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.65), radius: 30, y: 12)
        }
        .onAppear {
            let total = viewModel.activeMode == "Custom Timer" ? viewModel.totalTime : viewModel.customDurationSeconds
            let m = max(0, total / 60)
            let s = total % 60
            minutes = (m == 0 && s == 0) ? 25 : m
            seconds = s
            minutesString = "\(minutes)"
            secondsString = String(format: "%02d", seconds)
        }
    }

    private func stepperButton(label: String? = nil, icon: String? = nil, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                } else if let label = label {
                    Text(label)
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundColor(disabled ? .gray.opacity(0.35) : .white.opacity(0.9))
            .frame(width: 30, height: 32)
            .background(Color.white.opacity(disabled ? 0.02 : 0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(disabled ? 0.02 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func updateMinutes(to val: Int) {
        minutes = val
        minutesString = "\(val)"
        if minutes == 0 && seconds < 10 {
            updateSeconds(to: 10)
        }
    }

    private func updateSeconds(to val: Int) {
        seconds = val
        secondsString = String(format: "%02d", val)
    }

    private func applyDuration() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            viewModel.setCustomDuration(minutes: minutes, seconds: seconds)
            isPresented = false
        }
    }
}

// Backward-compatible alias
public typealias CustomDurationPopover = CustomDurationModalView

// MARK: - Quick Preset Chip View
struct QuickPresetChipView: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
                .foregroundColor(isSelected ? .orange : .white.opacity(0.88))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.orange.opacity(0.20) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.orange.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
