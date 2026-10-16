import Foundation

// MARK: - Focus Session Record (Date-Aware Analytics)
public struct FocusSessionRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public let durationSeconds: Int
    public let mode: String
    public let taskId: UUID?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        durationSeconds: Int,
        mode: String,
        taskId: UUID? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = max(0, durationSeconds)
        self.mode = mode
        self.taskId = taskId
    }

    /// Computes how many seconds of this session fall within the specified calendar day.
    /// Accurately accounts for midnight transitions using proportional date interval overlap.
    public func duration(on date: Date, calendar: Calendar = .current) -> Int {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return 0
        }
        let effectiveStart = max(startTime, dayStart)
        let effectiveEnd = min(endTime, dayEnd)
        if effectiveEnd > effectiveStart {
            let totalSpan = max(1.0, endTime.timeIntervalSince(startTime))
            let overlap = effectiveEnd.timeIntervalSince(effectiveStart)
            let ratio = min(1.0, max(0.0, overlap / totalSpan))
            return Int(round(Double(durationSeconds) * ratio))
        }
        return 0
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

// MARK: - Persistent App State Payload
public struct FocusAppData: Codable {
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
        stopwatchElapsedSeconds: TimeInterval = 0.0
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

        // Backward compatibility migration:
        // If sessionRecords is empty and legacyLifetimeFocusedSeconds was nil,
        // but focusedSeconds > 0, preserve that focusedSeconds as legacy lifetime focus,
        // so it does NOT falsely get assigned to today's focus!
        if self.sessionRecords.isEmpty && self.legacyLifetimeFocusedSeconds == nil && self.focusedSeconds > 0 {
            self.legacyLifetimeFocusedSeconds = self.focusedSeconds
        }
    }
}

// MARK: - Focus Storage Service (Atomic File Storage & Test Isolation)
public final class FocusStorageService {
    public static let shared = FocusStorageService()
    private let fileManager: FileManager
    private let customStorageURL: URL?

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
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let focusFlowDir = appSupport.appendingPathComponent("FocusFlow", isDirectory: true)
        if !fileManager.fileExists(atPath: focusFlowDir.path) {
            try? fileManager.createDirectory(at: focusFlowDir, withIntermediateDirectories: true)
        }
        return focusFlowDir.appendingPathComponent("focusflow_data.json")
    }

    public var hasPersistedData: Bool {
        fileManager.fileExists(atPath: effectiveStorageURL.path)
    }

    public func load() -> FocusAppData? {
        let url = effectiveStorageURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FocusAppData.self, from: data)
        } catch {
            print("[FocusStorageService] Warning: Failed to decode storage data from \(url): \(error)")
            return nil
        }
    }

    public func save(_ data: FocusAppData) {
        let url = effectiveStorageURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        do {
            let encoded = try encoder.encode(data)
            try encoded.write(to: url, options: [.atomic])
        } catch {
            print("[FocusStorageService] Error: Failed to write storage data to \(url): \(error)")
        }
    }
}
