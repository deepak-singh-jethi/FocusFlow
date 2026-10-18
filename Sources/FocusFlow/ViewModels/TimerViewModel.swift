import SwiftUI
import Combine
import AppKit

// MARK: - Timer & App State ViewModel (Persistent, Date-Aware & Power-Efficient)
@MainActor
public class TimerViewModel: ObservableObject {
    // MARK: - Supported Timer Duration Bounds
    public static let minSupportedTimerDuration: Int = 5
    public static let maxSupportedTimerDuration: Int = 360 * 60 + 59 // 21,659 seconds (360m 59s)

    /// Flag indicating whether timeRemaining is being synchronized internally by countdown tick or wake reconciliation.
    /// When true, timeRemaining.didSet does not shift or overwrite targetEndDate.
    private var isInternalTimerSync: Bool = false

    /// Synchronizes remaining countdown time from active countdown/deadline without shifting the deadline.
    internal func synchronizeCountdownRemaining(to newRemaining: Int) {
        isInternalTimerSync = true
        timeRemaining = newRemaining
        isInternalTimerSync = false
    }

    @Published public var timeRemaining: Int = 25 * 60 {
        didSet {
            guard !isInternalTimerSync else { return }
            if isTimerRunning, let target = targetEndDate {
                let now = currentDateProvider()
                let currentSecs = Int(ceil(target.timeIntervalSince(now)))
                if abs(currentSecs - timeRemaining) > 1 {
                    targetEndDate = now.addingTimeInterval(TimeInterval(timeRemaining))
                    fractionalRemaining = nil
                    if totalTime > 0 {
                        preciseProgress = min(max(Double(timeRemaining) / Double(totalTime), 0.0), 1.0)
                    }
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
    internal var segmentCreditedSeconds: Int = 0

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
    private var midnightRefreshCancellable: AnyCancellable?
    public private(set) var scheduledMidnightFireDate: Date?

    /// Injectable date/clock provider for deterministic testing (defaults to real-time `Date()`)
    public var currentDateProvider: () -> Date = { Date() }

    /// Injectable system calendar provider (defaults to `Calendar.autoupdatingCurrent`)
    public var systemCalendarProvider: () -> Calendar = { .autoupdatingCurrent }

    /// Counter for times `handleSystemTimeZoneChange` has executed
    public private(set) var timeZoneChangeHandledCount: Int = 0

    /// Counter for times the midnight timer callback has executed
    public private(set) var midnightRefreshCallbackCount: Int = 0

    /// Optional custom scheduler seam for midnight refresh timers. If nil, standard RunLoop.main timer is used.
    public var midnightTimerScheduler: ((Date, @escaping @MainActor () -> Void) -> AnyCancellable?)? = nil

    private var customReportingCalendar: Calendar?
    public var reportingCalendar: Calendar {
        get {
            customReportingCalendar ?? systemCalendarProvider()
        }
        set {
            customReportingCalendar = newValue
            handleCalendarOrTimeZoneChange()
        }
    }

    public var hasCustomReportingCalendar: Bool {
        customReportingCalendar != nil
    }

    public func resetReportingCalendarToSystem() {
        customReportingCalendar = nil
        handleCalendarOrTimeZoneChange()
    }

    public var activeDateChangeObserverCount: Int {
        dateChangeCancellables.count
    }
    public let storage: FocusStorageService
    private var isLoadingPersistedData = false
    private var lastPersistTime: Date = .distantPast

    // MARK: - Persistence Write Coalescing (Task 6)
    public static let defaultThrottleInterval: TimeInterval = 1.0
    public var throttleInterval: TimeInterval = 1.0

    /// Indicates whether a coalesced trailing save is currently scheduled and pending.
    public private(set) var hasPendingSave: Bool = false

    /// Total count of scheduled pending saves (for metrics and test verification).
    public private(set) var pendingSaveScheduledCount: Int = 0

    /// Total count of executed pending saves.
    public private(set) var pendingSaveExecutedCount: Int = 0

    /// Total count of cancelled pending saves.
    public private(set) var pendingSaveCancelledCount: Int = 0

    /// Monotonically increasing generation identity for pending coalesced save callbacks.
    public private(set) var activePendingSaveGeneration: UInt64 = 0

    /// Alias for active generation identity.
    public var pendingSaveGeneration: UInt64 {
        activePendingSaveGeneration
    }

    /// Injectable scheduler seam for test determinism.
    /// Signature: (delay: TimeInterval, action: @escaping @MainActor () -> Void) -> AnyCancellable?
    /// If nil, production `DispatchQueue.main.asyncAfter` with `DispatchWorkItem` is used.
    public var saveScheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable?)? = nil

    private var pendingSaveWorkItem: DispatchWorkItem?
    private var pendingSaveCancellable: AnyCancellable?

    public func cancelPendingSave() {
        guard hasPendingSave || pendingSaveWorkItem != nil || pendingSaveCancellable != nil else { return }
        activePendingSaveGeneration &+= 1
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        pendingSaveCancellable?.cancel()
        pendingSaveCancellable = nil
        if hasPendingSave {
            hasPendingSave = false
            pendingSaveCancelledCount += 1
        }
    }

    private func schedulePendingSave(delay: TimeInterval) {
        hasPendingSave = true
        pendingSaveScheduledCount += 1
        activePendingSaveGeneration &+= 1
        let generation = activePendingSaveGeneration

        if let customScheduler = saveScheduler {
            pendingSaveCancellable = customScheduler(delay) { [weak self] in
                guard let self = self else { return }
                self.executePendingSave(generation: generation)
            }
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.executePendingSave(generation: generation)
        }
        self.pendingSaveWorkItem = workItem
        self.pendingSaveCancellable = AnyCancellable { [weak workItem] in
            workItem?.cancel()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func executePendingSave(generation: UInt64) {
        guard hasPendingSave, generation == activePendingSaveGeneration else { return }
        if let workItem = pendingSaveWorkItem, workItem.isCancelled {
            cancelPendingSave()
            return
        }
        guard !isPersistenceBlocked else {
            cancelPendingSave()
            return
        }
        guard !hasTerminated else {
            cancelPendingSave()
            return
        }

        pendingSaveWorkItem = nil
        pendingSaveCancellable = nil
        hasPendingSave = false
        activePendingSaveGeneration &+= 1
        pendingSaveExecutedCount += 1

        performSave(now: currentDateProvider())
    }

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

    // Task 8: In-Flight Crash / Force-Quit Recovery State
    public private(set) var activeTimerSessionId: UUID = UUID()
    public var checkpointInterval: TimeInterval = 15.0
    public var checkpointRetryInterval: TimeInterval = 5.0
    public private(set) var lastSuccessfulCheckpointTime: Date = .distantPast
    public private(set) var lastAttemptedCheckpointTime: Date = .distantPast
    public var lastCheckpointTime: Date {
        lastSuccessfulCheckpointTime
    }
    @Published public private(set) var didRecoverInterruptedSession: Bool = false
    private var isPerformingSave: Bool = false
    private var pendingRecoveryNoticeMessage: String? = nil

    public func checkpointActiveTimers(now: Date? = nil) {
        guard !isLoadingPersistedData, !isPersistenceBlocked, !hasTerminated else { return }
        let effectiveNow = now ?? currentDateProvider()
        if reconcileIfExpired(at: effectiveNow) {
            return
        }
        performSave(now: effectiveNow)
    }

    public func dismissRecoveryNotice() {
        showRecoveryNotice = false
    }

    public func retrySave() {
        guard !isPersistenceBlocked else { return }
        persistData(force: true)
    }

    // MARK: - Crash Recovery Validation (Finding 2)
    public static func validateRecoveryState(_ recovery: ActiveSessionRecoveryState, in saved: FocusAppData) -> Bool {
        // 1. Supported version
        guard recovery.version == 1 else {
            print("[TimerViewModel] Recovery validation failed: unsupported version \(recovery.version)")
            return false
        }

        // 2. Activity state combinations
        guard recovery.isTimerRunning || recovery.isStopwatchRunning else {
            print("[TimerViewModel] Recovery validation failed: neither timer nor stopwatch is running")
            return false
        }

        // 3. Floating-point sanity
        guard recovery.preciseProgress.isFinite,
              recovery.preciseProgress >= 0.0,
              recovery.preciseProgress <= 1.0 else {
            print("[TimerViewModel] Recovery validation failed: invalid preciseProgress")
            return false
        }

        if let frac = recovery.fractionalRemaining {
            guard frac.isFinite, frac >= 0.0 else {
                print("[TimerViewModel] Recovery validation failed: invalid fractionalRemaining")
                return false
            }
        }

        // 4. Timer validation (if isTimerRunning)
        if recovery.isTimerRunning {
            let minDuration = TimerViewModel.minSupportedTimerDuration
            let maxDuration = TimerViewModel.maxSupportedTimerDuration

            guard recovery.totalTime >= minDuration, recovery.totalTime <= maxDuration else {
                print("[TimerViewModel] Recovery validation failed: totalTime \(recovery.totalTime) out of bounds")
                return false
            }

            guard recovery.timeRemaining >= 0, recovery.timeRemaining <= recovery.totalTime else {
                print("[TimerViewModel] Recovery validation failed: timeRemaining \(recovery.timeRemaining) out of bounds")
                return false
            }

            guard recovery.segmentCreditedSeconds >= 0, recovery.segmentCreditedSeconds <= recovery.totalTime else {
                print("[TimerViewModel] Recovery validation failed: segmentCreditedSeconds \(recovery.segmentCreditedSeconds) invalid")
                return false
            }

            let elapsedNominal = recovery.totalTime - recovery.timeRemaining
            guard recovery.segmentCreditedSeconds <= elapsedNominal + 1 else {
                print("[TimerViewModel] Recovery validation failed: segmentCreditedSeconds \(recovery.segmentCreditedSeconds) exceeds elapsed \(elapsedNominal)")
                return false
            }

            let cp = recovery.checkpointTimestamp
            if let start = recovery.sessionSegmentStartDate {
                guard start <= cp else {
                    print("[TimerViewModel] Recovery validation failed: sessionSegmentStartDate is after checkpointTimestamp")
                    return false
                }
            }

            if let target = recovery.targetEndDate {
                if let start = recovery.sessionSegmentStartDate {
                    guard start <= target else {
                        print("[TimerViewModel] Recovery validation failed: sessionSegmentStartDate is after targetEndDate")
                        return false
                    }
                }
            }
        }

        // 5. Stopwatch validation (if isStopwatchRunning)
        if recovery.isStopwatchRunning {
            guard recovery.stopwatchElapsedSeconds.isFinite,
                  recovery.stopwatchElapsedSeconds >= 0.0,
                  recovery.stopwatchElapsedSeconds <= 86400 * 365 else {
                print("[TimerViewModel] Recovery validation failed: invalid stopwatchElapsedSeconds")
                return false
            }
        }

        return true
    }

    // Active Timer Mode: "Pomodoro" or "Custom Timer"
    @Published public var activeMode: String = "Pomodoro" {
        didSet {
            guard !isLoadingPersistedData else { return }
            persistData()
        }
    }
    public var isRunning: Bool { isTimerRunning || isStopwatchRunning }

    public init(storage: FocusStorageService = .shared, currentDateProvider: (() -> Date)? = nil) {
        if let clock = currentDateProvider {
            self.currentDateProvider = clock
        }
        self.storage = storage
        loadPersistedData()
        NotificationService.shared.requestAuthorization()
        setupDateChangeMonitoring()
    }

    deinit {
        midnightRefreshTimer?.invalidate()
        midnightRefreshCancellable?.cancel()
        pendingSaveWorkItem?.cancel()
        pendingSaveCancellable?.cancel()
    }

    public private(set) var hasTerminated: Bool = false

    public func handleAppTermination() {
        guard !hasTerminated else { return }
        hasTerminated = true

        cancelPendingSave()
        guard !isPersistenceBlocked else { return }

        let now = currentDateProvider()
        reconcileIfExpired(at: now)

        if isTimerRunning {
            stopTimer(at: now)
        } else {
            recordActiveSessionSegment(at: now)
        }

        if isStopwatchRunning {
            stopStopwatch()
        }

        persistData(force: true)
    }

    public func resetTerminationStateForTesting() {
        hasTerminated = false
        cancelPendingSave()
    }

    // MARK: - Persistence Integration (Priority 4A & 4C)
    public func loadPersistedData() {
        cancelPendingSave()
        didRecoverInterruptedSession = false
        isLoadingPersistedData = true
        defer {
            isLoadingPersistedData = false
            recalculateFocusMetrics()
            if didRecoverInterruptedSession && !isPersistenceBlocked {
                persistData(force: true)
            }
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
        cancelPendingSave()
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
        self.segmentCreditedSeconds = 0
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
        if let recovery = saved.activeSessionRecovery,
           (recovery.isTimerRunning || recovery.isStopwatchRunning),
           Self.validateRecoveryState(recovery, in: saved) {
            let targetTaskId = recovery.isTimerRunning ? recovery.activeSessionTaskId : recovery.stopwatchTaskId
            if let targetTaskId = targetTaskId,
               let foundIndex = self.tasks.firstIndex(where: { $0.id == targetTaskId }),
               !self.tasks[foundIndex].isCompleted {
                self.activeTaskIndex = foundIndex
            } else if let savedTaskId = saved.selectedTaskId,
                      let foundIndex = self.tasks.firstIndex(where: { $0.id == savedTaskId }),
                      !self.tasks[foundIndex].isCompleted {
                self.activeTaskIndex = foundIndex
            } else if let firstEligible = self.tasks.firstIndex(where: { !$0.isCompleted }) {
                self.activeTaskIndex = firstEligible
            } else {
                self.activeTaskIndex = 0
            }
        } else if let savedTaskId = saved.selectedTaskId,
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

        if let recovery = saved.activeSessionRecovery, (recovery.isTimerRunning || recovery.isStopwatchRunning) {
            if Self.validateRecoveryState(recovery, in: saved) {
                restoreCrashRecoverySession(recovery, saved: saved)
            } else {
                print("[TimerViewModel] Quarantined invalid activeSessionRecovery metadata.")
                self.didRecoverInterruptedSession = false
                self.showRecoveryNotice = false
                self.recoveryNoticeMessage = nil
                if let paused = saved.pausedSession {
                    restorePausedTimerSession(paused, saved: saved)
                } else {
                    restoreIdleTimerConfiguration(saved: saved)
                }
            }
        } else if let paused = saved.pausedSession {
            restorePausedTimerSession(paused, saved: saved)
        } else {
            restoreIdleTimerConfiguration(saved: saved)
        }
    }

    private func restoreCrashRecoverySession(_ recovery: ActiveSessionRecoveryState, saved: FocusAppData) {
        self.didRecoverInterruptedSession = true
        self.pendingRecoveryNoticeMessage = "Interrupted session restored to paused state from last checkpoint."
        self.showRecoveryNotice = false

        let minDuration = TimerViewModel.minSupportedTimerDuration
        let maxDuration = TimerViewModel.maxSupportedTimerDuration

        if recovery.isTimerRunning {
            self.activePreset = recovery.activePreset
            self.activeMode = recovery.activeMode
            self.isBreakSession = recovery.isBreakSession
            self.totalTime = max(minDuration, min(recovery.totalTime, maxDuration))
            self.timeRemaining = max(1, min(recovery.timeRemaining, self.totalTime))
            self.currentSession = min(max(1, recovery.currentSession), max(1, self.totalSessions))
            self.customMinutes = max(0, min(recovery.customMinutes, 360))
            self.customSeconds = max(0, min(recovery.customSeconds, 59))
            self.customDurationSeconds = max(minDuration, min(self.customMinutes * 60 + self.customSeconds, maxDuration))

            if self.totalTime > 0 {
                self.preciseProgress = min(max(Double(self.timeRemaining) / Double(self.totalTime), 0.0), 1.0)
            } else {
                self.preciseProgress = recovery.preciseProgress
            }

            self.isTimerRunning = false
            self.targetEndDate = nil
            self.fractionalRemaining = recovery.fractionalRemaining
            self.sessionSegmentStartDate = nil
            self.segmentCreditedSeconds = 0
            self.activeSessionTaskId = nil
            self.activeTimerSessionId = UUID()

            // Finalize interrupted focus segment if credited seconds > 0
            if !recovery.isBreakSession && recovery.segmentCreditedSeconds > 0 {
                let credited = recovery.segmentCreditedSeconds
                let endTime = recovery.checkpointTimestamp
                let startTime = recovery.sessionSegmentStartDate ?? endTime.addingTimeInterval(-Double(credited))
                let boundedEnd = max(startTime, endTime)

                let recordTaskId: UUID?
                if let taskId = recovery.activeSessionTaskId,
                   let index = self.tasks.firstIndex(where: { $0.id == taskId }),
                   !self.tasks[index].isCompleted {
                    recordTaskId = taskId
                } else {
                    recordTaskId = nil
                }

                let isAlreadyRecorded = self.sessionRecords.contains {
                    $0.id == recovery.timerSessionId ||
                    ($0.startTime == startTime && $0.durationSeconds == credited && $0.taskId == recordTaskId)
                }
                if !isAlreadyRecorded {
                    let record = FocusSessionRecord(
                        id: recovery.timerSessionId,
                        startTime: startTime,
                        endTime: boundedEnd,
                        durationSeconds: credited,
                        mode: recovery.activePreset,
                        taskId: recordTaskId
                    )
                    self.sessionRecords.append(record)
                    recalculateFocusMetrics(now: boundedEnd)
                }
            }

            self.pausedSession = PausedTimerSession(
                activePreset: self.activePreset,
                activeMode: self.activeMode,
                isBreakSession: self.isBreakSession,
                totalTime: self.totalTime,
                timeRemaining: self.timeRemaining,
                preciseProgress: self.preciseProgress,
                customMinutes: self.customMinutes,
                customSeconds: self.customSeconds,
                currentSession: self.currentSession,
                activeTaskIndex: self.activeTaskIndex
            )
        } else if let paused = saved.pausedSession {
            restorePausedTimerSession(paused, saved: saved)
        } else {
            restoreIdleTimerConfiguration(saved: saved)
        }

        if recovery.isStopwatchRunning {
            self.isStopwatchRunning = false
            self.stopwatchStartDate = nil
            let restoredElapsed = max(0.0, recovery.stopwatchElapsedSeconds)
            self.stopwatchFractional = restoredElapsed
            self.stopwatchTime = max(0, Int(restoredElapsed))
            self.preciseStopwatchProgress = (restoredElapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
    }

    private func restorePausedTimerSession(_ paused: PausedTimerSession, saved: FocusAppData) {
        let minDuration = TimerViewModel.minSupportedTimerDuration
        let maxDuration = TimerViewModel.maxSupportedTimerDuration

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
    }

    private func restoreIdleTimerConfiguration(saved: FocusAppData) {
        let minDuration = TimerViewModel.minSupportedTimerDuration
        let maxDuration = TimerViewModel.maxSupportedTimerDuration

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

    public func persistData(force: Bool = false) {
        guard !isLoadingPersistedData else { return }
        guard !isPersistenceBlocked else {
            cancelPendingSave()
            print("[TimerViewModel] Persistence blocked: Storage error state active.")
            return
        }

        let now = currentDateProvider()

        if force {
            cancelPendingSave()
            performSave(now: now)
            return
        }

        let elapsed = now.timeIntervalSince(lastPersistTime)
        if elapsed >= throttleInterval || elapsed < 0 {
            cancelPendingSave()
            performSave(now: now)
            return
        }

        if hasPendingSave {
            return
        }

        let delay = max(0.01, throttleInterval - elapsed)
        schedulePendingSave(delay: delay)
    }

    private func settleActiveTimeForSnapshot(at now: Date) {
        var didMutate = false

        // 1. Settle running Focus countdown timer
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSince(now)
            if remaining <= 0 {
                if timeRemaining > 0 {
                    let uncounted = timeRemaining
                    synchronizeCountdownRemaining(to: 0)
                    preciseProgress = 0.0
                    if isFocusPreset && uncounted > 0 {
                        creditTaskTime(taskId: activeSessionTaskId, seconds: uncounted)
                        segmentCreditedSeconds += uncounted
                    }
                    didMutate = true
                }
            } else {
                let newRemaining = max(Int(ceil(remaining)), 0)
                if newRemaining < timeRemaining {
                    let delta = timeRemaining - newRemaining
                    synchronizeCountdownRemaining(to: newRemaining)
                    if isFocusPreset && delta > 0 {
                        creditTaskTime(taskId: activeSessionTaskId, seconds: delta)
                        segmentCreditedSeconds += delta
                    }
                    didMutate = true
                }
                if totalTime > 0 {
                    preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                }
            }
        }

        // 2. Settle running Stopwatch
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = max(0.0, now.timeIntervalSince(start))
            let newTime = max(Int(elapsed), 0)
            if newTime > stopwatchTime {
                let delta = newTime - stopwatchTime
                let targetTaskId = tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil
                creditTaskTime(taskId: targetTaskId, seconds: delta)
                stopwatchTime = newTime
                didMutate = true
            }
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }

        if didMutate {
            recalculateFocusMetrics(now: now)
        }
    }

    private func performSave(now: Date) {
        guard !isLoadingPersistedData else { return }
        guard !isPerformingSave else { return }
        guard !isPersistenceBlocked else {
            cancelPendingSave()
            print("[TimerViewModel] Persistence blocked: Storage error state active.")
            return
        }

        isPerformingSave = true
        defer { isPerformingSave = false }

        lastAttemptedCheckpointTime = now
        settleActiveTimeForSnapshot(at: now)

        lastPersistTime = now

        let currentStopwatchElapsed: TimeInterval
        if isStopwatchRunning, let start = stopwatchStartDate {
            currentStopwatchElapsed = max(0.0, now.timeIntervalSince(start))
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

        let recoveryState: ActiveSessionRecoveryState?
        if (isTimerRunning || isStopwatchRunning) && !hasTerminated {
            let activeSwTaskId: UUID?
            if isStopwatchRunning && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                activeSwTaskId = tasks[activeTaskIndex].id
            } else {
                activeSwTaskId = nil
            }

            recoveryState = ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: isTimerRunning,
                timerSessionId: activeTimerSessionId,
                activePreset: activePreset,
                activeMode: activeMode,
                isBreakSession: isBreakPreset,
                totalTime: totalTime,
                timeRemaining: timeRemaining,
                fractionalRemaining: fractionalRemaining,
                preciseProgress: preciseProgress,
                targetEndDate: targetEndDate,
                sessionSegmentStartDate: sessionSegmentStartDate,
                segmentCreditedSeconds: segmentCreditedSeconds,
                activeSessionTaskId: activeSessionTaskId,
                currentSession: currentSession,
                customMinutes: customMinutes,
                customSeconds: customSeconds,
                isStopwatchRunning: isStopwatchRunning,
                stopwatchElapsedSeconds: currentStopwatchElapsed,
                stopwatchTaskId: activeSwTaskId,
                checkpointTimestamp: max(now, sessionSegmentStartDate?.addingTimeInterval(Double(segmentCreditedSeconds)) ?? now)
            )
        } else {
            recoveryState = nil
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
            configuredIsBreakSession: isBreakSession,
            activeSessionRecovery: recoveryState
        )
        do {
            try storage.save(payload)
            if self.isSaveFailed {
                self.isSaveFailed = false
                self.saveErrorMessage = nil
                self.lastSaveError = nil
            }
            if recoveryState != nil {
                self.lastSuccessfulCheckpointTime = now
            }
            if self.didRecoverInterruptedSession {
                self.showRecoveryNotice = true
                self.recoveryNoticeMessage = self.pendingRecoveryNoticeMessage ?? "Interrupted session restored to paused state from last checkpoint."
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
                cancelPendingSave()
                let reason = (error as? StorageError)?.description ?? error.localizedDescription
                self.storageErrorMessage = "Data Protection Alert: Saved data could not be persisted because the save file is corrupted or unreadable. Automatic saving is blocked to protect your existing file.\n(\(reason))"
                self.isSaveFailed = false
                self.saveErrorMessage = nil
                self.lastSaveError = nil
                suspendActiveTimersForBlockedStorage()
                if self.didRecoverInterruptedSession {
                    self.showRecoveryNotice = false
                }
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
            if self.didRecoverInterruptedSession {
                self.showRecoveryNotice = false
            }
            print("[TimerViewModel] Failed to persist data: \(error)")
        }
    }

    // MARK: - Date-Aware Analytics Recalculation (Priority 2)
    public func recalculateFocusMetrics(calendar: Calendar? = nil, now: Date? = nil) {
        let cal = calendar ?? reportingCalendar
        let effectiveNow = now ?? currentDateProvider()

        let activeElapsed: Int
        let activeStart: Date?
        let activeEnd: Date
        if isTimerRunning, isFocusPreset, let start = sessionSegmentStartDate {
            let effectiveEnd: Date
            if let target = targetEndDate, target >= start, effectiveNow > target {
                effectiveEnd = target
            } else {
                effectiveEnd = effectiveNow
            }
            let credited = segmentCreditedSeconds
            let elapsed = max(0, Int(effectiveEnd.timeIntervalSince(start)))
            activeElapsed = credited > 0 ? credited : elapsed
            activeStart = start
            activeEnd = effectiveEnd
        } else {
            activeElapsed = 0
            activeStart = nil
            activeEnd = effectiveNow
        }

        let startOfToday = cal.startOfDay(for: effectiveNow)
        let effectiveTodayEnd = max(startOfToday, effectiveNow)

        // 1. Today's focus time (calculated strictly for time elapsed up to `effectiveNow` on today)
        let recordsToday = sessionRecords.reduce(0) {
            $0 + $1.duration(from: startOfToday, to: effectiveTodayEnd)
        }
        let activeToday: Int
        if activeElapsed > 0, let start = activeStart {
            activeToday = FocusIntervalAllocator.allocatedDuration(
                recordStart: start,
                recordEnd: activeEnd,
                durationSeconds: activeElapsed,
                intervalStart: startOfToday,
                intervalEnd: effectiveTodayEnd
            )
        } else {
            activeToday = 0
        }
        self.todayFocusedSeconds = recordsToday + activeToday

        // 2. Weekly focus time (calculated across the past 7 days up to `effectiveNow`: [startOfToday - 6 days, effectiveWeeklyEnd])
        let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let effectiveWeeklyEnd = max(sevenDaysAgo, effectiveNow)
        let recordsWeekly = sessionRecords.reduce(0) { total, record in
            total + record.duration(from: sevenDaysAgo, to: effectiveWeeklyEnd)
        }
        let activeWeekly: Int
        if activeElapsed > 0, let start = activeStart {
            activeWeekly = FocusIntervalAllocator.allocatedDuration(
                recordStart: start,
                recordEnd: activeEnd,
                durationSeconds: activeElapsed,
                intervalStart: sevenDaysAgo,
                intervalEnd: effectiveWeeklyEnd
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
    public func handleDateOrLifecycleChange(now: Date? = nil) {
        let effectiveNow = now ?? currentDateProvider()
        reconcileActiveTimers(at: effectiveNow)
        recalculateFocusMetrics(now: effectiveNow)
        scheduleNextMidnightRefresh(now: effectiveNow)
    }

    public func handleSystemTimeZoneChange(newCalendar: Calendar? = nil, now: Date? = nil) {
        if let custom = newCalendar {
            customReportingCalendar = custom
        }
        timeZoneChangeHandledCount += 1
        let effectiveNow = now ?? currentDateProvider()
        reconcileActiveTimers(at: effectiveNow)
        recalculateFocusMetrics(now: effectiveNow)
        scheduleNextMidnightRefresh(now: effectiveNow)
    }

    private func handleCalendarOrTimeZoneChange() {
        let effectiveNow = currentDateProvider()
        recalculateFocusMetrics(now: effectiveNow)
        scheduleNextMidnightRefresh(now: effectiveNow)
    }

    public func setupDateChangeMonitoring() {
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

        NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemTimeZoneChange()
                }
            }
            .store(in: &dateChangeCancellables)

        NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
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

    /// Determines the next local-midnight deadline (with 0.05s dispatch buffer) for a supplied calendar and reference date.
    public func nextMidnightDate(after date: Date? = nil, calendar: Calendar? = nil) -> Date? {
        let cal = calendar ?? reportingCalendar
        let referenceDate = date ?? currentDateProvider()
        guard let nextMidnight = cal.nextDate(
            after: referenceDate,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return nil
        }
        return nextMidnight.addingTimeInterval(0.05)
    }

    public func scheduleNextMidnightRefresh(now: Date? = nil) {
        midnightRefreshTimer?.invalidate()
        midnightRefreshTimer = nil
        midnightRefreshCancellable?.cancel()
        midnightRefreshCancellable = nil
        scheduledMidnightFireDate = nil

        let effectiveNow = now ?? currentDateProvider()
        guard let fireDate = nextMidnightDate(after: effectiveNow, calendar: reportingCalendar) else {
            return
        }
        scheduledMidnightFireDate = fireDate

        if let customScheduler = midnightTimerScheduler {
            midnightRefreshCancellable = customScheduler(fireDate) { [weak self] in
                guard let self = self else { return }
                self.midnightRefreshCallbackCount += 1
                self.handleDateOrLifecycleChange()
            }
            return
        }

        // Production / RunLoop scheduling:
        // Only arm a real RunLoop timer if the fireDate is strictly in the future of the real system clock.
        // This prevents immediate timer callback loops when tests or callers supply simulated historical dates.
        guard fireDate > Date() else {
            return
        }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.midnightRefreshCallbackCount += 1
                self.handleDateOrLifecycleChange()
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
                synchronizeCountdownRemaining(to: 0)
                if isFocusPreset && uncounted > 0 {
                    creditTaskTime(taskId: taskId, seconds: uncounted)
                    segmentCreditedSeconds += uncounted
                }
            } else {
                let newRemaining = max(Int(ceil(remaining)), 0)
                if isFocusPreset && newRemaining < timeRemaining {
                    let delta = timeRemaining - newRemaining
                    creditTaskTime(taskId: taskId, seconds: delta)
                    segmentCreditedSeconds += delta
                }
                synchronizeCountdownRemaining(to: newRemaining)
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

    private func finalizeRunningFocusSegment(at effectiveEnd: Date, for taskId: UUID?, duration: Int? = nil) {
        guard let start = sessionSegmentStartDate else { return }
        sessionSegmentStartDate = nil

        let credited = duration ?? segmentCreditedSeconds
        segmentCreditedSeconds = 0

        let boundedEnd = max(start, effectiveEnd)
        let elapsed = credited > 0 ? credited : max(0, Int(boundedEnd.timeIntervalSince(start)))
        guard elapsed > 0 else { return }

        if isFocusPreset {
            let record = FocusSessionRecord(
                startTime: start,
                endTime: boundedEnd,
                durationSeconds: elapsed,
                mode: activePreset,
                taskId: taskId
            )
            sessionRecords.append(record)
            recalculateFocusMetrics(now: boundedEnd)
        }
    }

    private func recordActiveSessionSegment(at date: Date? = nil) {
        guard let start = sessionSegmentStartDate else { return }
        let now = date ?? currentDateProvider()
        let recordingTaskId = activeSessionTaskId
        activeSessionTaskId = nil

        let effectiveEnd: Date
        if let explicit = date {
            if isFocusPreset, let target = targetEndDate, target >= start {
                effectiveEnd = min(explicit, target)
            } else {
                effectiveEnd = explicit
            }
        } else if isFocusPreset, let target = targetEndDate, target >= start, now > target {
            effectiveEnd = target
        } else {
            effectiveEnd = now
        }

        finalizeRunningFocusSegment(at: effectiveEnd, for: recordingTaskId)
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
        let now = currentDateProvider()
        reconcileIfExpired(at: now)
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

        let now = currentDateProvider()
        if isTimerRunning {
            stopTimer(at: now)
        } else {
            reconcileIfExpired(at: now)
            recordActiveSessionSegment(at: now)
        }

        fractionalRemaining = nil
        preservedSession = nil
        pausedSession = nil

        // Apply new requested preset/mode
        applyPresetDirectly(name: pending.name, minutes: pending.minutes, seconds: pending.seconds, mode: pending.mode, isBreak: pending.isBreak)

        showConflictModal = false
        pendingTimerRequest = nil
        conflictOrigin = nil
        persistData()

        // Start target timer immediately so user directly transitions into active Break/Focus session
        if autoStart && !hasTerminated {
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
        cancelPendingSave()
        isTimerRunning = false
        isStopwatchRunning = false
        targetEndDate = nil
        fractionalRemaining = nil
        stopwatchStartDate = nil
        sessionSegmentStartDate = nil
        activeSessionTaskId = nil
        segmentCreditedSeconds = 0
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

    /// Reconciles an active countdown timer if it has reached or exceeded its deadline.
    /// Returns true if expiration reconciliation was performed.
    @discardableResult
    internal func reconcileIfExpired(at now: Date) -> Bool {
        if isTimerRunning, let target = targetEndDate, now >= target {
            reconcileActiveTimers(at: now)
            return true
        }
        return false
    }

    /// Reconciles running Focus Timer and Stopwatch against the current wall-clock deadline.
    /// Safe and idempotent across sleep/wake, application activation, and high-frequency master ticks.
    public func reconcileActiveTimers(at date: Date? = nil) {
        guard !isPersistenceBlocked else {
            suspendActiveTimersForBlockedStorage()
            return
        }
        let now = date ?? currentDateProvider()

        // 1. Reconcile running Focus / Break countdown timer
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSince(now)
            if remaining <= 0 {
                let uncounted = timeRemaining
                synchronizeCountdownRemaining(to: 0)
                preciseProgress = 0.0

                if isFocusPreset && uncounted > 0 {
                    creditTaskTime(taskId: activeSessionTaskId, seconds: uncounted)
                    segmentCreditedSeconds += uncounted
                }

                let effectiveCompletionDate: Date
                if let target = targetEndDate {
                    if let start = sessionSegmentStartDate, target < start {
                        effectiveCompletionDate = start
                    } else {
                        effectiveCompletionDate = target
                    }
                } else if let start = sessionSegmentStartDate {
                    effectiveCompletionDate = start.addingTimeInterval(TimeInterval(segmentCreditedSeconds))
                } else {
                    effectiveCompletionDate = now
                }

                recordActiveSessionSegment(at: effectiveCompletionDate)
                isTimerRunning = false
                targetEndDate = nil
                fractionalRemaining = nil
                updateMasterEngine()
                handleSessionComplete()
            } else {
                if totalTime > 0 {
                    preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                }
                let newTime = max(Int(ceil(remaining)), 0)
                if timeRemaining != newTime {
                    let delta = timeRemaining - newTime
                    synchronizeCountdownRemaining(to: newTime)
                    if isFocusPreset && delta > 0 {
                        creditTaskTime(taskId: activeSessionTaskId, seconds: delta)
                        segmentCreditedSeconds += delta
                    }
                    recalculateFocusMetrics(now: now)
                }
            }
        }

        // 2. Reconcile running Stopwatch
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

        // 3. Periodic checkpoint for crash recovery
        if (isTimerRunning || isStopwatchRunning) && !hasTerminated {
            let timeSinceSuccess = now.timeIntervalSince(lastSuccessfulCheckpointTime)
            let timeSinceAttempt = now.timeIntervalSince(lastAttemptedCheckpointTime)
            let shouldAttempt: Bool
            if isSaveFailed {
                // Throttle retries during persistent failure to prevent write storms
                shouldAttempt = timeSinceAttempt >= checkpointRetryInterval || timeSinceAttempt < 0
            } else {
                shouldAttempt = timeSinceSuccess >= checkpointInterval || timeSinceSuccess < 0
            }
            if shouldAttempt {
                lastAttemptedCheckpointTime = now
                performSave(now: now)
            }
        }
    }

    internal func tick() {
        reconcileActiveTimers(at: currentDateProvider())
    }

    // MARK: Focus Timer Core Controls
    public func startTimer() {
        guard !isPersistenceBlocked, !hasTerminated else { return }
        guard !isTimerRunning else { return }
        // Ensure only one countdown timer runs at a time
        isTimerRunning = true
        activeTimerSessionId = UUID()
        let now = currentDateProvider()
        let remainingInterval = fractionalRemaining ?? TimeInterval(timeRemaining)
        targetEndDate = now.addingTimeInterval(remainingInterval)
        preciseProgress = totalTime > 0 ? min(max(remainingInterval / Double(totalTime), 0.0), 1.0) : 1.0
        fractionalRemaining = nil
        sessionSegmentStartDate = now
        segmentCreditedSeconds = 0
        if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
            activeSessionTaskId = tasks[activeTaskIndex].id
        } else {
            activeSessionTaskId = nil
        }
        pausedSession = nil
        lastAttemptedCheckpointTime = now
        updateMasterEngine()
        persistData(force: true)
    }

    private func settleAndStopRunningCountdown(at now: Date) {
        if isTimerRunning, let target = targetEndDate {
            let remaining = max(0, target.timeIntervalSince(now))
            fractionalRemaining = remaining
            let newRemaining = max(Int(ceil(remaining)), 0)
            if isFocusPreset, newRemaining < timeRemaining {
                let delta = timeRemaining - newRemaining
                creditTaskTime(taskId: activeSessionTaskId, seconds: delta)
                segmentCreditedSeconds += delta
            }
            synchronizeCountdownRemaining(to: newRemaining)
            if totalTime > 0 {
                preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
            }
        }
        recordActiveSessionSegment(at: now)
        isTimerRunning = false
        targetEndDate = nil
        updateMasterEngine()
    }

    public func stopTimer(at date: Date? = nil) {
        guard !isPersistenceBlocked else { return }
        let now = date ?? currentDateProvider()

        if reconcileIfExpired(at: now) {
            if isTimerRunning {
                stopTimer(at: now)
            }
            return
        }

        var capturedRemaining = timeRemaining
        var capturedProgress = preciseProgress
        let wasRunning = isTimerRunning

        if isTimerRunning, let target = targetEndDate {
            let remaining = max(0, target.timeIntervalSince(now))
            fractionalRemaining = remaining
            let newRemaining = max(Int(ceil(remaining)), 0)
            if isFocusPreset, newRemaining < timeRemaining {
                let delta = timeRemaining - newRemaining
                creditTaskTime(taskId: activeSessionTaskId, seconds: delta)
                segmentCreditedSeconds += delta
            }
            synchronizeCountdownRemaining(to: newRemaining)
            capturedRemaining = newRemaining
            if totalTime > 0 {
                preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                capturedProgress = preciseProgress
            }
        }
        recordActiveSessionSegment(at: now)
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
        lastAttemptedCheckpointTime = now
        persistData(force: true)
    }

    public func toggleTimer() {
        guard !isPersistenceBlocked else { return }
        let now = currentDateProvider()
        if reconcileIfExpired(at: now) {
            return
        }
        if isTimerRunning {
            stopTimer(at: now)
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
        let now = currentDateProvider()
        if isTimerRunning {
            stopTimer(at: now)
        } else {
            reconcileIfExpired(at: now)
        }
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
        guard !isPersistenceBlocked, !hasTerminated else { return }
        guard !isStopwatchRunning else { return }
        isStopwatchRunning = true
        let now = currentDateProvider()
        let offset = stopwatchFractional ?? TimeInterval(stopwatchTime)
        stopwatchStartDate = now.addingTimeInterval(-offset)
        preciseStopwatchProgress = (offset.truncatingRemainder(dividingBy: 60.0)) / 60.0
        stopwatchFractional = nil
        lastAttemptedCheckpointTime = now
        updateMasterEngine()
        persistData(force: true)
    }

    public func stopStopwatch() {
        guard !isPersistenceBlocked else { return }
        let now = currentDateProvider()
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = now.timeIntervalSince(start)
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
        lastAttemptedCheckpointTime = now
        updateMasterEngine()
        persistData(force: true)
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
        let now = currentDateProvider()
        let currentTotal: TimeInterval
        if isStopwatchRunning, let start = stopwatchStartDate {
            currentTotal = max(0, now.timeIntervalSince(start))
        } else {
            currentTotal = max(0, stopwatchFractional ?? TimeInterval(stopwatchTime))
        }

        let lapDuration = max(0, currentTotal - lastRecordedLapElapsedSeconds)
        let lapNum = nextLapNumber

        let newLap = StopwatchLap(
            lapNumber: lapNum,
            lapDuration: lapDuration,
            totalTime: currentTotal,
            timestamp: now
        )
        lastRecordedLapElapsedSeconds = currentTotal
        nextLapNumber += 1
        laps.insert(newLap, at: 0)
        persistData(force: true)
    }

    public func removeLap(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard laps.indices.contains(index) else { return }
        laps.remove(at: index)
        persistData(force: true)
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
        let now = currentDateProvider()
        reconcileIfExpired(at: now)

        let newTask = FocusTask(title: title, estimatedMinutes: expectedMinutes, icon: "checkmark.circle", iconColor: .cyan)
        let shouldBecomeActive = tasks.isEmpty || !tasks.indices.contains(activeTaskIndex) || tasks[activeTaskIndex].isCompleted

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
                segmentCreditedSeconds = 0
                activeSessionTaskId = newTask.id
            } else {
                activeSessionTaskId = newTask.id
            }
        }
        if pausedSession != nil {
            pausedSession?.activeTaskIndex = activeTaskIndex
        }
        persistData(force: true)
    }

    public func selectTask(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index), !tasks[index].isCompleted else { return }

        let now = currentDateProvider()
        reconcileIfExpired(at: now)

        let targetTask = tasks[index]
        let currentActiveId = (isTimerRunning && isFocusPreset) ? activeSessionTaskId : (isStopwatchRunning && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted ? tasks[activeTaskIndex].id : nil)

        // Avoid unnecessary focus-record splits when selecting the same task
        if targetTask.id == currentActiveId && index == activeTaskIndex {
            return
        }

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
            segmentCreditedSeconds = 0
            activeSessionTaskId = targetTask.id
        } else {
            activeSessionTaskId = targetTask.id
        }

        if pausedSession != nil {
            pausedSession?.activeTaskIndex = index
        }
        persistData(force: true)
    }

    public func toggleTaskCompletion(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index) else { return }

        let now = currentDateProvider()
        reconcileIfExpired(at: now)

        let targetTask = tasks[index]
        let isRunningFocus = isTimerRunning && isFocusPreset

        if !targetTask.isCompleted {
            // Task is currently incomplete -> marking it COMPLETE
            let isCompletingActive = (activeTaskIndex == index)

            if isCompletingActive {
                let now = currentDateProvider()
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
                        segmentCreditedSeconds = 0
                        activeSessionTaskId = tasks[nextIndex].id
                    } else {
                        activeSessionTaskId = tasks[nextIndex].id
                    }
                } else {
                    activeSessionTaskId = nil
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                        segmentCreditedSeconds = 0
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
                let now = currentDateProvider()
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
                    segmentCreditedSeconds = 0
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
        persistData(force: true)
    }

    public func removeTask(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index) else { return }

        let now = currentDateProvider()
        reconcileIfExpired(at: now)

        let deletingTask = tasks[index]
        let isRunningFocus = isTimerRunning && isFocusPreset
        let isDeletingAssigned = (isRunningFocus && activeSessionTaskId == deletingTask.id) ||
            (!isRunningFocus && isStopwatchRunning && activeTaskIndex == index && !deletingTask.isCompleted)

        if isDeletingAssigned {
            let now = currentDateProvider()
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
                    segmentCreditedSeconds = 0
                }
            } else {
                let candidateIndex = min(index, tasks.count - 1)
                if let nextIndex = findNextAvailableTaskIndex(startingAt: candidateIndex) {
                    activeTaskIndex = nextIndex
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                        segmentCreditedSeconds = 0
                        activeSessionTaskId = tasks[nextIndex].id
                    } else {
                        activeSessionTaskId = tasks[nextIndex].id
                    }
                } else {
                    activeTaskIndex = candidateIndex
                    activeSessionTaskId = nil
                    if isRunningFocus {
                        sessionSegmentStartDate = now
                        segmentCreditedSeconds = 0
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
        persistData(force: true)
    }

    public func resetTaskTime(at index: Int) {
        guard !isPersistenceBlocked else { return }
        guard tasks.indices.contains(index) else { return }
        tasks[index].timeSpentSeconds = 0
        persistData(force: true)
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
        guard !isPersistenceBlocked, !hasTerminated else { return }
        let now = currentDateProvider()
        if reconcileIfExpired(at: now) {
            return
        }
        if isTimerRunning {
            settleAndStopRunningCountdown(at: now)
        } else {
            recordActiveSessionSegment(at: now)
        }
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
            if autoStartNextSession && !hasTerminated {
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
            if autoStartNextSession && !hasTerminated {
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
            if autoStartNextSession && !hasTerminated {
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
            if autoStartNextSession && !hasTerminated {
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
