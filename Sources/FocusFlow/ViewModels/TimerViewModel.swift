import SwiftUI
import Combine
import AppKit

// MARK: - Timer & App State ViewModel (Persistent, Date-Aware & Power-Efficient)
@MainActor
public class TimerViewModel: ObservableObject {
    // MARK: - Supported Timer Duration Bounds
    public static let minSupportedTimerDuration: Int = 5
    public static let maxSupportedTimerDuration: Int = 360 * 60 + 59 // 21,659 seconds (360m 59s)

    @Published public var timeRemaining: Int = 25 * 60 {
        didSet {
            if isTimerRunning, let target = targetEndDate {
                let currentSecs = Int(ceil(target.timeIntervalSinceNow))
                if abs(currentSecs - timeRemaining) > 1 {
                    targetEndDate = Date().addingTimeInterval(TimeInterval(timeRemaining))
                    fractionalRemaining = nil
                }
            }
        }
    }
    @Published public var totalTime: Int = 25 * 60
    @Published public var currentSession: Int = 1 {
        didSet {
            if pausedSession != nil {
                pausedSession?.currentSession = currentSession
            }
            guard !isLoadingPersistedData else { return }
            persistData()
        }
    }
    private var isRevertingBlockedSetting = false

    @Published public var totalSessions: Int = 4 {
        didSet {
            guard !isRevertingBlockedSetting else { return }
            if isPersistenceBlocked {
                isRevertingBlockedSetting = true
                totalSessions = oldValue
                isRevertingBlockedSetting = false
                return
            }
            persistData()
        }
    }
    @Published public var preciseProgress: Double = 1.0
    @Published public var isTimerRunning: Bool = false
    public var targetEndDate: Date?
    private var fractionalRemaining: TimeInterval?

    // Custom Duration States
    @Published public var customMinutes: Int = 25 {
        didSet {
            guard !isLoadingPersistedData else { return }
            let safeM = max(0, min(customMinutes, 360))
            if safeM != customMinutes { customMinutes = safeM; return }
            let total = safeM * 60 + customSeconds
            customDurationSeconds = max(5, total)
            if activePreset == "Custom" || activeMode == "Custom Timer" {
                if !isTimerRunning && (pausedSession == nil) {
                    totalTime = customDurationSeconds
                    timeRemaining = customDurationSeconds
                    preciseProgress = 1.0
                }
            }
            persistData()
        }
    }
    @Published public var customSeconds: Int = 0 {
        didSet {
            guard !isLoadingPersistedData else { return }
            let safeS = max(0, min(customSeconds, 59))
            if safeS != customSeconds { customSeconds = safeS; return }
            let total = customMinutes * 60 + safeS
            customDurationSeconds = max(5, total)
            if activePreset == "Custom" || activeMode == "Custom Timer" {
                if !isTimerRunning && (pausedSession == nil) {
                    totalTime = customDurationSeconds
                    timeRemaining = customDurationSeconds
                    preciseProgress = 1.0
                }
            }
            persistData()
        }
    }
    public private(set) var customDurationSeconds: Int = 25 * 60

    // Preset & Modes
    @Published public var activePreset: String = "Focus" {
        didSet { persistData() }
    }
    @Published public var isBreakSession: Bool = false {
        didSet { persistData() }
    }
    public var isBreakPreset: Bool { isBreakSession || activePreset == "Short Break" || activePreset == "Long Break" || activePreset == "Break" }
    public var isFocusPreset: Bool { !isBreakPreset }

    // MARK: Date-Aware Analytics & Session Records (Priority 2)
    @Published public var sessionRecords: [FocusSessionRecord] = []
    public var legacyLifetimeFocusedSeconds: Int? = nil
    @Published public var todayFocusedSeconds: Int = 0
    @Published public var weeklyFocusedSeconds: Int = 0
    @Published public var lifetimeFocusedSeconds: Int = 0
    @Published public var focusedSeconds: Int = 0 // Maintained for backward compatibility with existing views

    // Wall-clock segment tracking (prevents duplicate counting on pause/resume/tick)
    internal var sessionSegmentStartDate: Date?

    // MARK: Stopwatch States (Priority 5)
    @Published public var stopwatchTime: Int = 0
    @Published public var preciseStopwatchProgress: Double = 0.0
    @Published public var isStopwatchRunning: Bool = false
    @Published public var laps: [StopwatchLap] = []
    public var lapTimes: [String] {
        laps.map { lap in
            let m = Int(lap.totalTime) / 60
            let s = Int(lap.totalTime) % 60
            return String(format: "%02d:%02d", m, s)
        }
    }
    internal var stopwatchStartDate: Date?
    public internal(set) var stopwatchFractional: TimeInterval?
    public private(set) var lastRecordedLapElapsedSeconds: TimeInterval = 0.0
    public private(set) var nextLapNumber: Int = 1
    public private(set) var activeSessionTaskId: UUID? = nil

    // Task States (Persistent)
    @Published public var tasks: [FocusTask] = [
        FocusTask(title: "Deep Work Session", estimatedMinutes: 25, timeSpentSeconds: 0, icon: "star.fill", iconColor: .orange),
        FocusTask(title: "Project Review & Planning", estimatedMinutes: 30, timeSpentSeconds: 0, icon: "doc.text.fill", iconColor: .blue),
        FocusTask(title: "Core Development & Refactor", estimatedMinutes: 45, timeSpentSeconds: 0, icon: "laptopcomputer", iconColor: .purple),
        FocusTask(title: "Inbox & Team Follow-ups", estimatedMinutes: 15, timeSpentSeconds: 0, icon: "tray.fill", iconColor: .teal)
    ]
    @Published public var activeTaskIndex: Int = 0 {
        didSet {
            guard !isLoadingPersistedData else { return }
            if pausedSession != nil {
                pausedSession?.activeTaskIndex = activeTaskIndex
            }
        }
    }
    @Published public var completedSessions: Int = 0
    @Published public var notes: [String] = []
    @Published public var dailyGoalHours: Int = 4 {
        didSet {
            guard !isRevertingBlockedSetting else { return }
            if isPersistenceBlocked {
                isRevertingBlockedSetting = true
                dailyGoalHours = oldValue
                isRevertingBlockedSetting = false
                return
            }
            persistData()
        }
    }

    // Alerts & Modals
    @Published public var showPresetAlert: Bool = false
    @Published public var showResetAlert: Bool = false
    @Published public var showNoteEditor: Bool = false
    @Published public var noteDraft: String = ""
    public var pendingPreset: (name: String, minutes: Int)? = nil
    @Published public var autoStartNextSession: Bool = false {
        didSet {
            guard !isRevertingBlockedSetting else { return }
            if isPersistenceBlocked {
                isRevertingBlockedSetting = true
                autoStartNextSession = oldValue
                isRevertingBlockedSetting = false
                return
            }
            persistData()
        }
    }

    // MARK: - Paused Timer Session State (Step 1 App Restart Recovery)
    @Published public var pausedSession: PausedTimerSession?

    // MARK: - Companion Navigation Mode
    public enum CompanionMode: String, CaseIterable {
        case timer = "Focus Timer"
        case stopwatch = "Stopwatch"
    }
    @Published public var selectedCompanionMode: CompanionMode = .timer

    // MARK: - Preserved Background Session & Mode Conflict States
    public enum ConflictPresentationOrigin: String, Equatable {
        case mainWindow
        case menuBar
    }
    @Published public var preservedSession: PreservedTimerSession?
    @Published public var showConflictModal: Bool = false
    @Published public var conflictOrigin: ConflictPresentationOrigin? = nil
    public var pendingTimerRequest: (name: String, minutes: Int, seconds: Int, mode: String, isBreak: Bool)? = nil

