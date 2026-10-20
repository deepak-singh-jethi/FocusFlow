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

                // MARK: - Idle Time Review Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Idle Time Review")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text("Distinguish between running timer time and focused work when away.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.top, 10)

                VStack(spacing: 0) {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Review Inactive Time")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Prompt to review focus credit after periods of system inactivity.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("Review Inactive Time", isOn: $viewModel.idleReviewEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.orange)
                    }
                    .padding(17)

                    if viewModel.idleReviewEnabled {
                        Divider().overlay(Color.white.opacity(0.08))

                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Inactivity Threshold")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Inactivity is detected after this duration without input.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                            Spacer()

                            Picker("Threshold", selection: $viewModel.idleThresholdSeconds) {
                                Text("2 min").tag(120)
                                Text("5 min").tag(300)
                                Text("10 min").tag(600)
                                Text("15 min").tag(900)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 110)
                        }
                        .padding(17)

                        if !viewModel.idleReviewCoordinator.pendingIntervals.isEmpty {
                            Divider().overlay(Color.white.opacity(0.08))

                            HStack {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.orange)
                                    Text("\(viewModel.idleReviewCoordinator.pendingIntervals.count) unresolved review\(viewModel.idleReviewCoordinator.pendingIntervals.count == 1 ? "" : "s") pending")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Button {
                                    if let first = viewModel.idleReviewCoordinator.pendingIntervals.first {
                                        viewModel.idleReviewCoordinator.openReview(for: first)
                                    }
                                } label: {
                                    Text("Review Now")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(17)
                        }
                    }
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
