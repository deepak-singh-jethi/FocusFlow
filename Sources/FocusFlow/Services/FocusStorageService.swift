import Foundation

// MARK: - Focus Session Record (Date-Aware Analytics)
public struct FocusSessionRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let sessionId: UUID?
    public let startTime: Date
    public let endTime: Date
    public let durationSeconds: Int
    public let mode: String
    public let taskId: UUID?

    public init(
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        startTime: Date,
        endTime: Date,
        durationSeconds: Int,
        mode: String,
        taskId: UUID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = max(0, durationSeconds)
        self.mode = mode
        self.taskId = taskId
    }

    /// Computes how many seconds of this session fall within the specified calendar day.
    /// Accurately accounts for midnight transitions using cumulative boundary allocation.
    public func duration(on date: Date, calendar: Calendar = .current) -> Int {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return 0
        }
        return duration(from: dayStart, to: dayEnd)
    }

    /// Computes how many seconds of this record fall within the specified date interval.
    /// Uses cumulative boundary allocation to guarantee exact integer conservation and zero rounding drift.
    public func duration(from intervalStart: Date, to intervalEnd: Date) -> Int {
        FocusIntervalAllocator.allocatedDuration(
            recordStart: startTime,
            recordEnd: endTime,
            durationSeconds: durationSeconds,
            intervalStart: intervalStart,
            intervalEnd: intervalEnd
        )
    }
}

// MARK: - Cumulative-Boundary Focus Interval Allocator
public enum FocusIntervalAllocator {
    /// Allocates recorded duration across a query interval [intervalStart, intervalEnd].
    /// Uses cumulative boundary allocation to guarantee exact integer conservation and zero rounding drift
    /// across any sequence of adjacent, non-overlapping partitions.
    public static func allocatedDuration(
        recordStart: Date,
        recordEnd: Date,
        durationSeconds: Int,
        intervalStart: Date,
        intervalEnd: Date
    ) -> Int {
        guard durationSeconds > 0 else { return 0 }
        guard intervalEnd > intervalStart else { return 0 }

        // Malformed record timestamps (zero or negative wall-clock duration)
        if recordEnd <= recordStart {
            if recordStart >= intervalStart && recordStart < intervalEnd {
                return durationSeconds
            }
            return 0
        }

        let span = recordEnd.timeIntervalSince(recordStart)
        guard span > 0 else { return 0 }

        let cumEnd = cumulativeSeconds(at: intervalEnd, recordStart: recordStart, recordEnd: recordEnd, span: span, totalDuration: durationSeconds)
        let cumStart = cumulativeSeconds(at: intervalStart, recordStart: recordStart, recordEnd: recordEnd, span: span, totalDuration: durationSeconds)

        return max(0, cumEnd - cumStart)
    }

    /// Monotonically non-decreasing cumulative allocation function C(t).
    /// For t <= recordStart: returns 0.
    /// For t >= recordEnd: returns totalDuration.
    /// For t in (recordStart, recordEnd): returns Int(round(totalDuration * ((t - recordStart) / span))).
    public static func cumulativeSeconds(
        at date: Date,
        recordStart: Date,
        recordEnd: Date,
        span: TimeInterval,
        totalDuration: Int
    ) -> Int {
        if date <= recordStart {
            return 0
        }
        if date >= recordEnd {
            return totalDuration
        }
        let elapsed = date.timeIntervalSince(recordStart)
        let ratio = max(0.0, min(1.0, elapsed / span))
        let cum = Int(round(Double(totalDuration) * ratio))
        return max(0, min(totalDuration, cum))
    }
}

// MARK: - Session Exclusion Record (Durable Task 9 Idle Review Ledger)
public struct SessionExclusionRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID                      // Stable interval UUID
    public let sessionId: UUID               // Originating timer session UUID
    public let taskId: UUID?                 // Original task UUID
    public let startTime: Date               // Exact idle start timestamp
    public let endTime: Date                 // Exact idle end timestamp
    public let decision: IdleReviewDecision  // Exclusion decision (.excludeFromFocus)
    public var isAppliedToHistory: Bool      // Whether applied to final sessionRecords

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        taskId: UUID? = nil,
        startTime: Date,
        endTime: Date,
        decision: IdleReviewDecision = .excludeFromFocus,
        isAppliedToHistory: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.taskId = taskId
        self.startTime = startTime
        self.endTime = endTime
        self.decision = decision
        self.isAppliedToHistory = isAppliedToHistory
    }

    public func toInterval() -> IdleReviewInterval {
        IdleReviewInterval(
            id: id,
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: startTime,
            endTime: endTime,
            eligibleDurationSeconds: max(0, Int(endTime.timeIntervalSince(startTime))),
            status: .excluded,
            isEstimated: false,
            isProvisionalCreditDeducted: true
        )
    }
}

