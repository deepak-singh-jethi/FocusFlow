import Foundation

// MARK: - Idle Review Status
public enum IdleReviewStatus: String, Codable, Equatable, Sendable {
    case pending
    case included
    case excluded
}

// MARK: - Idle Review Decision
public enum IdleReviewDecision: String, Codable, Equatable, Sendable {
    case countAsFocus
    case excludeFromFocus
    case decideLater
}

// MARK: - Idle Review Interval Model
public struct IdleReviewInterval: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionId: UUID
    public let sessionType: String // "Focus", "Custom", "Stopwatch"
    public let taskId: UUID?
    public let startTime: Date
    public let endTime: Date
    public let eligibleDurationSeconds: Int
    public var status: IdleReviewStatus
    public var decisionDate: Date?
    public var isEstimated: Bool

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        sessionType: String,
        taskId: UUID? = nil,
        startTime: Date,
        endTime: Date,
        eligibleDurationSeconds: Int,
        status: IdleReviewStatus = .pending,
        decisionDate: Date? = nil,
        isEstimated: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionType = sessionType
        self.taskId = taskId
        self.startTime = startTime
        self.endTime = endTime
        self.eligibleDurationSeconds = max(0, eligibleDurationSeconds)
        self.status = status
        self.decisionDate = decisionDate
        self.isEstimated = isEstimated
    }

    /// Formatted time range string for display (e.g. "10:07 AM — 10:16 AM")
    public func formattedTimeRange(locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: startTime)) — \(formatter.string(from: endTime))"
    }

    /// Human-friendly duration string (e.g. "9 minutes", "18 minutes", "45 seconds")
    public var formattedDuration: String {
        let minutes = eligibleDurationSeconds / 60
        let seconds = eligibleDurationSeconds % 60
        if minutes > 0 && seconds > 0 {
            return "\(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
    }
}
