import SwiftUI

// MARK: - Custom Duration Popover
public struct CustomDurationPopover: View {
    @ObservedObject public var viewModel: TimerViewModel
    @Binding public var isPresented: Bool

    @State private var minutes: Int = 25
    @State private var seconds: Int = 0
    @State private var minutesString: String = "25"
    @State private var secondsString: String = "00"

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

    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Duration")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("Set exact minutes and seconds")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }

            // Dual Stepper Controls (Minutes & Seconds)
            HStack(spacing: 14) {
                // Minutes Box
                VStack(spacing: 6) {
                    Text("MINUTES")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(.gray)

                    HStack(spacing: 6) {
                        Button {
                            adjustMinutes(by: -5)
                        } label: {
                            Text("-5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes < 5)

                        Button {
                            adjustMinutes(by: -1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes <= 0)

                        TextField("25", text: $minutesString)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .textFieldStyle(.plain)
                            .frame(width: 48, height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .onChange(of: minutesString) { _, newVal in
                                let digits = newVal.filter { $0.isNumber }
                                let val = min(Int(digits) ?? 0, 360)
                                minutes = val
                                if digits != newVal || val > 360 {
                                    minutesString = "\(val)"
                                }
                            }

                        Button {
                            adjustMinutes(by: 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 360)

                        Button {
                            adjustMinutes(by: 5)
                        } label: {
                            Text("+5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 355)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }

                // Seconds Box
                VStack(spacing: 6) {
                    Text("SECONDS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(.gray)

                    HStack(spacing: 6) {
                        Button {
                            adjustSeconds(by: -10)
                        } label: {
                            Text("-10")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(seconds < 10 && minutes == 0)

                        Button {
                            adjustSeconds(by: -5)
                        } label: {
                            Text("-5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(seconds <= 0 && minutes == 0)

                        TextField("00", text: $secondsString)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .textFieldStyle(.plain)
                            .frame(width: 44, height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .onChange(of: secondsString) { _, newVal in
                                let digits = newVal.filter { $0.isNumber }
                                let val = min(Int(digits) ?? 0, 59)
                                seconds = val
                                if digits != newVal || val > 59 {
                                    secondsString = String(format: "%02d", val)
                                }
                            }

                        Button {
                            adjustSeconds(by: 5)
                        } label: {
                            Text("+5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Button {
                            adjustSeconds(by: 10)
                        } label: {
                            Text("+10")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }
            }

            // Quick Preset Chips
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK PRESETS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.gray)

                HStack(spacing: 6) {
                    ForEach([("30s", 0, 30), ("1m", 1, 0), ("5m", 5, 0), ("10m", 10, 0), ("15m", 15, 0), ("25m", 25, 0), ("45m", 45, 0), ("60m", 60, 0)], id: \.0) { chip in
                        Button {
                            selectQuickPreset(min: chip.1, sec: chip.2)
                        } label: {
                            Text(chip.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(minutes == chip.1 && seconds == chip.2 ? .orange : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    minutes == chip.1 && seconds == chip.2 ? Color.orange.opacity(0.18) : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(minutes == chip.1 && seconds == chip.2 ? Color.orange.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Preview & Actions
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(formattedDisplay)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04), in: Capsule())

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(DashboardButtonStyle())

                Button {
                    viewModel.setCustomDuration(minutes: minutes, seconds: seconds)
                    isPresented = false
                } label: {
                    Text("Apply & Set Timer")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.1, green: 0.05, blue: 0.05))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.4, blue: 0.28)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(totalSeconds < 5)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 440)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
        .onAppear {
            let total = viewModel.totalTime
            minutes = total / 60
            seconds = total % 60
            minutesString = "\(minutes)"
            secondsString = String(format: "%02d", seconds)
        }
    }

    private func adjustMinutes(by delta: Int) {
        minutes = max(0, min(minutes + delta, 360))
        minutesString = "\(minutes)"
    }

    private func adjustSeconds(by delta: Int) {
        let newSec = seconds + delta
        if newSec < 0 {
            if minutes > 0 {
                minutes -= 1
                minutesString = "\(minutes)"
                seconds = 60 + newSec
            } else {
                seconds = 0
            }
        } else if newSec >= 60 {
            minutes = min(360, minutes + (newSec / 60))
            minutesString = "\(minutes)"
            seconds = newSec % 60
        } else {
            seconds = newSec
        }
        secondsString = String(format: "%02d", seconds)
    }

    private func selectQuickPreset(min: Int, sec: Int) {
        minutes = min
        seconds = sec
        minutesString = "\(min)"
        secondsString = String(format: "%02d", sec)
    }
}
