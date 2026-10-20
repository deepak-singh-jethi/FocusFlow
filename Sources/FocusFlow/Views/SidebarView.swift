import SwiftUI
import AppKit

// MARK: - Sidebar Design Tokens (Quiet Productivity)
public enum SidebarTokens {
    // Sizing
    public static let sidebarWidth: CGFloat = 252
    public static let collapsedWidth: CGFloat = 68
    public static let collapsedItemWidth: CGFloat = 44

    // Spacing
    public static let horizontalPadding: CGFloat = 12
    public static let headerHorizontalPadding: CGFloat = 16
    public static let headerTopPadding: CGFloat = 52
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
    @Binding public var isCollapsed: Bool
    @ObservedObject public var viewModel: TimerViewModel
    public var topPadding: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCollapseHovered = false

    public init(
        gradient: LinearGradient,
        selection: Binding<NavigationTab>,
        isCollapsed: Binding<Bool> = .constant(false),
        viewModel: TimerViewModel,
        topPadding: CGFloat = SidebarTokens.headerTopPadding
    ) {
        self.gradient = gradient
        self._selection = selection
        self._isCollapsed = isCollapsed
        self.viewModel = viewModel
        self.topPadding = topPadding
    }

    public init(gradient: LinearGradient, selection: Binding<NavigationTab>, viewModel: TimerViewModel, topPadding: CGFloat = SidebarTokens.headerTopPadding) {
        self.init(gradient: gradient, selection: selection, isCollapsed: .constant(false), viewModel: viewModel, topPadding: topPadding)
    }

