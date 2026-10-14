import SwiftUI
import AppKit

// MARK: - Dashboard Button Style
public struct DashboardButtonStyle: ButtonStyle {
    public var selected: Bool = false

    public init(selected: Bool = false) {
        self.selected = selected
    }

    public func makeBody(configuration: Configuration) -> some View {
        DashboardButtonBody(configuration: configuration, selected: selected)
    }

    private struct DashboardButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minHeight: 40)
                .foregroundColor(selected ? .orange : (isHovered ? .white : .white.opacity(0.82)))
                .padding(.horizontal, 14)
                .background(
                    selected ? Color.orange.opacity(0.18) :
                    Color.white.opacity(configuration.isPressed ? 0.15 : (isHovered ? 0.10 : 0.05)),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            selected ? Color.orange.opacity(0.45) :
                            (isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.08)),
                            lineWidth: 1
                        )
                )
                .shadow(color: isHovered ? (selected ? Color.orange.opacity(0.25) : Color.white.opacity(0.05)) : Color.clear, radius: 6)
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.02 : 1.0))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
        }
    }
}

// MARK: - Primary Dashboard Button Style
public struct PrimaryDashboardButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryDashboardButtonBody(configuration: configuration)
    }

    private struct PrimaryDashboardButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minHeight: 46)
                .foregroundColor(Color(red: 0.10, green: 0.05, blue: 0.05))
                .padding(.horizontal, 22)
                .background(
                    LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.38, blue: 0.28)], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
                )
                .shadow(color: Color.orange.opacity(isHovered ? 0.55 : 0.35), radius: isHovered ? 12 : 8, y: 2)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
        }
    }
}

// MARK: - Capsule Action Button
public struct CapsuleActionButton: View {
    public var icon: String
    public var title: String
    public var isPrimary: Bool = false
    public var isCyan: Bool = false
    public var action: () -> Void

    @State private var isHovered = false

    public init(icon: String, title: String, isPrimary: Bool = false, isCyan: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.isPrimary = isPrimary
        self.isCyan = isCyan
        self.action = action
    }

    private var primaryGradient: LinearGradient {
        if isCyan {
            return LinearGradient(colors: [Color.cyan, Color(red: 0.0, green: 0.65, blue: 0.95)], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [Color.orange, Color(red: 1.0, green: 0.38, blue: 0.28)], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var primaryShadowColor: Color {
        if isCyan {
            return Color.cyan.opacity(isHovered ? 0.55 : 0.38)
        } else {
            return Color.orange.opacity(isHovered ? 0.55 : 0.38)
        }
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isPrimary ? Color(red: 0.10, green: 0.05, blue: 0.05) : (isHovered ? .white : Color.white.opacity(0.92)))
            .padding(.horizontal, isPrimary ? 24 : 18)
            .frame(minHeight: 46)
            .background(
                Group {
                    if isPrimary {
                        Capsule().fill(primaryGradient)
                    } else {
                        Capsule().fill(Color.white.opacity(isHovered ? 0.11 : 0.045))
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(
                        isPrimary ? Color.white.opacity(isHovered ? 0.38 : 0.25) : Color.white.opacity(isHovered ? 0.22 : 0.09),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPrimary ? primaryShadowColor : (isHovered ? Color.white.opacity(0.06) : Color.clear),
                radius: isHovered ? 14 : 10,
                y: 3
            )
            .scaleEffect(isHovered ? 1.025 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Style Segment Button
public struct StyleSegmentButton: View {
    public let title: String
    public let icon: String
    public let isSelected: Bool
    public let action: () -> Void

    @State private var isHovered = false

    public init(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : (isHovered ? .white : .gray))
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(
                Capsule()
                    .fill(
                        isSelected ?
                        Color.white.opacity(0.14) :
                        (isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.001))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color.white.opacity(0.20) :
                        (isHovered ? Color.white.opacity(0.14) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? Color.white.opacity(0.08) : Color.clear, radius: 4)
            .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Secondary Button
public struct SecondaryButton: View {
    public var icon: String
    public var title: String
    public var action: () -> Void

    public init(icon: String, title: String, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.action = action
    }

    public var body: some View {
        CapsuleActionButton(icon: icon, title: title, isPrimary: false, action: action)
    }
}

// MARK: - Preset Card
public struct PresetCard: View {
    public var title: String
    public var time: String
    public var isSelected: Bool
    public var hasSparkle: Bool = false
    public var action: () -> Void

    public init(title: String, time: String, isSelected: Bool, hasSparkle: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.time = time
        self.isSelected = isSelected
        self.hasSparkle = hasSparkle
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .orange : .white)
                    Text(time)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .orange.opacity(0.8) : .gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isSelected ? Color.orange.opacity(0.12) : Color.white.opacity(0.04))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.orange.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1))

                if hasSparkle {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundColor(.gray.opacity(0.4))
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Task Row
public struct TaskRow: View {
    public var icon: String
    public var iconColor: Color
    public var title: String
    public var time: String
    public var timeSpent: String = "0m"
    public var progress: Double = 0.0
    public var status: String
    public var isActive: Bool
    public var isLocked: Bool = false
    public var isCompleted: Bool = false

    public init(
        icon: String,
        iconColor: Color,
        title: String,
        time: String,
        timeSpent: String = "0m",
        progress: Double = 0.0,
        status: String,
        isActive: Bool,
        isLocked: Bool = false,
        isCompleted: Bool = false
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.time = time
        self.timeSpent = timeSpent
        self.progress = progress
        self.status = status
        self.isActive = isActive
        self.isLocked = isLocked
        self.isCompleted = isCompleted
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .rotationEffect(icon == "triangle.fill" ? .degrees(-90) : .zero)
                .foregroundColor(iconColor)
                .font(.system(size: 14))
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isCompleted ? .gray.opacity(0.6) : (isActive ? .white : .gray.opacity(0.85)))
                        .strikethrough(isCompleted, color: .gray.opacity(0.6))
                    Spacer()
                    Text(isLocked ? "Locked" : time)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isLocked ? .gray : (isActive ? .orange : .gray.opacity(0.65)))
                }

                HStack(spacing: 6) {
                    if isCompleted {
                        Text("Completed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green.opacity(0.85))
                        if timeSpent != "0m" {
                            Text("· \(timeSpent) logged")
                                .font(.system(size: 11))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    } else if isActive {
                        Text("● Active · \(timeSpent) spent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                    } else if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.65))
                        if timeSpent != "0m" {
                            Text("· \(timeSpent) spent")
                                .font(.system(size: 11))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                }

                if progress > 0 && !isCompleted {
                    GeometryReader { p in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(isActive ? Color.orange : Color.gray.opacity(0.45))
                                .frame(width: p.size.width * CGFloat(progress))
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(isActive ? Color.orange.opacity(0.08) : Color.clear)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.orange.opacity(0.24) : Color.clear, lineWidth: 1))
    }
}
