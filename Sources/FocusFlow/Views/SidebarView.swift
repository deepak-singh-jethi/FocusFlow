import SwiftUI
import AppKit

// MARK: - Sidebar Design Tokens (Quiet Productivity)
public enum SidebarTokens {
    // Sizing
    public static let sidebarWidth: CGFloat = 252

    // Spacing
    public static let horizontalPadding: CGFloat = 12
    public static let headerHorizontalPadding: CGFloat = 16
    public static let headerTopPadding: CGFloat = 20
    public static let headerBottomPadding: CGFloat = 16
    public static let sectionSpacing: CGFloat = 6
    public static let itemSpacing: CGFloat = 3
    public static let itemMinHeight: CGFloat = 38
    public static let itemHorizontalPadding: CGFloat = 10
    public static let itemIconSpacing: CGFloat = 10
    public static let footerTopPadding: CGFloat = 10
    public static let footerBottomPadding: CGFloat = 14
    public static let footerSpacing: CGFloat = 10

    // Radii
    public static let itemCornerRadius: CGFloat = 8
    public static let cardCornerRadius: CGFloat = 12
    public static let iconCornerRadius: CGFloat = 8

    // Colors (Quiet Productivity: Dark Charcoal with Subtle Warm Layering)
    public static let sidebarBackground = Color(red: 0.10, green: 0.11, blue: 0.14)
    public static let surfaceSubtle = Color.white.opacity(0.035)
    public static let surfaceHover = Color.white.opacity(0.065)
    public static let borderSubtle = Color.white.opacity(0.07)
    public static let borderHover = Color.white.opacity(0.12)

    // Selection State
    public static let accentOrange = Color(red: 0.98, green: 0.52, blue: 0.18)
    public static let selectionFill = Color(red: 0.98, green: 0.52, blue: 0.18).opacity(0.12)
    public static let selectionBorder = Color(red: 0.98, green: 0.52, blue: 0.18).opacity(0.32)
    public static let selectionIndicator = Color(red: 0.98, green: 0.52, blue: 0.18)

    // Typography Colors
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.68)
    public static let textMuted = Color.white.opacity(0.42)
    public static let sectionHeader = Color.white.opacity(0.40)
}

// MARK: - Sidebar View (Three Logical Regions)
public struct SidebarView: View {
    public let gradient: LinearGradient
    @Binding public var selection: NavigationTab
    @ObservedObject public var viewModel: TimerViewModel

    public init(gradient: LinearGradient, selection: Binding<NavigationTab>, viewModel: TimerViewModel) {
        self.gradient = gradient
        self._selection = selection
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Region 1: Header (Brand Identity & Reserved Architecture)
            headerView

            // Region 2: Navigation (Scrollable Workspace Destinations)
            navigationListView

            // Region 3: Footer (Settings + Authoritative Daily Progress)
            footerView
        }
        .background(SidebarTokens.sidebarBackground)
    }

    // MARK: - Region 1: Header
    private var headerView: some View {
        HStack(spacing: SidebarTokens.itemIconSpacing) {
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(gradient)
                .frame(width: 30, height: 30)
                .background(SidebarTokens.surfaceHover, in: RoundedRectangle(cornerRadius: SidebarTokens.iconCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SidebarTokens.iconCornerRadius)
                        .stroke(SidebarTokens.borderSubtle, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("FocusFlow")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SidebarTokens.textPrimary)
                Text("FOCUS SPACE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(SidebarTokens.textMuted)
            }

            Spacer(minLength: 0)

            // Space reserved architecturally for future collapse control (Phase 2)
            Color.clear
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SidebarTokens.headerHorizontalPadding)
        .padding(.top, SidebarTokens.headerTopPadding)
        .padding(.bottom, SidebarTokens.headerBottomPadding)
    }

    // MARK: - Region 2: Navigation
    private var navigationListView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: SidebarTokens.itemSpacing) {
                HStack {
                    Text("WORKSPACE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundColor(SidebarTokens.sectionHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                ForEach(NavigationTab.workspaceTabs) { tab in
                    SidebarItem(
                        tab: tab,
                        badge: badge(for: tab),
                        isSelected: selection == tab,
                        gradient: gradient
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = tab
                        }
                    }
                }
            }
            .padding(.horizontal, SidebarTokens.horizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Region 3: Footer
    private var footerView: some View {
        VStack(alignment: .leading, spacing: SidebarTokens.footerSpacing) {
            Rectangle()
                .fill(SidebarTokens.borderSubtle)
                .frame(height: 1)
                .padding(.horizontal, SidebarTokens.horizontalPadding)

            VStack(alignment: .leading, spacing: SidebarTokens.itemSpacing) {
                SidebarItem(
                    tab: .settings,
                    badge: badge(for: .settings),
                    isSelected: selection == .settings,
                    gradient: gradient
                ) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        selection = .settings
                    }
                }
            }
            .padding(.horizontal, SidebarTokens.horizontalPadding)

            DailyProgressWidget(
                gradient: gradient,
                focusedSeconds: viewModel.todayFocusedSeconds,
                goalHours: viewModel.dailyGoalHours
            )
            .padding(.horizontal, SidebarTokens.horizontalPadding)
        }
        .padding(.top, SidebarTokens.footerTopPadding)
        .padding(.bottom, SidebarTokens.footerBottomPadding)
    }

    // MARK: - Badge Calculation
    private func badge(for tab: NavigationTab) -> String? {
        switch tab {
        case .focusTimer:
            return (viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime) ? viewModel.timerTimeString : nil
        case .stopwatch:
            return (viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0) ? viewModel.stopwatchTimeString : nil
        case .tasks:
            return viewModel.tasks.isEmpty ? nil : "\(viewModel.tasks.filter(\.isCompleted).count)/\(viewModel.tasks.count)"
        case .soundscapes, .insights, .settings:
            return nil
        }
    }
}

