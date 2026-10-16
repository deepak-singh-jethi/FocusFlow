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

// MARK: - Storage Result & Error Model
public enum StorageLoadResult: Equatable {
    case freshInstall
    case success(FocusAppData)
    case recovered(FocusAppData, backupURL: URL, diagnosticURL: URL?)
    case unrecoverable(StorageError)
}

public enum StorageError: Error, Equatable, CustomStringConvertible {
    case corruptedPrimary(URL, underlyingError: String)
    case corruptedPrimaryAndBackup(primaryURL: URL, backupURL: URL, primaryError: String, backupError: String)
    case corruptedBackupMissingPrimary(URL, underlyingError: String)
    case backupFailed(URL, underlyingError: String)
    case writeFailed(URL, underlyingError: String)
    case diagnosticPreservationFailed(URL, underlyingError: String)
    case persistenceBlocked(reason: String)

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

    // Testing hooks for simulating disk/IO failures
    public var simulateBackupFailure: Bool = false
    public var simulateWriteFailure: Bool = false
    public var simulateDiagnosticFailure: Bool = false
    public var simulateRestoreFailure: Bool = false

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

    public func resetBlockedStateForTesting() {
        isPersistenceBlocked = false
        lastError = nil
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
        guard !isPersistenceBlocked else {
            let error = StorageError.persistenceBlocked(reason: "Persistence is blocked due to unrecoverable storage state")
            self.lastError = error
            throw error
        }

        if simulateWriteFailure {
            let error = StorageError.writeFailed(effectiveStorageURL, underlyingError: "Simulated primary write failure")
            self.lastError = error
            throw error
        }

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

        if primaryExists {
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
                // If primary file is corrupted, NEVER overwrite backup with corrupted data or overwrite primary!
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
            } catch {
                print("[FocusStorageService] Error: Failed to create or update backup at \(backupURL.path): \(error)")
                let storageErr = StorageError.backupFailed(backupURL, underlyingError: error.localizedDescription)
                self.lastError = storageErr
                throw storageErr
            }
        }

        // Now write new encoded data to primary
        do {
            try encodedData.write(to: primaryURL, options: [.atomic])
        } catch {
            print("[FocusStorageService] Error: Failed to write primary storage data to \(primaryURL.path): \(error)")
            let storageErr = StorageError.writeFailed(primaryURL, underlyingError: error.localizedDescription)
            self.lastError = storageErr
            throw storageErr
        }

        // If primary did not exist previously (fresh install first save), also write initial backup
        if !primaryExists {
            if simulateBackupFailure {
                let error = StorageError.backupFailed(backupURL, underlyingError: "Simulated backup failure")
                self.lastError = error
                throw error
            }
            do {
                try encodedData.write(to: backupURL, options: [.atomic])
            } catch {
                print("[FocusStorageService] Error: Failed to write initial backup at \(backupURL.path): \(error)")
                let storageErr = StorageError.backupFailed(backupURL, underlyingError: error.localizedDescription)
                self.lastError = storageErr
                throw storageErr
            }
        }
    }
}
