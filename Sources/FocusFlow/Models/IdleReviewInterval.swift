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
    public var isProvisionalCreditDeducted: Bool

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
        isEstimated: Bool = false,
        isProvisionalCreditDeducted: Bool = false
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
        self.isProvisionalCreditDeducted = isProvisionalCreditDeducted
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionId, sessionType, taskId, startTime, endTime, eligibleDurationSeconds, status, decisionDate, isEstimated, isProvisionalCreditDeducted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        sessionType = try container.decode(String.self, forKey: .sessionType)
        taskId = try container.decodeIfPresent(UUID.self, forKey: .taskId)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decode(Date.self, forKey: .endTime)
        eligibleDurationSeconds = try container.decode(Int.self, forKey: .eligibleDurationSeconds)
        status = try container.decode(IdleReviewStatus.self, forKey: .status)
        decisionDate = try container.decodeIfPresent(Date.self, forKey: .decisionDate)
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
        isProvisionalCreditDeducted = try container.decodeIfPresent(Bool.self, forKey: .isProvisionalCreditDeducted) ?? false
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