// MARK: - Stopwatch Lap Data Model
public struct StopwatchLap: Identifiable, Codable, Equatable {
    public let id: UUID
    public let lapNumber: Int
    public let lapDuration: TimeInterval      // Duration of this individual lap split
    public let totalTime: TimeInterval        // Cumulative elapsed time when lap was recorded
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        lapNumber: Int,
        lapDuration: TimeInterval,
        totalTime: TimeInterval,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.lapNumber = lapNumber
        self.lapDuration = max(0, lapDuration)
        self.totalTime = max(0, totalTime)
        self.timestamp = timestamp
    }

    public var formattedLapDuration: String {
        Self.formatDuration(lapDuration)
    }

    public var formattedTotalTime: String {
        Self.formatDuration(totalTime)
    }

    public static func formatDuration(_ time: TimeInterval) -> String {
        let totalHundredths = max(0, Int(round(time * 100)))
        let hours = totalHundredths / 360_000
        let minutes = (totalHundredths / 6000) % 60
        let seconds = (totalHundredths / 100) % 60
        let hundredths = totalHundredths % 100
        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%02d", hours, minutes, seconds, hundredths)
        } else if (totalHundredths / 6000) > 0 {
            return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
        } else {
            return String(format: "%02d.%02d", seconds, hundredths)
        }
    }
}

// MARK: - Preserved Background Timer Session
public struct PreservedTimerSession: Codable, Equatable {
    public var activePreset: String
    public var activeMode: String
    public var isBreakSession: Bool
    public var totalTime: Int
    public var timeRemaining: Int
    public var preciseProgress: Double
    public var customMinutes: Int
    public var customSeconds: Int
    public var currentSession: Int
    public var activeTaskIndex: Int

    public init(
        activePreset: String,
        activeMode: String,
        isBreakSession: Bool,
        totalTime: Int,
        timeRemaining: Int,
        preciseProgress: Double,
        customMinutes: Int,
        customSeconds: Int,
        currentSession: Int,
        activeTaskIndex: Int
    ) {
        self.activePreset = activePreset
        self.activeMode = activeMode
        self.isBreakSession = isBreakSession
        self.totalTime = totalTime
        self.timeRemaining = timeRemaining
        self.preciseProgress = preciseProgress
        self.customMinutes = customMinutes
        self.customSeconds = customSeconds
        self.currentSession = currentSession
        self.activeTaskIndex = activeTaskIndex
    }