    public var hasPreservedSession: Bool {
        preservedSession != nil
    }

    public var isTimerActive: Bool {
        isTimerRunning || (timeRemaining < totalTime && timeRemaining > 0)
    }

    // Dynamic helpers for mini-bar to accurately reflect active or preserved timer
    public var displayedTimerPreset: String {
        if isTimerActive {
            return activePreset
        } else if let preserved = preservedSession {
            return preserved.activePreset
        }
        return activePreset
    }

    public var displayedTimerTimeString: String {
        if isTimerActive {
            return timerTimeString
        } else if let preserved = preservedSession {
            return preserved.timeString
        }
        return timerTimeString
    }

    public var isDisplayedTimerRunning: Bool {
        isTimerRunning
    }

    public var displayedTimerProgress: Double {
        if isTimerActive {
            return preciseProgress
        } else if let preserved = preservedSession {
            return preserved.preciseProgress
        }
        return preciseProgress
    }

    // Master Power-Efficient Timer Engine (10Hz / 100ms interval for 80% lower CPU wakeups)
    private var timerSubscription: AnyCancellable?
    private var dateChangeCancellables = Set<AnyCancellable>()
    private var midnightRefreshTimer: Timer?
    public var reportingCalendar: Calendar = .current {
        didSet {
            recalculateFocusMetrics()
            scheduleNextMidnightRefresh()
        }
    }
    public let storage: FocusStorageService
    private var isLoadingPersistedData = false
    private var lastPersistTime: Date = .distantPast

    // Storage Safety & Recovery State
    @Published public private(set) var storageLoadResult: StorageLoadResult = .freshInstall
    @Published public private(set) var isPersistenceBlocked: Bool = false
    @Published public private(set) var didRecoverFromBackup: Bool = false
    @Published public private(set) var storageErrorMessage: String? = nil
    @Published public private(set) var recoveryNoticeMessage: String? = nil
    @Published public var showRecoveryNotice: Bool = false
    @Published public private(set) var isSaveFailed: Bool = false
    @Published public private(set) var saveErrorMessage: String? = nil
    @Published public private(set) var lastSaveError: StorageError? = nil

    public func dismissRecoveryNotice() {
        showRecoveryNotice = false
    }

    public func retrySave() {
        guard !isPersistenceBlocked else { return }
        persistData(force: true)
    }

    // Active Timer Mode: "Pomodoro" or "Custom Timer"
    @Published public var activeMode: String = "Pomodoro" {
        didSet {
            guard !isLoadingPersistedData else { return }
            persistData()
        }
    }
    public var isRunning: Bool { isTimerRunning || isStopwatchRunning }

    public init(storage: FocusStorageService = .shared) {
        self.storage = storage
        loadPersistedData()
        NotificationService.shared.requestAuthorization()
        setupDateChangeMonitoring()
    }

    deinit {
        midnightRefreshTimer?.invalidate()
    }

    public private(set) var hasTerminated: Bool = false

    public func handleAppTermination() {
        guard !hasTerminated else { return }
        hasTerminated = true

        guard !isPersistenceBlocked else { return }

        if isTimerRunning {
            stopTimer()
        } else {
            recordActiveSessionSegment()
        }

        if isStopwatchRunning {
            stopStopwatch()
        }

        persistData(force: true)
    }

    public func resetTerminationStateForTesting() {
        hasTerminated = false
    }

    // MARK: - Persistence Integration (Priority 4A & 4C)
    public func loadPersistedData() {
        isLoadingPersistedData = true
        defer {
            isLoadingPersistedData = false
            recalculateFocusMetrics()
        }

        let result = storage.loadDetailed()
        self.storageLoadResult = result

        switch result {
        case .freshInstall:
            self.isPersistenceBlocked = false
            self.didRecoverFromBackup = false
            self.storageErrorMessage = nil
            self.recoveryNoticeMessage = nil
            self.showRecoveryNotice = false
            self.isSaveFailed = false
            self.saveErrorMessage = nil
            self.lastSaveError = nil
            // First run on a fresh machine (no storage file yet) -> Keep default initial tasks
            return

        case .success(let saved):
            self.isPersistenceBlocked = false
            self.didRecoverFromBackup = false
            self.storageErrorMessage = nil
            self.recoveryNoticeMessage = nil
            self.showRecoveryNotice = false
            self.isSaveFailed = false
            self.saveErrorMessage = nil
            self.lastSaveError = nil
            applyLoadedData(saved)

        case .recovered(let saved, let backupURL, let diagURL):
            self.isPersistenceBlocked = false
            self.didRecoverFromBackup = true
            self.storageErrorMessage = nil
            self.isSaveFailed = false
            self.saveErrorMessage = nil
            self.lastSaveError = nil
            if let diag = diagURL {
                self.recoveryNoticeMessage = "Saved data recovered from backup (\(backupURL.lastPathComponent)). Diagnostic file: \(diag.lastPathComponent)."
            } else {
                self.recoveryNoticeMessage = "Saved data recovered from backup (\(backupURL.lastPathComponent))."
            }
            self.showRecoveryNotice = true
            applyLoadedData(saved)

        case .unrecoverable(let error):
            self.isPersistenceBlocked = true
            self.didRecoverFromBackup = false
            self.storageErrorMessage = "Data Protection Alert: Saved data could not be loaded because the save file is corrupted or unreadable. Automatic saving is blocked to protect your existing file.\n(\(error.description))"
            self.recoveryNoticeMessage = nil
            self.showRecoveryNotice = false
            self.isSaveFailed = false
            self.saveErrorMessage = nil
            self.lastSaveError = nil
            clearDataForStorageError()
        }
    }

    private func clearDataForStorageError() {
        self.tasks = []
        self.sessionRecords = []
        self.legacyLifetimeFocusedSeconds = nil
        self.completedSessions = 0
        self.notes = []
        self.laps = []
        self.lastRecordedLapElapsedSeconds = 0.0
        self.nextLapNumber = 1
        self.preservedSession = nil
        self.pausedSession = nil
        self.stopwatchFractional = nil
        self.stopwatchTime = 0
        self.preciseStopwatchProgress = 0.0
        self.isStopwatchRunning = false
        self.stopwatchStartDate = nil
        self.isTimerRunning = false
        self.targetEndDate = nil
        self.fractionalRemaining = nil
        self.showConflictModal = false
        self.pendingTimerRequest = nil
        self.conflictOrigin = nil
        self.activeSessionTaskId = nil
    }

