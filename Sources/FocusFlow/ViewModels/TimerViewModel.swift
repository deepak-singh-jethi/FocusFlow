import SwiftUI
import Combine
import AppKit

// MARK: - Timer & App State ViewModel (Persistent, Date-Aware & Power-Efficient)
@MainActor
public class TimerViewModel: ObservableObject {
    // MARK: Focus Timer States
    @Published public var timeRemaining: Int = 25 * 60
    @Published public var totalTime: Int = 25 * 60
    @Published public var currentSession: Int = 1
    @Published public var totalSessions: Int = 4 {
        didSet { persistData() }
    }
    @Published public var preciseProgress: Double = 1.0
    @Published public var isTimerRunning: Bool = false
    public var targetEndDate: Date?
    private var fractionalRemaining: TimeInterval?

    // Custom Duration States
    @Published public var customMinutes: Int = 25
    @Published public var customSeconds: Int = 0
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
    private var sessionSegmentStartDate: Date?

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
    private var stopwatchStartDate: Date?
    private var stopwatchFractional: TimeInterval?

    // Task States (Persistent)
    @Published public var tasks: [FocusTask] = [
        FocusTask(title: "Deep Work Session", estimatedMinutes: 25, timeSpentSeconds: 0, icon: "star.fill", iconColor: .orange),
        FocusTask(title: "Project Review & Planning", estimatedMinutes: 30, timeSpentSeconds: 0, icon: "doc.text.fill", iconColor: .blue),
        FocusTask(title: "Core Development & Refactor", estimatedMinutes: 45, timeSpentSeconds: 0, icon: "laptopcomputer", iconColor: .purple),
        FocusTask(title: "Inbox & Team Follow-ups", estimatedMinutes: 15, timeSpentSeconds: 0, icon: "tray.fill", iconColor: .teal)
    ]
    @Published public var activeTaskIndex: Int = 0
    @Published public var completedSessions: Int = 0
    @Published public var notes: [String] = []
    @Published public var dailyGoalHours: Int = 4 {
        didSet { persistData() }
    }

    // Alerts & Modals
    @Published public var showPresetAlert: Bool = false
    @Published public var showResetAlert: Bool = false
    @Published public var showNoteEditor: Bool = false
    @Published public var noteDraft: String = ""
    public var pendingPreset: (name: String, minutes: Int)? = nil
    @Published public var autoStartNextSession: Bool = false {
        didSet { persistData() }
    }

    // MARK: - Preserved Background Session & Mode Conflict States
    @Published public var preservedSession: PreservedTimerSession?
    @Published public var showConflictModal: Bool = false
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
    private let storage: FocusStorageService
    private var isLoadingPersistedData = false
    private var lastPersistTime: Date = .distantPast

    // Active Timer Mode: "Pomodoro" or "Custom Timer"
    @Published public var activeMode: String = "Pomodoro"
    public var isRunning: Bool { isTimerRunning || isStopwatchRunning }