    private var toggleAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.05)
            : .spring(response: 0.32, dampingFraction: 0.85)
    }

    private func toggleCollapse() {
        withAnimation(toggleAnimation) {
            isCollapsed.toggle()
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Region 1: Header (Brand Identity & Collapse Control)
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
        Group {
            if isCollapsed {
                VStack(spacing: 0) {
                    collapseButton
                }
                .frame(width: SidebarTokens.collapsedItemWidth, height: 32)
                .padding(.horizontal, SidebarTokens.horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, SidebarTokens.headerBottomPadding)
            } else {
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

                    // Functional collapse/expand button (replaces the 24x24 placeholder)
                    collapseButton
                }
                .padding(.horizontal, SidebarTokens.headerHorizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, SidebarTokens.headerBottomPadding)
            }
        }
    }

    private var collapseButton: some View {
        Button(action: toggleCollapse) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isCollapseHovered ? SidebarTokens.textPrimary : SidebarTokens.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCollapseHovered ? SidebarTokens.surfaceHover : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCollapseHovered ? SidebarTokens.borderHover : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(isCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityLabel(isCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityHint(isCollapsed ? "Expands sidebar to show navigation labels" : "Collapses sidebar into icon-only mode")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isCollapseHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: - Region 2: Navigation
    private var navigationListView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: isCollapsed ? .center : .leading, spacing: SidebarTokens.itemSpacing) {
                if !isCollapsed {
                    HStack {
                        Text("WORKSPACE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.1)
                            .foregroundColor(SidebarTokens.sectionHeader)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

                ForEach(NavigationTab.workspaceTabs) { tab in
                    SidebarItem(
                        tab: tab,
                        badge: badge(for: tab),
                        contextualAccessibility: contextualAccessibilityValue(for: tab),
                        isSelected: selection == tab,
                        isCollapsed: isCollapsed,
                        gradient: gradient
                    ) {
                        let anim: Animation = reduceMotion
                            ? .linear(duration: 0.05)
                            : .spring(response: 0.38, dampingFraction: 0.82)
                        withAnimation(anim) {
                            selection = tab
                        }
                    }
                }
            }
            .padding(.horizontal, SidebarTokens.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Region 3: Footer
    private var footerView: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: SidebarTokens.footerSpacing) {
            Rectangle()
                .fill(SidebarTokens.borderSubtle)
                .frame(width: isCollapsed ? SidebarTokens.collapsedItemWidth : nil, height: 1)
                .padding(.horizontal, isCollapsed ? 0 : SidebarTokens.horizontalPadding)

            VStack(alignment: isCollapsed ? .center : .leading, spacing: SidebarTokens.itemSpacing) {
                SidebarItem(
                    tab: .settings,
                    badge: badge(for: .settings),
                    contextualAccessibility: contextualAccessibilityValue(for: .settings),
                    isSelected: selection == .settings,
                    isCollapsed: isCollapsed,
                    gradient: gradient
                ) {
                    let anim: Animation = reduceMotion
                        ? .linear(duration: 0.05)
                        : .spring(response: 0.38, dampingFraction: 0.82)
                    withAnimation(anim) {
                        selection = .settings
                    }
                }
            }
            .padding(.horizontal, isCollapsed ? 0 : SidebarTokens.horizontalPadding)

            DailyProgressWidget(
                gradient: gradient,
                focusedSeconds: viewModel.todayFocusedSeconds,
                goalHours: viewModel.dailyGoalHours,
                isCompact: isCollapsed
            )
            .padding(.horizontal, isCollapsed ? 0 : SidebarTokens.horizontalPadding)
        }
        .padding(.top, SidebarTokens.footerTopPadding)
        .padding(.bottom, SidebarTokens.footerBottomPadding)
    }

    // MARK: - Badge Calculation
    private func badge(for tab: NavigationTab) -> String? {
        switch tab {
        case .focusTimer:
            return (viewModel.isTimerRunning || viewModel.pausedSession != nil || viewModel.timeRemaining < viewModel.totalTime) ? viewModel.timerTimeString : nil
        case .stopwatch:
            return (viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0) ? viewModel.stopwatchTimeString : nil
        case .tasks:
            return viewModel.tasks.isEmpty ? nil : "\(viewModel.tasks.filter(\.isCompleted).count)/\(viewModel.tasks.count)"
        case .soundscapes, .insights, .settings:
            return nil
        }
    }

    // MARK: - Contextual Accessibility Value
    internal func contextualAccessibilityValue(for tab: NavigationTab) -> String? {
        switch tab {
        case .focusTimer:
            if viewModel.isTimerRunning {
                return "\(viewModel.timerTimeString) remaining, running"
            } else if viewModel.pausedSession != nil || (viewModel.timeRemaining < viewModel.totalTime && viewModel.timeRemaining > 0) {
                return "\(viewModel.timerTimeString) remaining, paused"
            } else if viewModel.timeRemaining == 0 && viewModel.totalTime > 0 {
                return "00:00 remaining, completed"
            }
            return nil
        case .stopwatch:
            if viewModel.isStopwatchRunning {
                return "\(viewModel.stopwatchTimeString) elapsed, running"
            } else if viewModel.stopwatchTime > 0 {
                return "\(viewModel.stopwatchTimeString) elapsed, paused"
            }
            return nil
        case .tasks:
            let total = viewModel.tasks.count
            if total == 0 {
                return "No tasks"
            }
            let completed = viewModel.tasks.filter(\.isCompleted).count
            return "\(completed) of \(total) tasks completed"
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
    public var contextualAccessibility: String? = nil
    public var isSelected: Bool
    public var isCollapsed: Bool = false
    public var gradient: LinearGradient? = nil
    public var action: () -> Void

    @State private var isHovered = false

    public init(
        tab: NavigationTab,
        badge: String? = nil,
        contextualAccessibility: String? = nil,
        isSelected: Bool,
        isCollapsed: Bool = false,
        gradient: LinearGradient? = nil,
        action: @escaping () -> Void
    ) {
        self.tab = tab
        self.icon = tab.icon
        self.title = tab.title
        self.badge = badge
        self.contextualAccessibility = contextualAccessibility
        self.isSelected = isSelected
        self.isCollapsed = isCollapsed
        self.gradient = gradient
        self.action = action
    }

    public init(
        tab: NavigationTab,
        badge: String? = nil,
        isSelected: Bool,
        gradient: LinearGradient? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            tab: tab,
            badge: badge,
            contextualAccessibility: nil,
            isSelected: isSelected,
            isCollapsed: false,
            gradient: gradient,
            action: action
        )
    }

    public init(
        icon: String,
        title: String,
        badge: String? = nil,
        contextualAccessibility: String? = nil,
        isSelected: Bool,
        isCollapsed: Bool = false,
        gradient: LinearGradient? = nil,
        action: @escaping () -> Void
    ) {
        self.tab = nil
        self.icon = icon
        self.title = title
        self.badge = badge
        self.contextualAccessibility = contextualAccessibility
        self.isSelected = isSelected
        self.isCollapsed = isCollapsed
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
        self.init(
            icon: icon,
            title: title,
            badge: badge,
            contextualAccessibility: nil,
            isSelected: isSelected,
            isCollapsed: false,
            gradient: gradient,
            action: action
        )
    }

    private var isStopwatch: Bool {
        tab == .stopwatch || title == NavigationTab.stopwatch.title || title == NavigationTab.stopwatch.rawValue
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

    private var tooltipText: String {
        if let badgeText = badge {
            return "\(title) (\(badgeText))"
        } else {
            return title
        }
    }

    public var body: some View {
        Button(action: action) {
            if isCollapsed {
                collapsedContent
            } else {
                expandedContent
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(isCollapsed ? tooltipText : "")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(contextualAccessibility ?? (badge != nil ? "Active: \(badge!)" : ""))
        .accessibilityHint("Navigates to \(title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    // Collapsed Mode: Centered Icon with Dot Badge and Selection Indicator
    private var collapsedContent: some View {
        ZStack {
            if isSelected {
                HStack {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(SidebarTokens.selectionIndicator)
                        .frame(width: 3, height: 16)
                        .padding(.leading, 2)
                    Spacer()
                }
            }

            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 24, height: 24)

                if badge != nil {
                    Circle()
                        .fill(badgeColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .frame(width: SidebarTokens.collapsedItemWidth, height: SidebarTokens.itemMinHeight)
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

    // Expanded Mode: Full HStack with Label, Pill, and Badge Text
    private var expandedContent: some View {
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
}

// MARK: - Daily Progress Widget
public struct DailyProgressWidget: View {
    public let gradient: LinearGradient
    public let focusedSeconds: Int
    public let goalHours: Int
    public var isCompact: Bool = false

    public init(gradient: LinearGradient, focusedSeconds: Int, goalHours: Int, isCompact: Bool = false) {
        self.gradient = gradient
        self.focusedSeconds = focusedSeconds
        self.goalHours = max(1, goalHours)
        self.isCompact = isCompact
    }

    public init(gradient: LinearGradient, focusedSeconds: Int, goalHours: Int) {
        self.init(gradient: gradient, focusedSeconds: focusedSeconds, goalHours: goalHours, isCompact: false)
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
        if isCompact {
            compactBody
        } else {
            expandedBody
        }
    }

    private var compactBody: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 2.5)
                    .frame(width: 24, height: 24)
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(SidebarTokens.accentOrange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
                Image(systemName: "flame.fill")
                    .font(.system(size: 10))
                    .foregroundColor(SidebarTokens.accentOrange)
            }
            Text(percentageLabel)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(SidebarTokens.accentOrange)
        }
        .frame(width: SidebarTokens.collapsedItemWidth, height: 44)
        .background(
            RoundedRectangle(cornerRadius: SidebarTokens.itemCornerRadius)
                .fill(SidebarTokens.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SidebarTokens.itemCornerRadius)
                .stroke(SidebarTokens.borderSubtle, lineWidth: 1)
        )
        .help("Daily Focus: \(durationLabel) of \(goalHours)h (\(percentageLabel))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily Focus Progress")
        .accessibilityValue("\(durationLabel) of \(goalHours) hours goal, \(percentageLabel) completed")
    }

    private var expandedBody: some View {
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
