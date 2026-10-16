import SwiftUI

// MARK: - Settings View
public struct SettingsView: View {
    @ObservedObject public var viewModel: TimerViewModel

    public init(viewModel: TimerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Tune the focus cycle to fit your day.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.top, 30)

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Sessions per cycle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("The session counter starts over after this many.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Stepper("\(viewModel.totalSessions)", value: $viewModel.totalSessions, in: 1...12)
                            .labelsHidden()
                        Text("\(viewModel.totalSessions)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 20)
                    }
                    .padding(17)

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Daily focus goal")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Used in your daily progress and insights.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Stepper("\(viewModel.dailyGoalHours) hours", value: $viewModel.dailyGoalHours, in: 1...12)
                            .labelsHidden()
                        Text("\(viewModel.dailyGoalHours)h")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 30)
                    }
                    .padding(17)

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Auto-start next session")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Continue the next interval when a timer ends.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("Auto-start next session", isOn: $viewModel.autoStartNextSession)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.orange)
                    }
                    .padding(17)
                }
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .disabled(viewModel.isPersistenceBlocked)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onChange(of: viewModel.totalSessions) { _, newTotal in
            guard !viewModel.isPersistenceBlocked else { return }
            if viewModel.currentSession > newTotal {
                viewModel.currentSession = 1
            }
        }
    }
}