    private func applyLoadedData(_ saved: FocusAppData) {
        // Existing saved file -> Faithfully restore tasks, even if intentionally empty!
        self.tasks = saved.tasks
        self.sessionRecords = saved.sessionRecords
        self.legacyLifetimeFocusedSeconds = saved.legacyLifetimeFocusedSeconds
        self.completedSessions = saved.completedSessions
        self.notes = saved.notes
        self.dailyGoalHours = saved.dailyGoalHours
        self.totalSessions = max(1, saved.totalSessions)
        self.autoStartNextSession = saved.autoStartNextSession
        self.activePreset = saved.activePreset
        self.laps = saved.laps
        self.preservedSession = saved.preservedSession
        self.pausedSession = saved.pausedSession

        // Restore or derive stopwatch lap checkpoint and sequence number
        if let persistedCheckpoint = saved.lastRecordedLapElapsedSeconds, persistedCheckpoint.isFinite && persistedCheckpoint >= 0 {
            self.lastRecordedLapElapsedSeconds = persistedCheckpoint
        } else if !saved.laps.isEmpty {
            let maxLapTotal = saved.laps.map(\.totalTime).filter { $0.isFinite && $0 >= 0 }.max() ?? 0.0
            self.lastRecordedLapElapsedSeconds = maxLapTotal
        } else {
            self.lastRecordedLapElapsedSeconds = 0.0
        }

        if let persistedNextLap = saved.nextLapNumber, persistedNextLap > 0 {
            self.nextLapNumber = persistedNextLap
        } else if !saved.laps.isEmpty {
            let maxLapNum = saved.laps.map(\.lapNumber).filter { $0 > 0 }.max() ?? 0
            self.nextLapNumber = maxLapNum + 1
        } else {
            self.nextLapNumber = 1
        }

        let restoredElapsed = saved.stopwatchElapsedSeconds
        if restoredElapsed.isFinite && restoredElapsed > 0 {
            self.stopwatchFractional = restoredElapsed
            self.stopwatchTime = max(0, Int(restoredElapsed))
            self.preciseStopwatchProgress = (restoredElapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        } else {
            self.stopwatchFractional = nil
            self.stopwatchTime = 0
            self.preciseStopwatchProgress = 0.0
        }
        self.isStopwatchRunning = false
        self.stopwatchStartDate = nil

        // Task Selection Restoration
        if let savedTaskId = saved.selectedTaskId,
           let foundIndex = self.tasks.firstIndex(where: { $0.id == savedTaskId }),
           !self.tasks[foundIndex].isCompleted {
            self.activeTaskIndex = foundIndex
        } else if let paused = saved.pausedSession,
                  self.tasks.indices.contains(paused.activeTaskIndex),
                  !self.tasks[paused.activeTaskIndex].isCompleted {
            self.activeTaskIndex = paused.activeTaskIndex
        } else if let firstEligible = self.tasks.firstIndex(where: { !$0.isCompleted }) {
            self.activeTaskIndex = firstEligible
        } else {
            self.activeTaskIndex = 0
        }

        let minDuration = TimerViewModel.minSupportedTimerDuration
        let maxDuration = TimerViewModel.maxSupportedTimerDuration

        if let paused = saved.pausedSession {
            // Highest Priority: Existing Paused Timer Session
            self.activePreset = paused.activePreset
            self.activeMode = paused.activeMode
            self.isBreakSession = paused.isBreakSession
            self.totalTime = max(minDuration, min(paused.totalTime, maxDuration))
            self.timeRemaining = max(1, min(paused.timeRemaining, self.totalTime))
            self.currentSession = min(max(1, paused.currentSession), max(1, self.totalSessions))
            self.pausedSession?.activeTaskIndex = self.activeTaskIndex
            self.pausedSession?.totalTime = self.totalTime
            self.pausedSession?.timeRemaining = self.timeRemaining

            if paused.activeMode == "Custom Timer" || paused.activePreset == "Custom" {
                self.customDurationSeconds = self.totalTime
                self.customMinutes = self.totalTime / 60
                self.customSeconds = self.totalTime % 60
                self.pausedSession?.customMinutes = self.customMinutes
                self.pausedSession?.customSeconds = self.customSeconds
            } else if let m = saved.configuredCustomMinutes, let s = saved.configuredCustomSeconds {
                let safeM = max(0, min(m, 360))
                let safeS = max(0, min(s, 59))
                let computed = safeM * 60 + safeS
                let safeCustom = (computed >= minDuration) ? min(computed, maxDuration) : 25 * 60
                self.customDurationSeconds = safeCustom
                self.customMinutes = safeCustom / 60
                self.customSeconds = safeCustom % 60
            } else {
                self.customMinutes = 25
                self.customSeconds = 0
                self.customDurationSeconds = 25 * 60
            }

            if self.totalTime > 0 {
                self.preciseProgress = min(max(Double(self.timeRemaining) / Double(self.totalTime), 0.0), 1.0)
            } else {
                self.preciseProgress = paused.preciseProgress
            }
            self.pausedSession?.preciseProgress = self.preciseProgress
            self.isTimerRunning = false
            self.targetEndDate = nil
            self.fractionalRemaining = nil
            self.activeSessionTaskId = nil
        } else {
            // Top-Level Idle Configuration or Legacy Defaults
            let savedMode = saved.activeMode ?? (saved.activePreset == "Custom" ? "Custom Timer" : "Pomodoro")
            self.activeMode = savedMode

            let isBreak: Bool
            if let savedIsBreak = saved.configuredIsBreakSession {
                isBreak = savedIsBreak
            } else {
                isBreak = (saved.activePreset == "Short Break" || saved.activePreset == "Long Break" || saved.activePreset == "Break")
            }
            self.isBreakSession = isBreak

            let savedTotalSessions = max(1, self.totalSessions)
            if let savedCurrent = saved.configuredCurrentSession {
                self.currentSession = min(max(1, savedCurrent), savedTotalSessions)
            } else {
                self.currentSession = min(max(1, self.currentSession), savedTotalSessions)
            }

            let customM = max(0, min(saved.configuredCustomMinutes ?? 25, 360))
            let customS = max(0, min(saved.configuredCustomSeconds ?? 0, 59))
            let computedCustom = customM * 60 + customS
            let safeCustom = (computedCustom >= minDuration) ? min(computedCustom, maxDuration) : 25 * 60
            self.customDurationSeconds = safeCustom
            self.customMinutes = safeCustom / 60
            self.customSeconds = safeCustom % 60

            let resolvedTotal: Int
            if let savedTotal = saved.configuredTotalTime, savedTotal >= minDuration {
                resolvedTotal = min(savedTotal, maxDuration)
            } else if let savedTotal = saved.configuredTotalTime, savedTotal > 0 {
                resolvedTotal = minDuration
            } else if saved.activePreset == "Short Break" || saved.activePreset == "Break" {
                resolvedTotal = 5 * 60
            } else if saved.activePreset == "Long Break" {
                resolvedTotal = 15 * 60
            } else if saved.activePreset == "Custom" || savedMode == "Custom Timer" {
                resolvedTotal = self.customDurationSeconds
            } else {
                resolvedTotal = 25 * 60
            }

            self.totalTime = max(minDuration, min(resolvedTotal, maxDuration))
            self.timeRemaining = self.totalTime
            self.preciseProgress = 1.0

            if self.activePreset == "Custom" || savedMode == "Custom Timer" {
                self.customDurationSeconds = self.totalTime
                self.customMinutes = self.totalTime / 60
                self.customSeconds = self.totalTime % 60
            }

            self.isTimerRunning = false
            self.targetEndDate = nil
            self.fractionalRemaining = nil
            self.activeSessionTaskId = nil
        }
    }

    public func persistData(force: Bool = false) {
        guard !isLoadingPersistedData else { return }
        guard !isPersistenceBlocked else {
            print("[TimerViewModel] Persistence blocked: Storage error state active.")
            return
        }

        let now = Date()
        // Throttle disk writes to avoid repeated writes during UI animations or high frequency changes
        if !force && now.timeIntervalSince(lastPersistTime) < 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.isPersistenceBlocked else { return }
                self.persistData(force: true)
            }
            return
        }
        lastPersistTime = now

        let currentStopwatchElapsed: TimeInterval
        if isStopwatchRunning, let start = stopwatchStartDate {
            currentStopwatchElapsed = max(0.0, Date().timeIntervalSince(start))
        } else if let frac = stopwatchFractional {
            currentStopwatchElapsed = max(0.0, frac)
        } else {
            currentStopwatchElapsed = max(0.0, TimeInterval(stopwatchTime))
        }