    public init(storage: FocusStorageService = .shared) {
        self.storage = storage
        loadPersistedData()
        NotificationService.shared.requestAuthorization()
        setupTerminationObserver()
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppTermination()
            }
        }
    }

    private func handleAppTermination() {
        if isTimerRunning {
            stopTimer()
        }
        if isStopwatchRunning {
            stopStopwatch()
        }
        persistData(force: true)
    }

    // MARK: - Persistence Integration (Priority 4A & 4C)
    public func loadPersistedData() {
        isLoadingPersistedData = true
        defer {
            isLoadingPersistedData = false
            recalculateFocusMetrics()
        }

        guard let saved = storage.load() else {
            // First run on a fresh machine (no storage file yet) -> Keep default initial tasks
            recalculateFocusMetrics()
            return
        }

        // Existing saved file -> Faithfully restore tasks, even if intentionally empty!
        self.tasks = saved.tasks
        self.sessionRecords = saved.sessionRecords
        self.legacyLifetimeFocusedSeconds = saved.legacyLifetimeFocusedSeconds
        self.completedSessions = saved.completedSessions
        self.notes = saved.notes
        self.dailyGoalHours = saved.dailyGoalHours
        self.totalSessions = saved.totalSessions
        self.autoStartNextSession = saved.autoStartNextSession
        self.activePreset = saved.activePreset
        self.laps = saved.laps
        self.preservedSession = saved.preservedSession
    }

    public func persistData(force: Bool = false) {
        guard !isLoadingPersistedData else { return }

        let now = Date()
        // Throttle disk writes to avoid repeated writes during UI animations or high frequency changes
        if !force && now.timeIntervalSince(lastPersistTime) < 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.persistData(force: true)
            }
            return
        }
        lastPersistTime = now

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
            preservedSession: preservedSession
        )
        storage.save(payload)
    }

    // MARK: - Date-Aware Analytics Recalculation (Priority 2)
    public func recalculateFocusMetrics(calendar: Calendar = .current, now: Date = Date()) {
        let activeElapsed: Int
        if isTimerRunning, isFocusPreset, let start = sessionSegmentStartDate {
            activeElapsed = max(0, Int(now.timeIntervalSince(start)))
        } else {
            activeElapsed = 0
        }

        // 1. Today's focus time (calculated strictly from dated records overlapping today)
        let recordsToday = sessionRecords.reduce(0) { $0 + $1.duration(on: now, calendar: calendar) }
        self.todayFocusedSeconds = recordsToday + activeElapsed

        // 2. Weekly focus time (calculated across the past 7 days)
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let recordsWeekly = sessionRecords.reduce(0) { total, record in
            let effectiveStart = max(record.startTime, sevenDaysAgo)
            let effectiveEnd = min(record.endTime, now)
            if effectiveEnd > effectiveStart {
                let totalSpan = max(1.0, record.endTime.timeIntervalSince(record.startTime))
                let overlap = effectiveEnd.timeIntervalSince(effectiveStart)
                let ratio = min(1.0, max(0.0, overlap / totalSpan))
                return total + Int(round(Double(record.durationSeconds) * ratio))
            }
            return total
        }
        self.weeklyFocusedSeconds = recordsWeekly + activeElapsed

        // 3. Lifetime focus time (all dated records + any legacy unassigned historical total)
        let recordsLifetime = sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        let legacy = legacyLifetimeFocusedSeconds ?? 0
        self.lifetimeFocusedSeconds = recordsLifetime + legacy + activeElapsed

        // Maintain focusedSeconds for direct backward-compatible binding
        self.focusedSeconds = self.todayFocusedSeconds
    }

    private func recordActiveSessionSegment() {
        guard let start = sessionSegmentStartDate else { return }
        sessionSegmentStartDate = nil
        let now = Date()
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        guard elapsed > 0 else { return }

        if isFocusPreset {
            let activeTaskId = tasks.indices.contains(activeTaskIndex) ? tasks[activeTaskIndex].id : nil
            let record = FocusSessionRecord(
                startTime: start,
                endTime: now,
                durationSeconds: elapsed,
                mode: activePreset,
                taskId: activeTaskId
            )
            sessionRecords.append(record)
            recalculateFocusMetrics(now: now)
            persistData()
        }
    }

    // MARK: Mode Switching within Timer Sessions
    public func changeMode(to newMode: String) {
        if newMode == "Pomodoro" {
            switchToFocus(minutes: 25)
        } else if newMode == "Custom Timer" {
            requestModeOrPresetChange(name: "Custom", minutes: customMinutes, seconds: customSeconds, mode: "Custom Timer", isBreak: false)
        }
    }

    // MARK: - Conflict-Aware Mode / Preset Requests
    public func requestModeOrPresetChange(name: String, minutes: Int, seconds: Int = 0, mode: String = "Pomodoro", isBreak: Bool = false) {
        let isSame = (activePreset == name && activeMode == mode && (mode != "Custom Timer" || totalTime == (minutes * 60 + seconds)))
        if isSame { return }

        // If a timer is currently active (running or paused with time elapsed):
        if isTimerActive {
            pendingTimerRequest = (name: name, minutes: minutes, seconds: seconds, mode: mode, isBreak: isBreak)
            showConflictModal = true
        } else {
            // Idle timer -> directly switch without interruption
            applyPresetDirectly(name: name, minutes: minutes, seconds: seconds, mode: mode, isBreak: isBreak)
        }
    }

    public func applyPresetDirectly(name: String, minutes: Int, seconds: Int = 0, mode: String = "Pomodoro", isBreak: Bool = false) {
        if isTimerRunning { stopTimer() }
        fractionalRemaining = nil
        activePreset = name
        activeMode = mode
        isBreakSession = isBreak
        let total = max(5, minutes * 60 + seconds)
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
    }

    public func pauseAndSwitch() {
        guard let pending = pendingTimerRequest else {
            showConflictModal = false
            return
        }

        // 1. Record active elapsed segment if running
        recordActiveSessionSegment()

        // 2. Pause active timer
        if isTimerRunning {
            isTimerRunning = false
            targetEndDate = nil
            fractionalRemaining = TimeInterval(timeRemaining)
            updateMasterEngine()
        }

        // 3. Save current session into preservedSession
        preservedSession = PreservedTimerSession(
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
        )

        // 4. Apply new requested preset/mode
        applyPresetDirectly(name: pending.name, minutes: pending.minutes, seconds: pending.seconds, mode: pending.mode, isBreak: pending.isBreak)

        showConflictModal = false
        pendingTimerRequest = nil
        persistData()
    }

    public func endAndSwitch() {
        guard let pending = pendingTimerRequest else {
            showConflictModal = false
            return
        }

        // 1. Record completed focus time into session records
        recordActiveSessionSegment()

        // 2. Stop timer and clear preserved session
        stopTimer()
        fractionalRemaining = nil
        preservedSession = nil

        // 3. Apply new requested preset/mode
        applyPresetDirectly(name: pending.name, minutes: pending.minutes, seconds: pending.seconds, mode: pending.mode, isBreak: pending.isBreak)

        showConflictModal = false
        pendingTimerRequest = nil
        persistData()
    }

    public func restorePreservedSession() {
        guard let preserved = preservedSession else { return }

        // If current timer is active, swap it into preservedSession so neither is lost!
        let currentWasActive = isTimerRunning || (timeRemaining < totalTime && timeRemaining > 0)
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

        if isTimerRunning {
            stopTimer()
        }

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
        persistData()
    }

    public func restorePreservedSessionIfNeeded() {
        if hasPreservedSession && !isTimerRunning {
            restorePreservedSession()
        }
    }

    // MARK: Master Engine
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

    private func tick() {
        let now = Date()

        // 1. Tick Focus Timer smoothly if running
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSinceNow
            if remaining <= 0 {
                preciseProgress = 0.0
                let uncounted = timeRemaining
                timeRemaining = 0
                if isFocusPreset && uncounted > 0 {
                    if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                        tasks[activeTaskIndex].timeSpentSeconds += uncounted
                    }
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
                        if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                            tasks[activeTaskIndex].timeSpentSeconds += delta
                        }
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
                if delta > 0 && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                }
            }
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
    }

    // MARK: Focus Timer Core Controls
    public func startTimer() {
        guard !isTimerRunning else { return }
        // Ensure only one countdown timer runs at a time
        isTimerRunning = true
        let remainingInterval = fractionalRemaining ?? TimeInterval(timeRemaining)
        targetEndDate = Date().addingTimeInterval(remainingInterval)
        preciseProgress = totalTime > 0 ? min(max(remainingInterval / Double(totalTime), 0.0), 1.0) : 1.0
        fractionalRemaining = nil
        sessionSegmentStartDate = Date()
        updateMasterEngine()
    }

    public func stopTimer() {
        if isTimerRunning, let target = targetEndDate {
            let remaining = max(0, target.timeIntervalSinceNow)
            fractionalRemaining = remaining
            let newRemaining = max(Int(ceil(remaining)), 0)
            if isFocusPreset, newRemaining < timeRemaining {
                let delta = timeRemaining - newRemaining
                if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                }
            }
            timeRemaining = newRemaining
            if totalTime > 0 {
                preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
            }
        }
        recordActiveSessionSegment()
        isTimerRunning = false
        targetEndDate = nil
        updateMasterEngine()
        persistData()
    }

    public func toggleTimer() {
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
        recordActiveSessionSegment()
        stopTimer()
        fractionalRemaining = nil
        timeRemaining = totalTime
        preciseProgress = 1.0
        persistData()
    }

    public func resetTimer() {
        resetFocusTimer()
    }

    // MARK: Stopwatch Core Controls (Priority 5)
    public func startStopwatch() {
        guard !isStopwatchRunning else { return }
        isStopwatchRunning = true
        let offset = stopwatchFractional ?? TimeInterval(stopwatchTime)
        stopwatchStartDate = Date().addingTimeInterval(-offset)
        preciseStopwatchProgress = (offset.truncatingRemainder(dividingBy: 60.0)) / 60.0
        stopwatchFractional = nil
        updateMasterEngine()
    }

    public func stopStopwatch() {
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = Date().timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if newTime > stopwatchTime {
                let delta = newTime - stopwatchTime
                if delta > 0 && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
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
        if isStopwatchRunning {
            stopStopwatch()
        } else {
            startStopwatch()
        }
    }

    public func resetStopwatch() {
        stopStopwatch()
        stopwatchFractional = nil
        stopwatchTime = 0
        laps.removeAll()
        preciseStopwatchProgress = 0.0
        persistData()
    }

    public func recordLap() {
        let currentTotal: TimeInterval
        if isStopwatchRunning, let start = stopwatchStartDate {
            currentTotal = max(0, Date().timeIntervalSince(start))
        } else {
            currentTotal = max(0, stopwatchFractional ?? TimeInterval(stopwatchTime))
        }

        // Previous cumulative total time across laps:
        let previousTotal = laps.first?.totalTime ?? 0.0
        let lapDuration = max(0, currentTotal - previousTotal)
        let nextLapNumber = laps.count + 1

        let newLap = StopwatchLap(
            lapNumber: nextLapNumber,
            lapDuration: lapDuration,
            totalTime: currentTotal,
            timestamp: Date()
        )
        laps.insert(newLap, at: 0)
        persistData()
    }

    public func removeLap(at index: Int) {
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
        if isStopwatch {
            recordLap()
        } else {
            noteDraft = ""
            showNoteEditor = true
        }
    }

    public func addTask(title: String = "New Task", expectedMinutes: Int = 25) {
        let newTask = FocusTask(title: title, estimatedMinutes: expectedMinutes, icon: "checkmark.circle", iconColor: .cyan)
        tasks.append(newTask)
        if tasks.count == 1 || !tasks.indices.contains(activeTaskIndex) || tasks[activeTaskIndex].isCompleted {
            activeTaskIndex = tasks.count - 1
        }
        persistData()
    }

    public func selectTask(at index: Int) {
        guard tasks.indices.contains(index), !tasks[index].isCompleted else { return }
        activeTaskIndex = index
    }

    public func toggleTaskCompletion(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks[index].isCompleted.toggle()
        if activeTaskIndex == index && tasks[index].isCompleted {
            advanceToNextAvailableTask(after: index)
        }
        persistData()
    }

    public func removeTask(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks.remove(at: index)
        if tasks.isEmpty {
            activeTaskIndex = 0
        } else if index < activeTaskIndex {
            activeTaskIndex -= 1
        } else if activeTaskIndex >= tasks.count {
            activeTaskIndex = tasks.count - 1
        }
        persistData()
    }

    public func resetTaskTime(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks[index].timeSpentSeconds = 0
        persistData()
    }

    public func saveNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(trimmed, at: 0)
        noteDraft = ""
        showNoteEditor = false
        persistData()
    }

    public func deleteNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        notes.remove(at: index)
        persistData()
    }

    public func requestPresetChange(name: String, minutes: Int) {
        guard minutes > 0 else { return }
        let isBreak = (name == "Short Break" || name == "Long Break" || name == "Break")
        requestModeOrPresetChange(name: name, minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: isBreak)
    }

    public func setCustomDuration(minutes: Int, seconds: Int) {
        let safeM = max(0, min(minutes, 360))
        let safeS = max(0, min(seconds, 59))
        requestModeOrPresetChange(name: "Custom", minutes: safeM, seconds: safeS, mode: "Custom Timer", isBreak: false)
    }

    public func switchToBreak(minutes: Int = 5) {
        requestModeOrPresetChange(name: "Short Break", minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: true)
    }

    public func switchToFocus(minutes: Int = 25) {
        requestModeOrPresetChange(name: "Focus", minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: false)
    }

    public func applyPendingPreset() {
        guard let pending = pendingPreset else { return }
        requestPresetChange(name: pending.name, minutes: pending.minutes)
        pendingPreset = nil
    }

    public func cancelPendingPreset() {
        pendingPreset = nil
    }

    public func applyPreset(name: String, minutes: Int) {
        let isBreak = (name == "Short Break" || name == "Long Break" || name == "Break")
        applyPresetDirectly(name: name, minutes: minutes, seconds: 0, mode: "Pomodoro", isBreak: isBreak)
    }

    public func skipSession() {
        recordActiveSessionSegment()
        stopTimer()
        fractionalRemaining = nil
        if isBreakPreset {
            applyPresetDirectly(name: "Focus", minutes: 25, mode: "Pomodoro", isBreak: false)
        } else {
            advanceSession()
        }
    }

    private func handleSessionComplete() {
        stopTimer()
        fractionalRemaining = nil

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
            applyPresetDirectly(name: "Focus", minutes: 25, mode: "Pomodoro", isBreak: false)
            persistData()
            if autoStartNextSession {
                startTimer()
            }
        }
    }

    private func advanceSession() {
        recordActiveSessionSegment()
        completedSessions += 1
        let isFinalSession = currentSession >= totalSessions
        currentSession = isFinalSession ? (autoStartNextSession ? currentSession : 1) : currentSession + 1
        let nextBreakPreset = isFinalSession ? "Long Break" : "Short Break"
        let nextBreakMinutes = isFinalSession ? 15 : 5
        applyPresetDirectly(name: nextBreakPreset, minutes: nextBreakMinutes, mode: "Pomodoro", isBreak: true)
        persistData()
        if autoStartNextSession {
            startTimer()
        }
    }

    private func advanceToNextAvailableTask(after currentIndex: Int) {
        guard !tasks.isEmpty else { return }
        let count = tasks.count
        for offset in 1..<count {
            let nextIndex = (currentIndex + offset) % count
            if !tasks[nextIndex].isCompleted {
                activeTaskIndex = nextIndex
                return
            }
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
        let m = stopwatchTime / 60
        let s = stopwatchTime % 60
        return String(format: "%02d:%02d", m, s)
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
        persistData()
    }
}