// MARK: - Sidebar Item
public struct SidebarItem: View {
    public var tab: NavigationTab?
    public var icon: String
    public var title: String
    public var badge: String? = nil
    public var isSelected: Bool
    public var gradient: LinearGradient? = nil
    public var action: () -> Void

    @State private var isHovered = false

    public init(
        tab: NavigationTab,
        badge: String? = nil,
        isSelected: Bool,
        gradient: LinearGradient? = nil,
        action: @escaping () -> Void
    ) {
        self.tab = tab
        self.icon = tab.icon
        self.title = tab.title
        self.badge = badge
        self.isSelected = isSelected
        self.gradient = gradient
        self.action = action
    }

    public init(
        icon: String,
        title: String,
        badge: String? = nil,
        isSelected: Bool,
        gradient: LinearGradient? = nil,
        action: @escaping () -> Void
    ) {
        self.tab = nil
        self.icon = icon
        self.title = title
        self.badge = badge
        self.isSelected = isSelected
        self.gradient = gradient
        self.action = action
    }

    private var isStopwatch: Bool {
        tab == .stopwatch || title == NavigationTab.stopwatch.title
    }

    private var backgroundFill: Color {
        if isSelected {
            return SidebarTokens.selectionFill
        } else if isHovered {
            return SidebarTokens.surfaceHover
        } else {
            return Color.clear
        }
    }

    private var borderStroke: Color {
        if isSelected {
            return SidebarTokens.selectionBorder
        } else if isHovered {
            return SidebarTokens.borderHover
        } else {
            return Color.clear
        }
    }

    private var iconColor: Color {
        if isSelected {
            return SidebarTokens.accentOrange
        } else if isHovered {
            return SidebarTokens.textPrimary
        } else {
            return SidebarTokens.textSecondary
        }
    }

    private var titleColor: Color {
        if isSelected {
            return SidebarTokens.textPrimary
        } else if isHovered {
            return SidebarTokens.textPrimary
        } else {
            return SidebarTokens.textSecondary
        }
    }

    private var badgeColor: Color {
        isStopwatch ? Color.cyan : SidebarTokens.accentOrange
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarTokens.itemIconSpacing) {
                // Leading indicator pill for selected state
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? SidebarTokens.selectionIndicator : Color.clear)
                    .frame(width: 3, height: 16)
                    .padding(.leading, -4)

                Image(systemName: icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 4)

                if let badgeText = badge {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 5, height: 5)
                        Text(badgeText)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(badgeColor)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(badgeColor.opacity(0.14), in: Capsule())
                }
            }
            .frame(minHeight: SidebarTokens.itemMinHeight)
            .padding(.horizontal, SidebarTokens.itemHorizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: SidebarTokens.itemCornerRadius)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SidebarTokens.itemCornerRadius)
                    .stroke(borderStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(badge != nil ? "Active: \(badge!)" : "")
        .accessibilityHint("Navigates to \(title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
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
        self.goalHours = max(1, goalHours)
    }

    internal var progress: Double {
        let goalSeconds = max(goalHours * 3600, 1)
        return min(max(Double(focusedSeconds) / Double(goalSeconds), 0.0), 1.0)
    }

    internal var durationLabel: String {
        let totalMinutes = focusedSeconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours)h \(minutes)m"
    }

    internal var percentageLabel: String {
        "\(Int(progress * 100))%"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DAILY FOCUS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(SidebarTokens.sectionHeader)
                Spacer()
                Image(systemName: "flame.fill")
                    .font(.system(size: 11))
                    .foregroundColor(SidebarTokens.accentOrange)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(durationLabel)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(SidebarTokens.textPrimary)
                Text("/ \(goalHours)h")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SidebarTokens.textMuted)
                Spacer(minLength: 0)
                Text(percentageLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(SidebarTokens.accentOrange)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(SidebarTokens.accentOrange)
                        .frame(width: max(0, min(proxy.size.width * CGFloat(progress), proxy.size.width)))
                }
            }
            .frame(height: 5)

            Text("Keep your focus streak going")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(SidebarTokens.textMuted)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SidebarTokens.cardCornerRadius)
                .fill(SidebarTokens.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SidebarTokens.cardCornerRadius)
                .stroke(SidebarTokens.borderSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily Focus Progress")
        .accessibilityValue("\(durationLabel) of \(goalHours) hours goal, \(percentageLabel) completed")
    }
}
