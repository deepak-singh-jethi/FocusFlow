import SwiftUI

// MARK: - Focus Task Model (Codable & Persistent)
public struct FocusTask: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var estimatedMinutes: Int
    public var timeSpentSeconds: Int
    public var icon: String
    public var iconColorName: String
    public var isLocked: Bool
    public var isCompleted: Bool

    public var expectedTime: String {
        "\(estimatedMinutes)m"
    }

    public var formattedTimeSpent: String {
        let mins = timeSpentSeconds / 60
        let secs = timeSpentSeconds % 60
        if mins >= 60 {
            let hours = mins / 60
            let remMins = mins % 60
            return "\(hours)h \(remMins)m"
        } else if mins > 0 {
            return "\(mins)m"
        } else if secs > 0 {
            return "\(secs)s"
        } else {
            return "0m"
        }
    }

    public var progress: Double {
        let target = max(estimatedMinutes * 60, 1)
        return min(max(Double(timeSpentSeconds) / Double(target), 0.0), 1.0)
    }

    public var iconColor: Color {
        get {
            switch iconColorName.lowercased() {
            case "orange": return .orange
            case "blue": return .blue
            case "purple": return .purple
            case "teal": return .teal
            case "cyan": return .cyan
            case "green": return .green
            case "red": return .red
            case "yellow": return .yellow
            case "pink": return .pink
            default: return .orange
            }
        }
        set {
            if newValue == .orange { iconColorName = "orange" }
            else if newValue == .blue { iconColorName = "blue" }
            else if newValue == .purple { iconColorName = "purple" }
            else if newValue == .teal { iconColorName = "teal" }
            else if newValue == .cyan { iconColorName = "cyan" }
            else if newValue == .green { iconColorName = "green" }
            else if newValue == .red { iconColorName = "red" }
            else if newValue == .yellow { iconColorName = "yellow" }
            else if newValue == .pink { iconColorName = "pink" }
            else { iconColorName = "orange" }
        }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        estimatedMinutes: Int = 25,
        timeSpentSeconds: Int = 0,
        icon: String = "checkmark.circle",
        iconColor: Color = .orange,
        isLocked: Bool = false,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.timeSpentSeconds = timeSpentSeconds
        self.icon = icon
        if iconColor == .blue { self.iconColorName = "blue" }
        else if iconColor == .purple { self.iconColorName = "purple" }
        else if iconColor == .teal { self.iconColorName = "teal" }
        else if iconColor == .cyan { self.iconColorName = "cyan" }
        else if iconColor == .green { self.iconColorName = "green" }
        else if iconColor == .red { self.iconColorName = "red" }
        else if iconColor == .yellow { self.iconColorName = "yellow" }
        else if iconColor == .pink { self.iconColorName = "pink" }
        else { self.iconColorName = "orange" }
        self.isLocked = isLocked
        self.isCompleted = isCompleted
    }
}

public typealias StudyTask = FocusTask