    public var timeString: String {
        let m = timeRemaining / 60
        let s = timeRemaining % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Paused Timer Session Snapshot (App Relaunch Recovery)
public struct PausedTimerSession: Codable, Equatable {
    public var activePreset: String
    public var activeMode: String
    public var isBreakSession: Bool
    public var totalTime: Int
    public var timeRemaining: Int
    public var preciseProgress: Double
    public var customMinutes: Int
    public var customSeconds: Int
    public var currentSession: Int
    public var activeTaskIndex: Int

    public init(
        activePreset: String,
        activeMode: String = "Pomodoro",
        isBreakSession: Bool = false,
        totalTime: Int,
        timeRemaining: Int,
        preciseProgress: Double,
        customMinutes: Int = 25,
        customSeconds: Int = 0,
        currentSession: Int = 1,
        activeTaskIndex: Int = 0
    ) {
        self.activePreset = activePreset
        self.activeMode = activeMode
        self.isBreakSession = isBreakSession
        self.totalTime = totalTime
        self.timeRemaining = timeRemaining
        self.preciseProgress = preciseProgress
        self.customMinutes = customMinutes
        self.customSeconds = customSeconds
        self.currentSession = currentSession
        self.activeTaskIndex = activeTaskIndex
    }

    public var timeString: String {
        let m = timeRemaining / 60
        let s = timeRemaining % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Active Session Recovery State (Task 8: Crash / Force-Quit Recovery)
public struct ActiveSessionRecoveryState: Codable, Equatable {
    public var version: Int
    public var isTimerRunning: Bool
    public var timerSessionId: UUID
    public var activePreset: String
    public var activeMode: String
    public var isBreakSession: Bool
    public var totalTime: Int
    public var timeRemaining: Int
    public var fractionalRemaining: Double?
    public var preciseProgress: Double
    public var targetEndDate: Date?
    public var sessionSegmentStartDate: Date?
    public var segmentCreditedSeconds: Int
    public var activeSessionTaskId: UUID?
    public var currentSession: Int
    public var customMinutes: Int
    public var customSeconds: Int

    public var isStopwatchRunning: Bool
    public var stopwatchElapsedSeconds: Double
    public var stopwatchTaskId: UUID?

    // Task 9: Idle Time Review Recovery
    public var isDeferredCompletionPending: Bool?
    public var pendingIdleIntervals: [IdleReviewInterval]?
    public var sessionExclusionLedger: [SessionExclusionRecord]?

    public var checkpointTimestamp: Date

    public init(
        version: Int = 1,
        isTimerRunning: Bool = false,
        timerSessionId: UUID = UUID(),
        activePreset: String = "Focus",
        activeMode: String = "Pomodoro",
        isBreakSession: Bool = false,
        totalTime: Int = 1500,
        timeRemaining: Int = 1500,
        fractionalRemaining: Double? = nil,
        preciseProgress: Double = 1.0,
        targetEndDate: Date? = nil,
        sessionSegmentStartDate: Date? = nil,
        segmentCreditedSeconds: Int = 0,
        activeSessionTaskId: UUID? = nil,
        currentSession: Int = 1,
        customMinutes: Int = 25,
        customSeconds: Int = 0,
        isStopwatchRunning: Bool = false,
        stopwatchElapsedSeconds: Double = 0.0,
        stopwatchTaskId: UUID? = nil,
        isDeferredCompletionPending: Bool? = nil,
        pendingIdleIntervals: [IdleReviewInterval]? = nil,
        sessionExclusionLedger: [SessionExclusionRecord]? = nil,
        checkpointTimestamp: Date = Date()
    ) {
        self.version = version
        self.isTimerRunning = isTimerRunning
        self.timerSessionId = timerSessionId
        self.activePreset = activePreset
        self.activeMode = activeMode
        self.isBreakSession = isBreakSession
        self.totalTime = totalTime
        self.timeRemaining = timeRemaining
        self.fractionalRemaining = fractionalRemaining
        self.preciseProgress = preciseProgress
        self.targetEndDate = targetEndDate
        self.sessionSegmentStartDate = sessionSegmentStartDate
        self.segmentCreditedSeconds = max(0, segmentCreditedSeconds)
        self.activeSessionTaskId = activeSessionTaskId
        self.currentSession = currentSession
        self.customMinutes = customMinutes
        self.customSeconds = customSeconds
        self.isStopwatchRunning = isStopwatchRunning
        self.stopwatchElapsedSeconds = max(0.0, stopwatchElapsedSeconds)
        self.stopwatchTaskId = stopwatchTaskId
        self.isDeferredCompletionPending = isDeferredCompletionPending
        self.pendingIdleIntervals = pendingIdleIntervals
        self.sessionExclusionLedger = sessionExclusionLedger
        self.checkpointTimestamp = checkpointTimestamp
    }
}

// MARK: - Persistent App State Payload
public struct FocusAppData: Codable, Equatable {
    public var tasks: [FocusTask]
    public var focusedSeconds: Int
    public var completedSessions: Int
    public var notes: [String]
    public var dailyGoalHours: Int
    public var totalSessions: Int
    public var autoStartNextSession: Bool
    public var activePreset: String
    public var clockStyle: String
    public var sessionRecords: [FocusSessionRecord]
    public var legacyLifetimeFocusedSeconds: Int?
    public var laps: [StopwatchLap]
    public var preservedSession: PreservedTimerSession?
    public var pausedSession: PausedTimerSession?
    public var stopwatchElapsedSeconds: TimeInterval
    public var lastRecordedLapElapsedSeconds: TimeInterval?
    public var nextLapNumber: Int?
    // Task 4: Idle Timer Configuration & Selection Persistence
    public var selectedTaskId: UUID?
    public var activeMode: String?
    public var configuredTotalTime: Int?
    public var configuredCustomMinutes: Int?
    public var configuredCustomSeconds: Int?
    public var configuredCurrentSession: Int?
    public var configuredIsBreakSession: Bool?
    // Task 8: Crash / Force-Quit Recovery State
    public var activeSessionRecovery: ActiveSessionRecoveryState?
    // Task 9: Idle Time Review Settings and Unresolved Reviews
    public var idleReviewEnabled: Bool?
    public var idleThresholdSeconds: Int?
    public var pendingIdleIntervals: [IdleReviewInterval]?
    public var sessionExclusionLedger: [SessionExclusionRecord]?

    enum CodingKeys: String, CodingKey {
        case tasks
        case focusedSeconds
        case completedSessions
        case notes
        case dailyGoalHours
        case totalSessions
        case autoStartNextSession
        case activePreset
        case clockStyle
        case sessionRecords
        case legacyLifetimeFocusedSeconds
        case laps
        case preservedSession
        case pausedSession
        case stopwatchElapsedSeconds
        case lastRecordedLapElapsedSeconds
        case nextLapNumber
        // Task 4 Keys
        case selectedTaskId
        case activeMode
        case configuredTotalTime
        case configuredCustomMinutes
        case configuredCustomSeconds
        case configuredCurrentSession
        case configuredIsBreakSession
        case activeSessionRecovery
        // Task 9 Keys
        case idleReviewEnabled
        case idleThresholdSeconds
        case pendingIdleIntervals
        case sessionExclusionLedger
    }

    public init(
        tasks: [FocusTask] = [],
        focusedSeconds: Int = 0,
        completedSessions: Int = 0,
        notes: [String] = [],
        dailyGoalHours: Int = 4,
        totalSessions: Int = 4,
        autoStartNextSession: Bool = false,
        activePreset: String = "Focus",
        clockStyle: String = "Digital",
        sessionRecords: [FocusSessionRecord] = [],
        legacyLifetimeFocusedSeconds: Int? = nil,
        laps: [StopwatchLap] = [],
        preservedSession: PreservedTimerSession? = nil,
        pausedSession: PausedTimerSession? = nil,
        stopwatchElapsedSeconds: TimeInterval = 0.0,
        lastRecordedLapElapsedSeconds: TimeInterval? = nil,
        nextLapNumber: Int? = nil,
        selectedTaskId: UUID? = nil,
        activeMode: String? = nil,
        configuredTotalTime: Int? = nil,
        configuredCustomMinutes: Int? = nil,
        configuredCustomSeconds: Int? = nil,
        configuredCurrentSession: Int? = nil,
        configuredIsBreakSession: Bool? = nil,
        activeSessionRecovery: ActiveSessionRecoveryState? = nil,
        idleReviewEnabled: Bool? = nil,
        idleThresholdSeconds: Int? = nil,
        pendingIdleIntervals: [IdleReviewInterval]? = nil,
        sessionExclusionLedger: [SessionExclusionRecord]? = nil
    ) {
        self.tasks = tasks
        self.focusedSeconds = focusedSeconds
        self.completedSessions = completedSessions
        self.notes = notes
        self.dailyGoalHours = dailyGoalHours
        self.totalSessions = totalSessions
        self.autoStartNextSession = autoStartNextSession
        self.activePreset = activePreset
        self.clockStyle = clockStyle
        self.sessionRecords = sessionRecords
        self.legacyLifetimeFocusedSeconds = legacyLifetimeFocusedSeconds
        self.laps = laps
        self.preservedSession = preservedSession
        self.pausedSession = pausedSession
        if stopwatchElapsedSeconds.isFinite && stopwatchElapsedSeconds > 0 {
            self.stopwatchElapsedSeconds = stopwatchElapsedSeconds
        } else {
            self.stopwatchElapsedSeconds = 0.0
        }
        if let lastLap = lastRecordedLapElapsedSeconds, lastLap.isFinite && lastLap >= 0 {
            self.lastRecordedLapElapsedSeconds = lastLap
        } else {
            self.lastRecordedLapElapsedSeconds = nil
        }
        if let nextNum = nextLapNumber, nextNum > 0 {
            self.nextLapNumber = nextNum
        } else {
            self.nextLapNumber = nil
        }
        self.selectedTaskId = selectedTaskId
        self.activeMode = activeMode
        self.configuredTotalTime = configuredTotalTime
        self.configuredCustomMinutes = configuredCustomMinutes
        self.configuredCustomSeconds = configuredCustomSeconds
        self.configuredCurrentSession = configuredCurrentSession
        self.configuredIsBreakSession = configuredIsBreakSession
        self.activeSessionRecovery = activeSessionRecovery
        self.idleReviewEnabled = idleReviewEnabled
        self.idleThresholdSeconds = idleThresholdSeconds
        self.pendingIdleIntervals = pendingIdleIntervals
        self.sessionExclusionLedger = sessionExclusionLedger
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tasks = try container.decodeIfPresent([FocusTask].self, forKey: .tasks) ?? []
        self.focusedSeconds = try container.decodeIfPresent(Int.self, forKey: .focusedSeconds) ?? 0
        self.completedSessions = try container.decodeIfPresent(Int.self, forKey: .completedSessions) ?? 0
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        self.dailyGoalHours = try container.decodeIfPresent(Int.self, forKey: .dailyGoalHours) ?? 4
        self.totalSessions = try container.decodeIfPresent(Int.self, forKey: .totalSessions) ?? 4
        self.autoStartNextSession = try container.decodeIfPresent(Bool.self, forKey: .autoStartNextSession) ?? false
        self.activePreset = try container.decodeIfPresent(String.self, forKey: .activePreset) ?? "Focus"
        self.clockStyle = try container.decodeIfPresent(String.self, forKey: .clockStyle) ?? "Digital"
        self.sessionRecords = try container.decodeIfPresent([FocusSessionRecord].self, forKey: .sessionRecords) ?? []
        self.legacyLifetimeFocusedSeconds = try container.decodeIfPresent(Int.self, forKey: .legacyLifetimeFocusedSeconds)
        self.laps = try container.decodeIfPresent([StopwatchLap].self, forKey: .laps) ?? []
        self.preservedSession = try container.decodeIfPresent(PreservedTimerSession.self, forKey: .preservedSession)
        self.pausedSession = try container.decodeIfPresent(PausedTimerSession.self, forKey: .pausedSession)
        let decodedElapsed = try container.decodeIfPresent(Double.self, forKey: .stopwatchElapsedSeconds) ?? 0.0
        if decodedElapsed.isFinite && decodedElapsed > 0 {
            self.stopwatchElapsedSeconds = decodedElapsed
        } else {
            self.stopwatchElapsedSeconds = 0.0
        }

        let decodedLastLap = try container.decodeIfPresent(Double.self, forKey: .lastRecordedLapElapsedSeconds)
        if let decodedLastLap = decodedLastLap, decodedLastLap.isFinite && decodedLastLap >= 0 {
            self.lastRecordedLapElapsedSeconds = decodedLastLap
        } else {
            self.lastRecordedLapElapsedSeconds = nil
        }

        let decodedNextLapNumber = try container.decodeIfPresent(Int.self, forKey: .nextLapNumber)
        if let decodedNextLapNumber = decodedNextLapNumber, decodedNextLapNumber > 0 {
            self.nextLapNumber = decodedNextLapNumber
        } else {
            self.nextLapNumber = nil
        }

        self.selectedTaskId = try container.decodeIfPresent(UUID.self, forKey: .selectedTaskId)
        self.activeMode = try container.decodeIfPresent(String.self, forKey: .activeMode)
        self.configuredTotalTime = try container.decodeIfPresent(Int.self, forKey: .configuredTotalTime)
        self.configuredCustomMinutes = try container.decodeIfPresent(Int.self, forKey: .configuredCustomMinutes)
        self.configuredCustomSeconds = try container.decodeIfPresent(Int.self, forKey: .configuredCustomSeconds)
        self.configuredCurrentSession = try container.decodeIfPresent(Int.self, forKey: .configuredCurrentSession)
        self.configuredIsBreakSession = try container.decodeIfPresent(Bool.self, forKey: .configuredIsBreakSession)

        do {
            self.activeSessionRecovery = try container.decodeIfPresent(ActiveSessionRecoveryState.self, forKey: .activeSessionRecovery)
        } catch {
            print("[FocusStorageService] Warning: Failed to decode activeSessionRecovery: \(error)")
            self.activeSessionRecovery = nil
        }

        self.idleReviewEnabled = try container.decodeIfPresent(Bool.self, forKey: .idleReviewEnabled)
        self.idleThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds)
        self.pendingIdleIntervals = try container.decodeIfPresent([IdleReviewInterval].self, forKey: .pendingIdleIntervals)
        self.sessionExclusionLedger = try container.decodeIfPresent([SessionExclusionRecord].self, forKey: .sessionExclusionLedger)

        // Backward compatibility migration:
        // If sessionRecords is empty and legacyLifetimeFocusedSeconds was nil,
        // and no active/deferred session is in flight (activeSessionRecovery is nil),
        // but focusedSeconds > 0, preserve that focusedSeconds as legacy lifetime focus,
        // so it does NOT falsely get assigned to today's focus!
        if self.sessionRecords.isEmpty && self.legacyLifetimeFocusedSeconds == nil && self.activeSessionRecovery == nil && self.focusedSeconds > 0 {
            self.legacyLifetimeFocusedSeconds = self.focusedSeconds
        }
    }
}

// MARK: - Storage Result & Error Model
public enum StorageLoadResult: Equatable {
    case freshInstall
    case success(FocusAppData)
    case recovered(FocusAppData, backupURL: URL, diagnosticURL: URL?)
    case unrecoverable(StorageError)
}

public enum StorageError: LocalizedError, Equatable, CustomStringConvertible {
    case corruptedPrimary(URL, underlyingError: String)
    case corruptedPrimaryAndBackup(primaryURL: URL, backupURL: URL, primaryError: String, backupError: String)
    case corruptedBackupMissingPrimary(URL, underlyingError: String)
    case backupFailed(URL, underlyingError: String)
    case writeFailed(URL, underlyingError: String)
    case diagnosticPreservationFailed(URL, underlyingError: String)
    case persistenceBlocked(reason: String)

    public var errorDescription: String? {
        description
    }

    public var description: String {
        switch self {
        case .corruptedPrimary(let url, let err):
            return "Primary save file is corrupted at \(url.lastPathComponent): \(err)"
        case .corruptedPrimaryAndBackup(let pURL, let bURL, let pErr, let bErr):
            return "Both primary (\(pURL.lastPathComponent): \(pErr)) and backup (\(bURL.lastPathComponent): \(bErr)) are unreadable."
        case .corruptedBackupMissingPrimary(let url, let err):
            return "Primary save file is missing and backup is corrupted at \(url.lastPathComponent): \(err)"
        case .backupFailed(let url, let err):
            return "Failed to create or update backup at \(url.lastPathComponent): \(err)"
        case .writeFailed(let url, let err):
            return "Failed to write storage data to \(url.lastPathComponent): \(err)"
        case .diagnosticPreservationFailed(let url, let err):
            return "Failed to safely preserve corrupted file to diagnostic path \(url.lastPathComponent): \(err)"
        case .persistenceBlocked(let reason):
            return "Persistence blocked: \(reason)"
        }
    }
}

// MARK: - Focus Storage Service (Atomic File Storage, Backup & Test Isolation)
public final class FocusStorageService {
    public static let shared = FocusStorageService()
    private let fileManager: FileManager
    private let customStorageURL: URL?

    public private(set) var isPersistenceBlocked: Bool = false
    public private(set) var lastLoadResult: StorageLoadResult?
    public private(set) var lastError: StorageError?
    public internal(set) var hasInterruptedInitialSave: Bool = false

    // Testing hooks for simulating disk/IO failures
    public var simulateBackupFailure: Bool = false
    public var simulateWriteFailure: Bool = false
    public var simulateDiagnosticFailure: Bool = false
    public var simulateRestoreFailure: Bool = false
    public var onSavePayload: ((FocusAppData) -> Void)?
    public private(set) var saveAttemptCount: Int = 0

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.customStorageURL = storageURL
        self.fileManager = fileManager
    }

    public var effectiveStorageURL: URL {
        if let custom = customStorageURL {
            let parentDir = custom.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            return custom
        }
        if let envPath = ProcessInfo.processInfo.environment["FOCUSFLOW_STORAGE_PATH"], !envPath.isEmpty {
            let envURL = URL(fileURLWithPath: envPath)
            let parentDir = envURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            return envURL
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let focusFlowDir = appSupport.appendingPathComponent("FocusFlow", isDirectory: true)
        if !fileManager.fileExists(atPath: focusFlowDir.path) {
            try? fileManager.createDirectory(at: focusFlowDir, withIntermediateDirectories: true)
        }
        return focusFlowDir.appendingPathComponent("focusflow_data.json")
    }

    public var backupURL: URL {
        effectiveStorageURL.appendingPathExtension("bak")
    }

    public func makeDiagnosticURL() -> URL {
        let primary = effectiveStorageURL
        let parentDir = primary.deletingLastPathComponent()
        let baseName = primary.deletingPathExtension().lastPathComponent
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let timeStr = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uniqueID = UUID().uuidString.prefix(8)
        let filename = "\(baseName)_corrupted_\(timeStr)_\(uniqueID).json"
        return parentDir.appendingPathComponent(filename)
    }

    public var hasPersistedData: Bool {
        fileManager.fileExists(atPath: effectiveStorageURL.path) || fileManager.fileExists(atPath: backupURL.path)
    }

    public func resetSaveAttemptCount() {
        saveAttemptCount = 0
    }

    public func resetBlockedStateForTesting() {
        isPersistenceBlocked = false
        lastError = nil
        hasInterruptedInitialSave = false
        simulateBackupFailure = false
        simulateWriteFailure = false
        simulateDiagnosticFailure = false
        simulateRestoreFailure = false
        saveAttemptCount = 0
    }

    public func decodeData(from url: URL) throws -> FocusAppData {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FocusAppData.self, from: data)
    }

    public func loadDetailed() -> StorageLoadResult {
        let primaryURL = effectiveStorageURL
        let backupURL = self.backupURL

        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        // 1. Fresh installation: Neither primary save nor backup exists
        if !primaryExists && !backupExists {
            isPersistenceBlocked = false
            let result = StorageLoadResult.freshInstall
            self.lastLoadResult = result
            return result
        }

        // 2. Primary file exists: attempt to decode primary
        if primaryExists {
            do {
                let primaryData = try decodeData(from: primaryURL)
                isPersistenceBlocked = false
                let result = StorageLoadResult.success(primaryData)
                self.lastLoadResult = result
                return result
            } catch let primaryError {
                print("[FocusStorageService] Warning: Failed to decode primary save file at \(primaryURL.path): \(primaryError)")

                // Primary is corrupted/unreadable. Check if a valid backup exists.
                guard backupExists else {
                    let storageErr = StorageError.corruptedPrimary(primaryURL, underlyingError: primaryError.localizedDescription)
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                // Attempt to load and validate backup
                let backupData: FocusAppData
                do {
                    backupData = try decodeData(from: backupURL)
                } catch let backupError {
                    print("[FocusStorageService] Error: Both primary and backup save files are corrupted!")
                    let storageErr = StorageError.corruptedPrimaryAndBackup(
                        primaryURL: primaryURL,
                        backupURL: backupURL,
                        primaryError: primaryError.localizedDescription,
                        backupError: backupError.localizedDescription
                    )
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                // Valid backup found!
                // Step 3: Preserve original corrupted primary file byte-for-byte in diagnostic file before replacing it.
                if simulateDiagnosticFailure {
                    let storageErr = StorageError.diagnosticPreservationFailed(primaryURL, underlyingError: "Simulated diagnostic preservation failure")
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                let diagnosticURL = makeDiagnosticURL()
                do {
                    try fileManager.copyItem(at: primaryURL, to: diagnosticURL)
                } catch let diagError {
                    print("[FocusStorageService] Error: Failed to safely preserve corrupted file to \(diagnosticURL.path): \(diagError)")
                    let storageErr = StorageError.diagnosticPreservationFailed(diagnosticURL, underlyingError: diagError.localizedDescription)
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                // Step 4: Restore validated backup safely to primary path.
                if simulateRestoreFailure {
                    let storageErr = StorageError.writeFailed(primaryURL, underlyingError: "Simulated primary restore failure")
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                do {
                    let backupBytes = try Data(contentsOf: backupURL)
                    try backupBytes.write(to: primaryURL, options: [.atomic])
                } catch let restoreError {
                    print("[FocusStorageService] Error: Failed to restore validated backup to primary path: \(restoreError)")
                    let storageErr = StorageError.writeFailed(primaryURL, underlyingError: restoreError.localizedDescription)
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                // Step 5: Keep valid backup available.
                // Step 6: Report recovery occurred.
                isPersistenceBlocked = false
                let result = StorageLoadResult.recovered(backupData, backupURL: backupURL, diagnosticURL: diagnosticURL)
                self.lastLoadResult = result
                return result
            }
        } else {
            // Primary file does not exist, but backup exists!
            do {
                let backupData = try decodeData(from: backupURL)

                if simulateRestoreFailure {
                    let storageErr = StorageError.writeFailed(primaryURL, underlyingError: "Simulated primary restore failure")
                    self.lastError = storageErr
                    self.isPersistenceBlocked = true
                    let result = StorageLoadResult.unrecoverable(storageErr)
                    self.lastLoadResult = result
                    return result
                }

                // Restore validated backup safely to primary path
                let backupBytes = try Data(contentsOf: backupURL)
                try backupBytes.write(to: primaryURL, options: [.atomic])

                isPersistenceBlocked = false
                let result = StorageLoadResult.recovered(backupData, backupURL: backupURL, diagnosticURL: nil)
                self.lastLoadResult = result
                return result
            } catch let backupError {
                print("[FocusStorageService] Error: Primary missing and backup save file is corrupted: \(backupError)")
                let storageErr = StorageError.corruptedBackupMissingPrimary(backupURL, underlyingError: backupError.localizedDescription)
                self.lastError = storageErr
                self.isPersistenceBlocked = true
                let result = StorageLoadResult.unrecoverable(storageErr)
                self.lastLoadResult = result
                return result
            }
        }
    }

    public func load() -> FocusAppData? {
        switch loadDetailed() {
        case .success(let data), .recovered(let data, _, _):
            return data
        case .freshInstall, .unrecoverable:
            return nil
        }
    }

    public func save(_ data: FocusAppData) throws {
        saveAttemptCount += 1
        onSavePayload?(data)
        guard !isPersistenceBlocked else {
            let error = StorageError.persistenceBlocked(reason: "Persistence is blocked due to unrecoverable storage state")
            self.lastError = error
            throw error
        }

        // 1. Encode and validate payload
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let encodedData: Data
        do {
            encodedData = try encoder.encode(data)
        } catch {
            let storageErr = StorageError.writeFailed(effectiveStorageURL, underlyingError: "JSON encoding failed: \(error.localizedDescription)")
            self.lastError = storageErr
            throw storageErr
        }

        let primaryURL = effectiveStorageURL
        let backupURL = self.backupURL
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        // Case C: Primary is missing but an existing backup is present
        if !primaryExists && backupExists {
            // First, decode and validate the existing backup
            let backupData: FocusAppData
            do {
                backupData = try decodeData(from: backupURL)
            } catch {
                print("[FocusStorageService] Error: Primary missing and backup save file is corrupted: \(error)")
                let storageErr = StorageError.corruptedBackupMissingPrimary(backupURL, underlyingError: error.localizedDescription)
                self.lastError = storageErr
                self.isPersistenceBlocked = true
                throw storageErr
            }

            // Check if this is an interrupted initial save:
            // either tracked by hasInterruptedInitialSave or the backup matches the in-memory data to be saved
            let isInterruptedInitialSave = self.hasInterruptedInitialSave || (backupData == data)
            guard isInterruptedInitialSave else {
                let error = StorageError.persistenceBlocked(reason: "Primary file is missing while an existing backup is present. Overwrite blocked to protect existing backup.")
                self.lastError = error
                self.isPersistenceBlocked = true
                throw error
            }

            // Safely complete the initial save by writing and validating the primary file
            if simulateWriteFailure {
                let error = StorageError.writeFailed(primaryURL, underlyingError: "Simulated primary write failure")
                self.lastError = error
                throw error
            }

            do {
                try encodedData.write(to: primaryURL, options: [.atomic])
                _ = try decodeData(from: primaryURL)
            } catch {
                print("[FocusStorageService] Error: Failed to write or validate primary file during recovery of interrupted save: \(error)")
                let storageErr = StorageError.writeFailed(primaryURL, underlyingError: error.localizedDescription)
                self.lastError = storageErr
                throw storageErr
            }

            // Both primary and backup now exist and validate!
            self.hasInterruptedInitialSave = false
            return
        }

        // Case A: Fresh installation (neither primary nor backup exists)
        if !primaryExists && !backupExists {
            // Step 2: Atomically write and validate initial backup FIRST
            if simulateBackupFailure {
                let error = StorageError.backupFailed(backupURL, underlyingError: "Simulated backup failure")
                self.lastError = error
                throw error
            }

            do {
                try encodedData.write(to: backupURL, options: [.atomic])
                _ = try decodeData(from: backupURL)
            } catch {
                print("[FocusStorageService] Error: Failed to write or validate initial backup: \(error)")
                let storageErr = StorageError.backupFailed(backupURL, underlyingError: error.localizedDescription)
                self.lastError = storageErr
                throw storageErr
            }

            // Step 3: Only after backup exists and is valid, atomically write primary file
            if simulateWriteFailure {
                // "If primary creation fails after the backup succeeds, retain the valid backup so startup recovery can restore it."
                // "Do not delete the valid backup as part of error cleanup."
                self.hasInterruptedInitialSave = true
                let error = StorageError.writeFailed(primaryURL, underlyingError: "Simulated primary write failure")
                self.lastError = error
                throw error
            }

            do {
                try encodedData.write(to: primaryURL, options: [.atomic])
                _ = try decodeData(from: primaryURL)
            } catch {
                print("[FocusStorageService] Error: Failed to write or validate primary file on fresh install: \(error)")
                self.hasInterruptedInitialSave = true
                let storageErr = StorageError.writeFailed(primaryURL, underlyingError: error.localizedDescription)
                self.lastError = storageErr
                throw storageErr
            }

            // Step 4: Report success only after both required files exist and validate
            self.hasInterruptedInitialSave = false
            return
        }

        // Case B: Subsequent save (primaryExists == true)
        // Check if existing primary is valid before touching backup
        let primaryIsValid: Bool
        var existingPrimaryBytes = Data()
        do {
            let bytes = try Data(contentsOf: primaryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(FocusAppData.self, from: bytes)
            existingPrimaryBytes = bytes
            primaryIsValid = true
        } catch {
            primaryIsValid = false
        }

        if !primaryIsValid {
            // Existing primary is corrupted! NEVER overwrite backup with corrupted data or overwrite primary!
            self.isPersistenceBlocked = true
            let error = StorageError.persistenceBlocked(reason: "Primary save file is corrupted. Normal saves are blocked to protect data.")
            self.lastError = error
            throw error
        }

        // Primary is valid: back up existing valid primary before writing new data
        if simulateBackupFailure {
            let error = StorageError.backupFailed(backupURL, underlyingError: "Simulated backup failure")
            self.lastError = error
            throw error
        }

        do {
            try existingPrimaryBytes.write(to: backupURL, options: [.atomic])
            _ = try decodeData(from: backupURL)
        } catch {
            print("[FocusStorageService] Error: Failed to create or update backup at \(backupURL.path): \(error)")
            let storageErr = StorageError.backupFailed(backupURL, underlyingError: error.localizedDescription)
            self.lastError = storageErr
            throw storageErr
        }

        // Now write new encoded data to primary
        if simulateWriteFailure {
            let error = StorageError.writeFailed(primaryURL, underlyingError: "Simulated primary write failure")
            self.lastError = error
            throw error
        }

        do {
            try encodedData.write(to: primaryURL, options: [.atomic])
            _ = try decodeData(from: primaryURL)
        } catch {
            print("[FocusStorageService] Error: Failed to write primary storage data to \(primaryURL.path): \(error)")
            let storageErr = StorageError.writeFailed(primaryURL, underlyingError: error.localizedDescription)
            self.lastError = storageErr
            throw storageErr
        }
    }
}
