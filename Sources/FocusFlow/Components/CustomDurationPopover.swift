import SwiftUI

// MARK: - Custom Duration Modal View
public struct CustomDurationModalView: View {
    @ObservedObject public var viewModel: TimerViewModel
    @Binding public var isPresented: Bool

    @State private var minutes: Int = 25
    @State private var seconds: Int = 0

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

    private let quickPresets: [(String, Int)] = [
        ("5m", 5),
        ("15m", 15),
        ("25m", 25),
        ("30m", 30),
        ("45m", 45),
        ("60m", 60),
        ("90m", 90)
    ]

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom Duration")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Text("Set exact time for your custom focus session")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.gray.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            // Big Timer Display
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.orange)
                Text(formattedDisplay)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.vertical, 6)

            // Direct Adjusters: Minutes & Seconds
            HStack(spacing: 20) {
                // Minutes
                VStack(spacing: 8) {
                    Text("MINUTES")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.gray)

                    HStack(spacing: 6) {
                        Button {
                            minutes = max(0, minutes - 5)
                            if minutes == 0 && seconds < 10 { seconds = 10 }
                        } label: {
                            Text("-5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 30, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes < 5)

                        Button {
                            minutes = max(0, minutes - 1)
                            if minutes == 0 && seconds < 10 { seconds = 10 }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes <= 0 && seconds <= 10)

                        Text("\(minutes)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                        Button {
                            minutes = min(360, minutes + 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 360)

                        Button {
                            minutes = min(360, minutes + 5)
                        } label: {
                            Text("+5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 30, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 355)
                    }
                }

                Divider().frame(height: 50).overlay(Color.white.opacity(0.1))

                // Seconds
                VStack(spacing: 8) {
                    Text("SECONDS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(.gray)

                    HStack(spacing: 6) {
                        Button {
                            seconds = max(0, seconds - 15)
                            if minutes == 0 && seconds < 10 { seconds = 10 }
                        } label: {
                            Text("-15")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(seconds < 15 && minutes == 0)

                        Text(String(format: "%02d", seconds))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                        Button {
                            let next = seconds + 15
                            if next >= 60 {
                                minutes = min(360, minutes + 1)
                                seconds = next % 60
                            } else {
                                seconds = next
                            }
                        } label: {
                            Text("+15")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 360 && seconds >= 45)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))

            // Quick Presets
            VStack(alignment: .leading, spacing: 8) {
                Text("QUICK PRESETS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.gray)

                HStack(spacing: 8) {
                    ForEach(quickPresets, id: \.0) { chip in
                        Button {
                            minutes = chip.1
                            seconds = 0
                        } label: {
                            Text(chip.0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(minutes == chip.1 && seconds == 0 ? .orange : .white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(
                                    minutes == chip.1 && seconds == 0 ? Color.orange.opacity(0.20) : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(minutes == chip.1 && seconds == 0 ? Color.orange.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(DashboardButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    viewModel.setCustomDuration(minutes: minutes, seconds: seconds)
                    isPresented = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                        Text("Set Timer")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(
                        LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.45, blue: 0.3)], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(totalSeconds < 5)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
        .onAppear {
            let total = viewModel.activeMode == "Custom Timer" ? viewModel.totalTime : viewModel.customDurationSeconds
            minutes = max(0, total / 60)
            seconds = total % 60
            if minutes == 0 && seconds == 0 {
                minutes = 25
            }
        }
    }
}

// Backward-compatible alias
public typealias CustomDurationPopover = CustomDurationModalView