        let currentSelectedTaskId: UUID?
        if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
            currentSelectedTaskId = tasks[activeTaskIndex].id
        } else {
            currentSelectedTaskId = nil
        }

        let payload = FocusAppData(
            tasks: tasks,
            focusedSeconds: todayFocusedSeconds,
            completedSessions: completedSessions,
            notes: notes,
            dailyGoalHours: dailyGoalHours,
            totalSessions: totalSessions,
            autoStartNextSession: autoStartNextSession,
            activePreset: activePreset,
            clockStyle: "Digital",
            sessionRecords: sessionRecords,
            legacyLifetimeFocusedSeconds: legacyLifetimeFocusedSeconds,
            laps: laps,
            preservedSession: preservedSession,
            pausedSession: pausedSession,
            stopwatchElapsedSeconds: currentStopwatchElapsed,
            lastRecordedLapElapsedSeconds: lastRecordedLapElapsedSeconds,
            nextLapNumber: nextLapNumber,
            selectedTaskId: currentSelectedTaskId,
            activeMode: activeMode,
            configuredTotalTime: totalTime,
            configuredCustomMinutes: customMinutes,
            configuredCustomSeconds: customSeconds,
            configuredCurrentSession: currentSession,
            configuredIsBreakSession: isBreakSession
        )
        do {
            try storage.save(payload)
            if self.isSaveFailed {
                self.isSaveFailed = false
                self.saveErrorMessage = nil
                self.lastSaveError = nil
            }
        } catch {
            let isUnrecoverable: Bool
            if storage.isPersistenceBlocked {
                isUnrecoverable = true
            } else if let storageErr = error as? StorageError {
                switch storageErr {
                case .persistenceBlocked, .corruptedPrimary, .corruptedPrimaryAndBackup, .corruptedBackupMissingPrimary, .diagnosticPreservationFailed:
                    isUnrecoverable = true
                case .backupFailed, .writeFailed:
                    isUnrecoverable = false
                }
            } else {
                isUnrecoverable = false
            }

            if isUnrecoverable {
                self.isPersistenceBlocked = true
                let reason = (error as? StorageError)?.description ?? error.localizedDescription
                self.storageErrorMessage = "Data Protection Alert: Saved data could not be persisted because the save file is corrupted or unreadable. Automatic saving is blocked to protect your existing file.\n(\(reason))"
                self.isSaveFailed = false
                self.saveErrorMessage = nil
                self.lastSaveError = nil
                suspendActiveTimersForBlockedStorage()
                print("[TimerViewModel] Storage blocked persistence due to unrecoverable state: \(error)")
                return
            }

            self.isSaveFailed = true
            if let storageErr = error as? StorageError {
                self.lastSaveError = storageErr
                self.saveErrorMessage = "Recent changes may not have been saved. (\(storageErr.description))"
            } else {
                self.lastSaveError = nil
                self.saveErrorMessage = "Recent changes may not have been saved. (\(error.localizedDescription))"
            }
            print("[TimerViewModel] Failed to persist data: \(error)")
        }
    }

    // MARK: - Date-Aware Analytics Recalculation (Priority 2)
    public func recalculateFocusMetrics(calendar: Calendar? = nil, now: Date = Date()) {
        let cal = calendar ?? reportingCalendar
        let activeElapsed: Int
        let activeStart: Date?
        if isTimerRunning, isFocusPreset, let start = sessionSegmentStartDate {
            activeElapsed = max(0, Int(now.timeIntervalSince(start)))
            activeStart = start
        } else {
            activeElapsed = 0
            activeStart = nil
        }

        let startOfToday = cal.startOfDay(for: now)
        guard let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday) else {
            return
        }

        // 1. Today's focus time (calculated strictly from dated records overlapping today + active running segment on today)
        let recordsToday = sessionRecords.reduce(0) { $0 + $1.duration(on: now, calendar: cal) }
        let activeToday: Int
        if activeElapsed > 0, let start = activeStart {
            activeToday = FocusIntervalAllocator.allocatedDuration(
                recordStart: start,
                recordEnd: now,
                durationSeconds: activeElapsed,
                intervalStart: startOfToday,
                intervalEnd: endOfToday
            )
        } else {
            activeToday = 0
        }
        self.todayFocusedSeconds = recordsToday + activeToday

        // 2. Weekly focus time (calculated across the past 7 days: [startOfToday - 6 days, endOfToday])
        let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let recordsWeekly = sessionRecords.reduce(0) { total, record in
            total + record.duration(from: sevenDaysAgo, to: endOfToday)
        }
        let activeWeekly: Int
        if activeElapsed > 0, let start = activeStart {
            activeWeekly = FocusIntervalAllocator.allocatedDuration(
                recordStart: start,
                recordEnd: now,
                durationSeconds: activeElapsed,
                intervalStart: sevenDaysAgo,
                intervalEnd: endOfToday
            )
        } else {
            activeWeekly = 0
        }
        self.weeklyFocusedSeconds = recordsWeekly + activeWeekly

        // 3. Lifetime focus time (all dated records + any legacy unassigned historical total + active running segment)
        let recordsLifetime = sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        let legacy = legacyLifetimeFocusedSeconds ?? 0
        self.lifetimeFocusedSeconds = recordsLifetime + legacy + activeElapsed

        // Maintain focusedSeconds for direct backward-compatible binding
        self.focusedSeconds = self.todayFocusedSeconds
    }

    // MARK: - Date Change & Midnight Lifecycle Monitoring
    public func handleDateOrLifecycleChange(now: Date = Date()) {
        recalculateFocusMetrics(now: now)
        scheduleNextMidnightRefresh()
    }

    private func setupDateChangeMonitoring() {
        dateChangeCancellables.removeAll()

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDateOrLifecycleChange()
                }
            }
            .store(in: &dateChangeCancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDateOrLifecycleChange()
                }
            }
            .store(in: &dateChangeCancellables)

        NotificationCenter.default.publisher(for: Notification.Name("NSSystemClockDidChangeNotification"))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDateOrLifecycleChange()
                }
            }
            .store(in: &dateChangeCancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDateOrLifecycleChange()
                }
            }
            .store(in: &dateChangeCancellables)

        scheduleNextMidnightRefresh()
    }

    private func scheduleNextMidnightRefresh() {
        midnightRefreshTimer?.invalidate()
        midnightRefreshTimer = nil

        let now = Date()
        guard let nextMidnight = reportingCalendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return
        }

        let fireDate = nextMidnight.addingTimeInterval(0.05)
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.recalculateFocusMetrics()
                self.scheduleNextMidnightRefresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightRefreshTimer = timer
    }

    private func creditTaskTime(taskId: UUID?, seconds: Int) {
        guard let taskId = taskId, seconds > 0 else { return }
        if let index = tasks.firstIndex(where: { $0.id == taskId }), !tasks[index].isCompleted {
            tasks[index].timeSpentSeconds += seconds
        }
    }

    private func settleActiveTime(at now: Date, for taskId: UUID?) {
        // 1. Settle running Focus Timer delta
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSince(now)
            if remaining <= 0 {
                preciseProgress = 0.0
                let uncounted = timeRemaining
                timeRemaining = 0
                if isFocusPreset && uncounted > 0 {
                    creditTaskTime(taskId: taskId, seconds: uncounted)
                }
            } else {
                let newRemaining = max(Int(ceil(remaining)), 0)
                if isFocusPreset && newRemaining < timeRemaining {
                    let delta = timeRemaining - newRemaining
                    creditTaskTime(taskId: taskId, seconds: delta)
                }
                timeRemaining = newRemaining
                if totalTime > 0 {
                    preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                }
            }
        }

        // 2. Settle running Stopwatch delta
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = now.timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if newTime > stopwatchTime {
                let delta = newTime - stopwatchTime
                if delta > 0 {
                    creditTaskTime(taskId: taskId, seconds: delta)
                }
                stopwatchTime = newTime
            }
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
    }

    private func finalizeRunningFocusSegment(at now: Date, for taskId: UUID?) {
        guard let start = sessionSegmentStartDate else { return }
        sessionSegmentStartDate = nil
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        guard elapsed > 0 else { return }

        if isFocusPreset {
            let record = FocusSessionRecord(
                startTime: start,
                endTime: now,
                durationSeconds: elapsed,
                mode: activePreset,
                taskId: taskId
            )
            sessionRecords.append(record)
            recalculateFocusMetrics(now: now)
        }
    }

    private func recordActiveSessionSegment() {
        guard sessionSegmentStartDate != nil else { return }
        let now = Date()
        let recordingTaskId = activeSessionTaskId
        activeSessionTaskId = nil
        finalizeRunningFocusSegment(at: now, for: recordingTaskId)
        persistData()
    }

    // MARK: Mode Switching within Timer Sessions
    public func changeMode(to newMode: String, origin: ConflictPresentationOrigin = .mainWindow) {
        guard !isPersistenceBlocked else { return }
        if newMode == "Pomodoro" {
            switchToFocus(minutes: 25, origin: origin)
        } else if newMode == "Custom Timer" {
            requestModeOrPresetChange(name: "Custom", minutes: customMinutes, seconds: customSeconds, mode: "Custom Timer", isBreak: false, origin: origin)
        }
    }

    // MARK: - Conflict-Aware Mode / Preset Requests
    public func requestModeOrPresetChange(
        name: String,
        minutes: Int,
        seconds: Int = 0,
        mode: String = "Pomodoro",
        isBreak: Bool = false,
        origin: ConflictPresentationOrigin = .mainWindow
    ) {
        guard !isPersistenceBlocked else { return }
        let isSame = (activePreset == name && activeMode == mode && totalTime == (minutes * 60 + seconds))
        if isSame { return }

        // If a timer is currently active (running or paused with time elapsed):
        if isTimerActive {
            pendingTimerRequest = (name: name, minutes: minutes, seconds: seconds, mode: mode, isBreak: isBreak)
            conflictOrigin = origin
            showConflictModal = true
        } else {
            // Idle timer -> directly switch without interruption
            conflictOrigin = nil
            applyPresetDirectly(name: name, minutes: minutes, seconds: seconds, mode: mode, isBreak: isBreak)
        }
    }

    public func applyPresetDirectly(name: String, minutes: Int, seconds: Int = 0, mode: String = "Pomodoro", isBreak: Bool = false) {
        guard !isPersistenceBlocked else { return }
        if isTimerRunning { stopTimer() }
        fractionalRemaining = nil
        pausedSession = nil
        activePreset = name
        activeMode = mode
        isBreakSession = isBreak
        let safeM = max(0, min(minutes, 360))
        let safeS = max(0, min(seconds, 59))
        let total = min(max(TimerViewModel.minSupportedTimerDuration, safeM * 60 + safeS), TimerViewModel.maxSupportedTimerDuration)
        customMinutes = total / 60
        customSeconds = total % 60
        customDurationSeconds = total
        totalTime = total
        timeRemaining = total
        preciseProgress = 1.0
        persistData()
    }

    // MARK: - 3-Option Conflict Resolution Actions
    public func continueCurrentTimer() {
        showConflictModal = false
        pendingTimerRequest = nil
        conflictOrigin = nil
    }

    public func pauseAndSwitch() {
        guard !isPersistenceBlocked else { return }
        endAndSwitch()
    }

    public var currentSessionElapsedMinutes: Int {
        let elapsed = max(0, totalTime - timeRemaining)
        return max(1, Int(round(Double(elapsed) / 60.0)))
    }

    public func endAndSwitch(autoStart: Bool = true) {
        guard !isPersistenceBlocked else { return }
        guard let pending = pendingTimerRequest else {
            showConflictModal = false
            conflictOrigin = nil
            return
        }

        // 1. Record completed focus time into session records
        recordActiveSessionSegment()

        // 2. Stop timer and clear preserved session
        stopTimer()
        fractionalRemaining = nil
        preservedSession = nil
        pausedSession = nil

        // 3. Apply new requested preset/mode
        applyPresetDirectly(name: pending.name, minutes: pending.minutes, seconds: pending.seconds, mode: pending.mode, isBreak: pending.isBreak)

        showConflictModal = false
        pendingTimerRequest = nil
        conflictOrigin = nil
        persistData()

        // 4. Start target timer immediately so user directly transitions into active Break/Focus session
        if autoStart {
            startTimer()
        }
    }

    public func restorePreservedSession() {
        guard !isPersistenceBlocked else { return }
        guard let preserved = preservedSession else { return }

        // If current timer is active, swap it into preservedSession so neither is lost!
        let currentWasActive = isTimerRunning || (timeRemaining < totalTime && timeRemaining > 0)
        if isTimerRunning {
            stopTimer()
        }
        let swapSession = currentWasActive ? PreservedTimerSession(
            activePreset: activePreset,
            activeMode: activeMode,
            isBreakSession: isBreakSession,
            totalTime: totalTime,
            timeRemaining: timeRemaining,
            preciseProgress: preciseProgress,
            customMinutes: customMinutes,
            customSeconds: customSeconds,
            currentSession: currentSession,
            activeTaskIndex: activeTaskIndex
        ) : nil

        // Restore preserved session values
        activePreset = preserved.activePreset
        activeMode = preserved.activeMode
        isBreakSession = preserved.isBreakSession
        totalTime = preserved.totalTime
        timeRemaining = preserved.timeRemaining
        preciseProgress = preserved.preciseProgress
        customMinutes = preserved.customMinutes
        customSeconds = preserved.customSeconds
        customDurationSeconds = preserved.totalTime
        currentSession = preserved.currentSession
        activeTaskIndex = preserved.activeTaskIndex

        preservedSession = swapSession
        pausedSession = (timeRemaining < totalTime && timeRemaining > 0) ? PausedTimerSession(
            activePreset: activePreset,
            activeMode: activeMode,
            isBreakSession: isBreakSession,
            totalTime: totalTime,
            timeRemaining: timeRemaining,
            preciseProgress: preciseProgress,
            customMinutes: customMinutes,
            customSeconds: customSeconds,
            currentSession: currentSession,
            activeTaskIndex: activeTaskIndex
        ) : nil
        persistData()
    }

    public func restorePreservedSessionIfNeeded() {
        guard !isPersistenceBlocked else { return }
        if hasPreservedSession && !isTimerRunning {
            restorePreservedSession()
        }
    }

    // MARK: Master Engine
    private func suspendActiveTimersForBlockedStorage() {
        isTimerRunning = false
        isStopwatchRunning = false
        targetEndDate = nil
        fractionalRemaining = nil
        stopwatchStartDate = nil
        sessionSegmentStartDate = nil
        activeSessionTaskId = nil
        timerSubscription?.cancel()
        timerSubscription = nil
    }

    private func updateMasterEngine() {
        if isTimerRunning || isStopwatchRunning {
            if timerSubscription == nil {
                // Relaxed 100ms interval (10Hz) dramatically reduces CPU wakeups while keeping animations completely liquid
                timerSubscription = Timer.publish(every: 0.1, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        self?.tick()
                    }
            }
        } else {
            timerSubscription?.cancel()
            timerSubscription = nil
        }
    }

    internal func tick() {
        guard !isPersistenceBlocked else {
            suspendActiveTimersForBlockedStorage()
            return
        }
        let now = Date()

        // 1. Tick Focus Timer smoothly if running
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSinceNow
            if remaining <= 0 {
                preciseProgress = 0.0
                let uncounted = timeRemaining
                timeRemaining = 0
                if isFocusPreset && uncounted > 0 {
                    creditTaskTime(taskId: activeSessionTaskId, seconds: uncounted)
                }
                recordActiveSessionSegment()
                handleSessionComplete()
            } else {
                if totalTime > 0 {
                    preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                }
                let newTime = Int(ceil(remaining))
                if timeRemaining != newTime {
                    let delta = timeRemaining - newTime
                    timeRemaining = newTime
                    if isFocusPreset && delta > 0 {
                        creditTaskTime(taskId: activeSessionTaskId, seconds: delta)
                    }
                    recalculateFocusMetrics(now: now)
                }
            }
        }

        // 2. Tick Stopwatch smoothly if running
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = now.timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if stopwatchTime != newTime {
                let delta = newTime - stopwatchTime
                stopwatchTime = newTime
                if delta > 0 {
                    let targetTaskId = tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil
                    creditTaskTime(taskId: targetTaskId, seconds: delta)
                }
            }
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
    }

    // MARK: Focus Timer Core Controls
    public func startTimer() {
        guard !isPersistenceBlocked else { return }
        guard !isTimerRunning else { return }
        hasTerminated = false
        // Ensure only one countdown timer runs at a time
        isTimerRunning = true
        let remainingInterval = fractionalRemaining ?? TimeInterval(timeRemaining)
        targetEndDate = Date().addingTimeInterval(remainingInterval)
        preciseProgress = totalTime > 0 ? min(max(remainingInterval / Double(totalTime), 0.0), 1.0) : 1.0
        fractionalRemaining = nil
        sessionSegmentStartDate = Date()
        if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
            activeSessionTaskId = tasks[activeTaskIndex].id
        } else {
            activeSessionTaskId = nil
        }
        pausedSession = nil
        updateMasterEngine()
        persistData()
    }

    public func stopTimer() {
        guard !isPersistenceBlocked else { return }
        var capturedRemaining = timeRemaining
        var capturedProgress = preciseProgress
        let wasRunning = isTimerRunning

        if isTimerRunning, let target = targetEndDate {
            let remaining = max(0, target.timeIntervalSinceNow)
            fractionalRemaining = remaining
            let newRemaining = max(Int(ceil(remaining)), 0)
            if isFocusPreset, newRemaining < timeRemaining {
                let delta = timeRemaining - newRemaining
                creditTaskTime(taskId: activeSessionTaskId, seconds: delta)
            }
            timeRemaining = newRemaining
            capturedRemaining = newRemaining
            if totalTime > 0 {
                preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                capturedProgress = preciseProgress
            }
        }
        recordActiveSessionSegment()
        isTimerRunning = false
        targetEndDate = nil
        updateMasterEngine()
        if capturedRemaining > 0 && (capturedRemaining < totalTime || wasRunning) {
            pausedSession = PausedTimerSession(
                activePreset: activePreset,
                activeMode: activeMode,
                isBreakSession: isBreakSession,
                totalTime: totalTime,
                timeRemaining: capturedRemaining,
                preciseProgress: capturedProgress,
                customMinutes: customMinutes,
                customSeconds: customSeconds,
                currentSession: currentSession,
                activeTaskIndex: activeTaskIndex
            )
        } else {
            pausedSession = nil
        }
        persistData()
    }

    public func toggleTimer() {
        guard !isPersistenceBlocked else { return }
        if isTimerRunning {
            stopTimer()
        } else {
            if timeRemaining == 0 && hasPreservedSession {
                restorePreservedSession()
                startTimer()
            } else {
                startTimer()
            }
        }
    }

    public func resetFocusTimer() {
        guard !isPersistenceBlocked else { return }
        recordActiveSessionSegment()
        stopTimer()
        fractionalRemaining = nil
        timeRemaining = totalTime
        preciseProgress = 1.0
        pausedSession = nil
        persistData()
    }

    public func resetTimer() {
        guard !isPersistenceBlocked else { return }
        resetFocusTimer()
    }

    // MARK: Stopwatch Core Controls (Priority 5)
    public func startStopwatch() {
        guard !isPersistenceBlocked else { return }
        guard !isStopwatchRunning else { return }
        hasTerminated = false
        isStopwatchRunning = true
        let offset = stopwatchFractional ?? TimeInterval(stopwatchTime)
        stopwatchStartDate = Date().addingTimeInterval(-offset)
        preciseStopwatchProgress = (offset.truncatingRemainder(dividingBy: 60.0)) / 60.0
        stopwatchFractional = nil
        updateMasterEngine()
    }

    public func stopStopwatch() {
        guard !isPersistenceBlocked else { return }
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = Date().timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if newTime > stopwatchTime {
                let delta = newTime - stopwatchTime
                if delta > 0 {
                    let targetTaskId = tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil
                    creditTaskTime(taskId: targetTaskId, seconds: delta)
                }
            }
            stopwatchFractional = elapsed
            stopwatchTime = newTime
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
        isStopwatchRunning = false
        stopwatchStartDate = nil
        updateMasterEngine()
        persistData()
    }

    public func toggleStopwatch() {
        guard !isPersistenceBlocked else { return }
        if isStopwatchRunning {
            stopStopwatch()
        } else {
            startStopwatch()
        }
    }

    public func resetStopwatch() {
        guard !isPersistenceBlocked else { return }
        stopStopwatch()
        stopwatchFractional = nil
        stopwatchTime = 0
        laps.removeAll()
        lastRecordedLapElapsedSeconds = 0.0
        nextLapNumber = 1
        preciseStopwatchProgress = 0.0
        persistData(force: true)
    }

    public func recordLap() {
        guard !isPersistenceBlocked else { return }
        let currentTotal: TimeInterval
        if isStopwatchRunning, let start = stopwatchStartDate {
            currentTotal = max(0, Date().timeIntervalSince(start))
        } else {
            currentTotal = max(0, stopwatchFractional ?? TimeInterval(stopwatchTime))
        }

        let lapDuration = max(0, currentTotal - lastRecordedLapElapsedSeconds)
        let lapNum = nextLapNumber

        let newLap = StopwatchLap(
            lapNumber: lapNum,
            lapDuration: lapDuration,
            totalTime: currentTotal,
            timestamp: Date()
        )
        lastRecordedLapElapsedSeconds = currentTotal
        nextLapNumber += 1
        laps.insert(newLap, at: 0)
        persistData()
    }

    public func removeLap(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard laps.indices.contains(index) else { return }
        laps.remove(at: index)
        persistData()
    }

    public var fastestLapIndex: Int? {
        guard laps.count >= 2 else { return nil }
        var bestIndex = 0
        var minDuration = laps[0].lapDuration
        for (i, lap) in laps.enumerated() {
            if lap.lapDuration < minDuration {
                minDuration = lap.lapDuration
                bestIndex = i
            }
        }
        return bestIndex
    }

    public var slowestLapIndex: Int? {
        guard laps.count >= 2 else { return nil }
        var worstIndex = 0
        var maxDuration = laps[0].lapDuration
        for (i, lap) in laps.enumerated() {
            if lap.lapDuration > maxDuration {
                maxDuration = lap.lapDuration
                worstIndex = i
            }
        }
        return worstIndex
    }

    public func requestReset(isStopwatch: Bool = false) {
        guard !isPersistenceBlocked else { return }
        if isStopwatch {
            if stopwatchTime > 0 {
                showResetAlert = true
            } else {
                resetStopwatch()
            }
        } else {
            if timeRemaining < totalTime {
                showResetAlert = true
            } else {
                resetFocusTimer()
            }
        }
    }

    public func recordLapOrNote(isStopwatch: Bool = false) {
        guard !isPersistenceBlocked else { return }
        if isStopwatch {
            recordLap()
        } else {
            noteDraft = ""
            showNoteEditor = true
        }
    }

    public func addTask(title: String = "New Task", expectedMinutes: Int = 25) {
        guard !isPersistenceBlocked else { return }
        let newTask = FocusTask(title: title, estimatedMinutes: expectedMinutes, icon: "checkmark.circle", iconColor: .cyan)
        let shouldBecomeActive = tasks.isEmpty || !tasks.indices.contains(activeTaskIndex) || tasks[activeTaskIndex].isCompleted

        let now = Date()
        if shouldBecomeActive {
            let oldTaskId = (isTimerRunning && isFocusPreset) ? activeSessionTaskId : (isStopwatchRunning && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil)

            if isTimerRunning || isStopwatchRunning {
                settleActiveTime(at: now, for: oldTaskId)
                finalizeRunningFocusSegment(at: now, for: oldTaskId)
            }
        }

        tasks.append(newTask)

        if shouldBecomeActive {
            activeTaskIndex = tasks.count - 1

            if isTimerRunning && isFocusPreset {
                sessionSegmentStartDate = now
                activeSessionTaskId = newTask.id
            } else {
                activeSessionTaskId = newTask.id
            }
        }
        if pausedSession != nil {
            pausedSession?.activeTaskIndex = activeTaskIndex
        }
        persistData()
    }

    public func selectTask(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index), !tasks[index].isCompleted else { return }

        let targetTask = tasks[index]
        let currentActiveId = (isTimerRunning && isFocusPreset) ? activeSessionTaskId : (isStopwatchRunning && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil)

        // Avoid unnecessary focus-record splits when selecting the same task
        if targetTask.id == currentActiveId && index == activeTaskIndex {
            return
        }

        let now = Date()
        let oldTaskId = currentActiveId

        // 1. Settle pending elapsed time under the old task
        settleActiveTime(at: now, for: oldTaskId)

        // 2. Finalize running focus segment under old task
        finalizeRunningFocusSegment(at: now, for: oldTaskId)

        // 3. Switch active task selection
        activeTaskIndex = index

        // 4. If focus timer running, begin next segment under new task
        if isTimerRunning && isFocusPreset {
            sessionSegmentStartDate = now
            activeSessionTaskId = targetTask.id
        } else {
            activeSessionTaskId = targetTask.id
        }

        if pausedSession != nil {
            pausedSession?.activeTaskIndex = index
        }
        persistData()
    }

    public func toggleTaskCompletion(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index) else { return }

        let targetTask = tasks[index]
        let isRunningFocus = isTimerRunning && isFocusPreset

        if !targetTask.isCompleted {
            // Task is currently incomplete -> marking it COMPLETE
            let isCompletingActive = (activeTaskIndex == index)

            if isCompletingActive {
                let now = Date()
                let oldTaskId = targetTask.id

                // 1. Settle pending elapsed time under the old task before marking complete
                settleActiveTime(at: now, for: oldTaskId)

                // 2. Finalize running focus segment under old task
                finalizeRunningFocusSegment(at: now, for: oldTaskId)

                // 3. Mark completed
                tasks[index].isCompleted = true

                // 4. Find next available eligible task
                if let nextIndex = findNextAvailableTaskIndex(startingAt: index + 1, excludingIndex: index) {
                    activeTaskIndex = nextIndex
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                        activeSessionTaskId = tasks[nextIndex].id
                    } else {
                        activeSessionTaskId = tasks[nextIndex].id
                    }
                } else {
                    activeSessionTaskId = nil
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                    }
                }
            } else {
                // Completing an inactive task: active task and running segment are unaffected
                tasks[index].isCompleted = true
            }
        } else {
            // Task is currently completed -> REOPENING (marking INCOMPLETE)
            let shouldBecomeActive = (!tasks.indices.contains(activeTaskIndex) || tasks[activeTaskIndex].isCompleted || activeTaskIndex == index)

            if shouldBecomeActive {
                let now = Date()
                let oldTaskId = isRunningFocus ? activeSessionTaskId : (isStopwatchRunning && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil)

                // 1. Settle pending elapsed time under old identity (nil if unassigned)
                settleActiveTime(at: now, for: oldTaskId)

                // 2. Finalize running focus segment under old identity (taskId == nil if unassigned)
                finalizeRunningFocusSegment(at: now, for: oldTaskId)

                // 3. Mark incomplete and make active
                tasks[index].isCompleted = false
                activeTaskIndex = index

                // 4. Begin next focus segment under the reopened task's UUID at the exact same timestamp
                if isRunningFocus {
                    sessionSegmentStartDate = now
                    activeSessionTaskId = targetTask.id
                } else {
                    activeSessionTaskId = targetTask.id
                }
            } else {
                tasks[index].isCompleted = false
            }
        }

        if pausedSession != nil {
            pausedSession?.activeTaskIndex = activeTaskIndex
        }
        persistData()
    }

    public func removeTask(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index) else { return }

        let deletingTask = tasks[index]
        let isRunningFocus = isTimerRunning && isFocusPreset
        let isDeletingAssigned = (isRunningFocus && activeSessionTaskId == deletingTask.id) ||
            (!isRunningFocus && isStopwatchRunning && activeTaskIndex == index && !deletingTask.isCompleted)

        if isDeletingAssigned {
            let now = Date()
            let oldTaskId = deletingTask.id

            // 1. Settle pending elapsed time under the deleting task
            settleActiveTime(at: now, for: oldTaskId)

            // 2. Finalize running focus segment under deleting task
            finalizeRunningFocusSegment(at: now, for: oldTaskId)

            // 3. Remove the task
            tasks.remove(at: index)

            // 4. Safely choose next active eligible task
            if tasks.isEmpty {
                activeTaskIndex = 0
                activeSessionTaskId = nil
                if isRunningFocus {
                    sessionSegmentStartDate = now
                }
            } else {
                let candidateIndex = min(index, tasks.count - 1)
                if let nextIndex = findNextAvailableTaskIndex(startingAt: candidateIndex) {
                    activeTaskIndex = nextIndex
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                        activeSessionTaskId = tasks[nextIndex].id
                    } else {
                        activeSessionTaskId = tasks[nextIndex].id
                    }
                } else {
                    activeTaskIndex = candidateIndex
                    activeSessionTaskId = nil
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                    }
                }
            }
        } else {
            // Deleting a task that does NOT own the running session:
            // Could be:
            // - Deleting a completed task during an unassigned focus session (activeSessionTaskId == nil)
            // - Deleting an inactive task while another task is running
            // - Deleting any task while timers are idle
            let preservedActiveId = isRunningFocus ? activeSessionTaskId : (tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil)

            tasks.remove(at: index)

            if tasks.isEmpty {
                activeTaskIndex = 0
                activeSessionTaskId = nil
            } else if let preservedId = preservedActiveId, let newIndex = tasks.firstIndex(where: { $0.id == preservedId }) {
                activeTaskIndex = newIndex
            } else {
                if index < activeTaskIndex {
                    activeTaskIndex -= 1
                } else if activeTaskIndex >= tasks.count {
                    activeTaskIndex = tasks.count - 1
                }
            }
        }

        if pausedSession != nil {
            pausedSession?.activeTaskIndex = activeTaskIndex
        }
        persistData()
    }

    public func resetTaskTime(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index) else { return }
        tasks[index].timeSpentSeconds = 0
        persistData()
    }

    public func saveNote() {
        guard !isPersistenceBlocked else { return }
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(trimmed, at: 0)
        noteDraft = ""
        showNoteEditor = false
        persistData()
    }

    public func deleteNote(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
        persistData()
    }

    public func requestPresetChange(name: String, minutes: Int, origin: ConflictPresentationOrigin = .mainWindow) {
        guard !isPersistenceBlocked else { return }
        guard minutes > 0 else { return }
        if name == "Focus" {
            switchToFocus(minutes: minutes, origin: origin)
            return
        }
        if name == "Short Break" || name == "Break" {
            switchToBreak(minutes: minutes, origin: origin)
            return
        }
        if name == "Long Break" {
            switchToBreak(minutes: minutes, origin: origin)
            return
        }
        let isBreak = (name == "Short Break" || name == "Long Break" || name == "Break")
        requestModeOrPresetChange(name: name, minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: isBreak, origin: origin)
    }

    public func setCustomDuration(minutes: Int, seconds: Int, origin: ConflictPresentationOrigin = .mainWindow) {
        guard !isPersistenceBlocked else { return }
        let safeM = max(0, min(minutes, 360))
        let safeS = max(0, min(seconds, 59))
        requestModeOrPresetChange(name: "Custom", minutes: safeM, seconds: safeS, mode: "Custom Timer", isBreak: false, origin: origin)
    }

    public func switchToBreak(minutes: Int = 5, origin: ConflictPresentationOrigin = .mainWindow) {
        guard !isPersistenceBlocked else { return }
        let breakName = (minutes >= 15) ? "Long Break" : "Short Break"
        // If we are already in this exact Break preset with the exact same duration, do nothing
        if isBreakPreset && activeMode == "Pomodoro" && activePreset == breakName && totalTime == minutes * 60 { return }

        // If a timer is currently active (running or paused with time elapsed):
        // Remind user that switching will end their active focus session and request confirmation!
        if isTimerActive {
            pendingTimerRequest = (name: breakName, minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: true)
            conflictOrigin = origin
            showConflictModal = true
            return
        }

        // Timer is idle: switch immediately and cleanly
        conflictOrigin = nil
        applyPresetDirectly(name: breakName, minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: true)
    }

    public func switchToFocus(minutes: Int = 25, origin: ConflictPresentationOrigin = .mainWindow) {
        guard !isPersistenceBlocked else { return }
        // If we are already in Focus with this duration, do nothing
        if isFocusPreset && activeMode == "Pomodoro" && (activePreset == "Focus" && totalTime == minutes * 60) { return }

        // If a timer is currently active (e.g. running break timer):
        // Remind user that switching will end their active session and request confirmation!
        if isTimerActive {
            pendingTimerRequest = (name: "Focus", minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: false)
            conflictOrigin = origin
            showConflictModal = true
            return
        }

        // Timer is idle: switch immediately and cleanly
        conflictOrigin = nil
        applyPresetDirectly(name: "Focus", minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: false)
    }

    public func applyPendingPreset() {
        guard !isPersistenceBlocked else { return }
        guard let pending = pendingPreset else { return }
        requestPresetChange(name: pending.name, minutes: pending.minutes)
        pendingPreset = nil
    }

    public func cancelPendingPreset() {
        pendingPreset = nil
    }

    public func applyPreset(name: String, minutes: Int) {
        guard !isPersistenceBlocked else { return }
        let isBreak = (name == "Short Break" || name == "Long Break" || name == "Break")
        applyPresetDirectly(name: name, minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: isBreak)
    }

    public func skipSession() {
        guard !isPersistenceBlocked else { return }
        recordActiveSessionSegment()
        stopTimer()
        fractionalRemaining = nil
        pausedSession = nil
        if isBreakPreset {
            if activePreset == "Long Break" {
                currentSession = 1
            }

            if let preserved = preservedSession, preserved.isBreakSession {
                preservedSession = nil
            }

            applyPresetDirectly(name: "Focus", minutes: 25, mode: "Pomodoro", isBreak: false)
            persistData()
            if autoStartNextSession {
                startTimer()
            }
        } else {
            let isFinalSession = currentSession >= totalSessions
            currentSession = isFinalSession ? (autoStartNextSession ? currentSession : 1) : currentSession + 1
            let nextBreakPreset = isFinalSession ? "Long Break" : "Short Break"
            let nextBreakMinutes = isFinalSession ? 15 : 5

            if let preserved = preservedSession, !preserved.isBreakSession {
                preservedSession = nil
            }

            applyPresetDirectly(name: nextBreakPreset, minutes: nextBreakMinutes, mode: "Pomodoro", isBreak: true)
            persistData()
            if autoStartNextSession {
                startTimer()
            }
        }
    }

    internal func handleSessionComplete() {
        stopTimer()
        fractionalRemaining = nil
        pausedSession = nil
        showConflictModal = false
        pendingTimerRequest = nil
        conflictOrigin = nil

        // Native macOS User Notification
        NotificationService.shared.sendSessionCompleteNotification(presetName: activePreset, isBreak: isBreakPreset)

        // Completion chime (native macOS alert sound)
        if let chime = NSSound(named: NSSound.Name("Glass")) {
            chime.play()
        } else {
            NSSound.beep()
        }

        if isFocusPreset {
            completedSessions += 1
            // A task often requires multiple focus sessions.
            // Finishing a session must NOT mark the task completed or auto-advance tasks.
            // Tasks remain incomplete until the user explicitly toggles completion.

            let isFinalSession = currentSession >= totalSessions
            currentSession = isFinalSession ? (autoStartNextSession ? currentSession : 1) : currentSession + 1
            let nextBreakPreset = isFinalSession ? "Long Break" : "Short Break"
            let nextBreakMinutes = isFinalSession ? 15 : 5

            if let preserved = preservedSession, !preserved.isBreakSession {
                preservedSession = nil
            }

            applyPresetDirectly(name: nextBreakPreset, minutes: nextBreakMinutes, mode: "Pomodoro", isBreak: true)
            persistData()
            if autoStartNextSession {
                startTimer()
            }
            return
        } else {
            if activePreset == "Long Break" {
                currentSession = 1
            }

            if let preserved = preservedSession, preserved.isBreakSession {
                preservedSession = nil
            }

            applyPresetDirectly(name: "Focus", minutes: 25, mode: "Pomodoro", isBreak: false)
            persistData()
            if autoStartNextSession {
                startTimer()
            }
        }
    }

    private func findNextAvailableTaskIndex(startingAt index: Int, excludingIndex: Int? = nil) -> Int? {
        guard !tasks.isEmpty else { return nil }
        let count = tasks.count
        for offset in 0..<count {
            let candidate = (index + offset) % count
            if candidate == excludingIndex { continue }
            if !tasks[candidate].isCompleted {
                return candidate
            }
        }
        return nil
    }

    private func advanceToNextAvailableTask(after currentIndex: Int) {
        guard !tasks.isEmpty else { return }
        if let nextIndex = findNextAvailableTaskIndex(startingAt: currentIndex + 1) {
            activeTaskIndex = nextIndex
        }
    }

    // MARK: Computed Helpers for Display
    public var timeString: String {
        let m = timeRemaining / 60
        let s = timeRemaining % 60
        return String(format: "%02d:%02d", m, s)
    }

    public var timerTimeString: String {
        timeString
    }

    public var stopwatchTimeString: String {
        let total = max(0, stopwatchTime)
        let hours = total / 3600
        let minutes = (total / 60) % 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var formattedCustomDuration: String {
        let m = totalTime / 60
        let s = totalTime % 60
        if s > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(m)m"
        }
    }

    public var fillAmount: Double {
        preciseProgress
    }

    public func adjustCustomDuration(by minutes: Int) {
        guard !isPersistenceBlocked else { return }
        guard !isTimerRunning else { return }
        let currentTotal = totalTime
        let newTotal = min(max(currentTotal + minutes * 60, 5), 360 * 60)
        customDurationSeconds = newTotal
        customMinutes = newTotal / 60
        customSeconds = newTotal % 60
        activeMode = "Custom Timer"
        activePreset = "Custom"
        totalTime = newTotal
        timeRemaining = newTotal
        preciseProgress = 1.0
        pausedSession = nil
        persistData()
    }
}
