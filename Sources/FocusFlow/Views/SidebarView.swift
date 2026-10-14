import SwiftUI
import AppKit

// MARK: - Sidebar View
public struct SidebarView: View {
    public let gradient: LinearGradient
    @Binding public var selection: String
    @ObservedObject public var viewModel: TimerViewModel

    public init(gradient: LinearGradient, selection: Binding<String>, viewModel: TimerViewModel) {
        self.gradient = gradient
        self._selection = selection
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(gradient)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("FocusFlow")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("FOCUS SPACE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(.gray)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WORKSPACE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    SidebarItem(
                        icon: "hourglass",
                        title: "Focus Timer",
                        badge: (viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime) ? viewModel.timerTimeString : nil,
                        isSelected: selection == "Focus Timer",
                        gradient: gradient
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Focus Timer"
                        }
                    }

                    SidebarItem(
                        icon: "stopwatch",
                        title: "Stopwatch & Laps",
                        badge: (viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0) ? viewModel.stopwatchTimeString : nil,
                        isSelected: selection == "Stopwatch & Laps",
                        gradient: gradient
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Stopwatch & Laps"
                        }
                    }

                    SidebarItem(
                        icon: "checklist",
                        title: "Tasks",
                        badge: viewModel.tasks.isEmpty ? nil : "\(viewModel.tasks.filter(\.isCompleted).count)/\(viewModel.tasks.count)",
                        isSelected: selection == "Tasks" || selection == "Study Tasks"
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Tasks"
                        }
                    }
                    SidebarItem(icon: "headphones", title: "Focus Soundscapes", isSelected: selection == "Focus Soundscapes") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Focus Soundscapes"
                        }
                    }
                    SidebarItem(icon: "chart.bar", title: "Insights & Stats", isSelected: selection == "Insights & Stats") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Insights & Stats"
                        }
                    }
                    SidebarItem(icon: "gearshape", title: "Settings", isSelected: selection == "Settings") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Settings"
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            DailyProgressWidget(gradient: gradient, focusedSeconds: viewModel.focusedSeconds, goalHours: viewModel.dailyGoalHours)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
    }
}

// MARK: - Sidebar Item
public struct SidebarItem: View {
    public var icon: String
    public var title: String
    public var badge: String? = nil
    public var isSelected: Bool
    public var gradient: LinearGradient? = nil
    public var action: () -> Void

    @State private var isHovered = false

    public init(icon: String, title: String, badge: String? = nil, isSelected: Bool, gradient: LinearGradient? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.badge = badge
        self.isSelected = isSelected
        self.gradient = gradient
        self.action = action
    }

    private var itemBackground: Color {
        isHovered ? Color.white.opacity(0.065) : Color.white.opacity(0.001)
    }

    private var itemBorder: Color {
        isSelected ? Color.orange.opacity(0.3) : (isHovered ? Color.white.opacity(0.12) : Color.clear)
    }

    private var itemForeground: Color {
        isSelected ? .orange : (isHovered ? .white : .gray.opacity(0.85))
    }

    private var titleForeground: Color {
        isSelected ? .white : (isHovered ? .white : .gray.opacity(0.85))
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(itemForeground)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(titleForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)

                Spacer()

                if let badge = badge {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(title == "Stopwatch & Laps" ? Color.cyan : Color.orange)
                            .frame(width: 5, height: 5)
                        Text(badge)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(title == "Stopwatch & Laps" ? .cyan : .orange)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background((title == "Stopwatch & Laps" ? Color.cyan : Color.orange).opacity(0.16), in: Capsule())
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9)
                            .fill((gradient ?? LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)).opacity(0.14))
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(itemBackground)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(itemBorder, lineWidth: 1)
            )
            .shadow(color: isSelected ? .orange.opacity(0.15) : .clear, radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Daily Progress Widget
public struct DailyProgressWidget: View {
    public let gradient: LinearGradient
    public let focusedSeconds: Int
    public let goalHours: Int

    public init(gradient: LinearGradient, focusedSeconds: Int, goalHours: Int) {
        self.gradient = gradient
        self.focusedSeconds = focusedSeconds
        self.goalHours = goalHours
    }

    private var progress: Double {
        let goal = max(goalHours * 3600, 1)
        return min(Double(focusedSeconds) / Double(goal), 1)
    }

    private var durationLabel: String {
        let minutes = focusedSeconds / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DAILY FOCUS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundColor(.gray)
                Spacer()
                Image(systemName: "flame.fill")
                    .foregroundColor(.orange)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(durationLabel)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("/ \(goalHours)h")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                Spacer(minLength: 0)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(gradient).frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 6)
            Text("Keep your focus streak going")
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.8))
        }
        .padding(14)
        .background(Color.white.opacity(0.02))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
