import SwiftUI

// MARK: - Insights & Stats View (Date-Aware Analytics)
public struct InsightsView: View {
    @ObservedObject public var viewModel: TimerViewModel
    public var topPadding: CGFloat

    public init(viewModel: TimerViewModel, topPadding: CGFloat = WindowLayoutMetrics.standardTopClearance) {
        self.viewModel = viewModel
        self.topPadding = topPadding
    }

    private var completedTasks: Int { viewModel.tasks.filter(\.isCompleted).count }

    private var todayFocusLabel: String {
        let minutes = viewModel.todayFocusedSeconds / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var weeklyFocusLabel: String {
        let minutes = viewModel.weeklyFocusedSeconds / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var lifetimeFocusLabel: String {
        let minutes = viewModel.lifetimeFocusedSeconds / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Insights & Stats")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Track your daily, weekly, and lifetime focus analytics.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.top, topPadding)

                // Date-Aware Analytics Metric Cards
                HStack(spacing: 12) {
                    insightCard(title: "TODAY FOCUS", value: todayFocusLabel, icon: "clock")
                    insightCard(title: "PAST 7 DAYS", value: weeklyFocusLabel, icon: "calendar")
                    insightCard(title: "LIFETIME", value: lifetimeFocusLabel, icon: "chart.bar.fill")
                    insightCard(title: "SESSIONS", value: "\(viewModel.completedSessions)", icon: "checkmark.circle")
                }

                // Daily Focus Goal Progress Card
                VStack(alignment: .leading, spacing: 15) {
                    Text("Daily focus goal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(todayFocusLabel).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundColor(.white)
                        Text("of \(viewModel.dailyGoalHours) hours").font(.system(size: 12)).foregroundColor(.gray)
                    }
                    ProgressView(value: min(Double(viewModel.todayFocusedSeconds) / Double(max(viewModel.dailyGoalHours * 3600, 1)), 1))
                        .tint(.orange)
                    Text("Calculated from today's sessions. Resets naturally at midnight.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .padding(19)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

                // Tasks Time Tracking
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Time logged by task")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(completedTasks)/\(viewModel.tasks.count) completed")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }

                    if viewModel.tasks.isEmpty {
                        Text("No tasks added yet.")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(viewModel.tasks) { task in
                                HStack {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(task.isCompleted ? .green : .gray)
                                        .font(.system(size: 13))
                                    Text(task.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(task.isCompleted ? .gray : .white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(task.formattedTimeSpent) / \(task.expectedTime)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(task.timeSpentSeconds > 0 ? .orange : .gray)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(19)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            viewModel.recalculateFocusMetrics()
        }
    }

    private func insightCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundColor(.orange)
            Text(value).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
            Text(title).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
