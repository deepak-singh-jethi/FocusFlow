import SwiftUI

// MARK: - Navigation Tab Enum
public enum NavigationTab: String, CaseIterable, Identifiable, Codable {
    case focusTimer = "Focus Timer"
    case stopwatch = "Stopwatch & Laps"
    case tasks = "Tasks"
    case soundscapes = "Focus Soundscapes"
    case insights = "Insights & Stats"
    case settings = "Settings"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .focusTimer: return "Focus"
        case .stopwatch: return "Stopwatch"
        case .tasks: return "Tasks"
        case .soundscapes: return "Sounds"
        case .insights: return "Insights"
        case .settings: return "Settings"
        }
    }

    public var icon: String {
        switch self {
        case .focusTimer: return "hourglass"
        case .stopwatch: return "stopwatch"
        case .tasks: return "checklist"
        case .soundscapes: return "headphones"
        case .insights: return "chart.bar"
        case .settings: return "gearshape"
        }
    }

    public var isWorkspaceTab: Bool {
        self != .settings
    }

    public static var workspaceTabs: [NavigationTab] {
        [.focusTimer, .stopwatch, .tasks, .soundscapes, .insights]
    }
}

// MARK: - Clock Style Enum
public enum ClockStyle: String, CaseIterable, Identifiable, Codable {
    case digital = "Digital"
    case ring = "Ring"
    case analog = "Analog"

    public var id: String { rawValue }
    public var title: String { rawValue }

    public var icon: String {
        switch self {
        case .digital: return "textformat.123"
        case .ring: return "circle"
        case .analog: return "clock"
        }
    }
}
