import SwiftUI

// MARK: - Focus Task Model
public struct FocusTask: Identifiable {
    public let id: UUID
    public var title: String
    public var estimatedMinutes: Int
    public var timeSpentSeconds: Int = 0
    public var icon: String
    public var iconColor: Color
    public var isLocked: Bool = false
    public var isCompleted: Bool = false

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
        self.iconColor = iconColor
        self.isLocked = isLocked
        self.isCompleted = isCompleted
    }
}

public typealias StudyTask = FocusTask
