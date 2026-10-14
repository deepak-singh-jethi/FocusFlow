import SwiftUI
import Combine
import AppKit

// MARK: - Timer & App State ViewModel
@MainActor
public class TimerViewModel: ObservableObject {
    // MARK: Focus Timer States
    @Published public var timeRemaining: Int = 25 * 60
    @Published public var totalTime: Int = 25 * 60
    @Published public var currentSession: Int = 1
    @Published public var totalSessions: Int = 4
    @Published public var preciseProgress: Double = 1.0
    @Published public var isTimerRunning: Bool = false
    public var targetEndDate: Date?
    private var fractionalRemaining: TimeInterval?

    // Custom Duration States
    @Published public var customMinutes: Int = 25
    @Published public var customSeconds: Int = 0
    private var customDurationSeconds: Int = 25 * 60

    // Preset & Modes
    @Published public var activePreset: String = "Focus"
    public var isBreakPreset: Bool { activePreset == "Short Break" || activePreset == "Long Break" }
    public var isFocusPreset: Bool { !isBreakPreset }

    // MARK: Stopwatch States
    @Published public var stopwatchTime: Int = 0
    @Published public var preciseStopwatchProgress: Double = 0.0
    @Published public var isStopwatchRunning: Bool = false
    @Published public var lapTimes: [String] = []
    private var stopwatchStartDate: Date?
    private var stopwatchFractional: TimeInterval?

    // Task States
    @Published public var tasks: [FocusTask] = [
        FocusTask(title: "Deep Work Session", estimatedMinutes: 25, timeSpentSeconds: 0, icon: "star.fill", iconColor: .orange),
        FocusTask(title: "Project Review & Planning", estimatedMinutes: 30, timeSpentSeconds: 0, icon: "doc.text.fill", iconColor: .blue),
        FocusTask(title: "Core Development & Refactor", estimatedMinutes: 45, timeSpentSeconds: 0, icon: "laptopcomputer", iconColor: .purple),
        FocusTask(title: "Inbox & Team Follow-ups", estimatedMinutes: 15, timeSpentSeconds: 0, icon: "tray.fill", iconColor: .teal)
    ]
    @Published public var activeTaskIndex: Int = 0
    @Published public var completedSessions: Int = 0
    @Published public var focusedSeconds: Int = 0
    @Published public var notes: [String] = []
    @Published public var dailyGoalHours: Int = 4

    // Alerts & Modals
    @Published public var showPresetAlert: Bool = false
    @Published public var showResetAlert: Bool = false
    @Published public var showNoteEditor: Bool = false
    @Published public var noteDraft: String = ""
    public var pendingPreset: (name: String, minutes: Int)? = nil
    @Published public var autoStartNextSession: Bool = false

    // Master 50Hz Timer Engine
    private var timerSubscription: AnyCancellable?

    // Active Timer Mode: "Pomodoro" or "Custom Timer"
    @Published public var activeMode: String = "Pomodoro"
    public var isRunning: Bool { isTimerRunning || isStopwatchRunning }

    public init() {}

    // MARK: Mode Switching within Timer Sessions
    public func changeMode(to newMode: String) {
        if isTimerRunning { stopTimer() }
        if newMode == "Pomodoro" {
            activePreset = "Focus"
            totalTime = 25 * 60
            timeRemaining = totalTime
            preciseProgress = 1.0
        } else if newMode == "Custom Timer" {
            activePreset = "Custom"
            totalTime = customDurationSeconds
            timeRemaining = totalTime
            customMinutes = totalTime / 60
            customSeconds = totalTime % 60
            preciseProgress = 1.0
        }
    }

    // MARK: Master Engine
    private func updateMasterEngine() {
        if isTimerRunning || isStopwatchRunning {
            if timerSubscription == nil {
                timerSubscription = Timer.publish(every: 0.02, on: .main, in: .common)
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
        // 1. Tick Focus Timer smoothly if running
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSinceNow
            if remaining <= 0 {
                preciseProgress = 0.0
                let uncounted = timeRemaining
                timeRemaining = 0
                if isFocusPreset && uncounted > 0 {
                    focusedSeconds += uncounted
                    if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                        tasks[activeTaskIndex].timeSpentSeconds += uncounted
                    }
                }
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
                        focusedSeconds += delta
                        if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                            tasks[activeTaskIndex].timeSpentSeconds += delta
                        }
                    }
                }
            }
        }

        // 2. Tick Stopwatch smoothly if running
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = Date().timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if stopwatchTime != newTime {
                let delta = newTime - stopwatchTime
                stopwatchTime = newTime
                if delta > 0 && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                    focusedSeconds += delta
                }
            }
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
    }

    // MARK: Focus Timer Core Controls
    public func startTimer() {
        guard !isTimerRunning else { return }
        isTimerRunning = true
        let remainingInterval = fractionalRemaining ?? TimeInterval(timeRemaining)
        targetEndDate = Date().addingTimeInterval(remainingInterval)
        preciseProgress = totalTime > 0 ? min(max(remainingInterval / Double(totalTime), 0.0), 1.0) : 1.0
        fractionalRemaining = nil
        updateMasterEngine()
    }

    public func stopTimer() {
        if isTimerRunning, let target = targetEndDate {
            let remaining = max(0, target.timeIntervalSinceNow)
            fractionalRemaining = remaining
            let newRemaining = max(Int(ceil(remaining)), 0)
            if isFocusPreset, newRemaining < timeRemaining {
                let delta = timeRemaining - newRemaining
                focusedSeconds += delta
                if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                }
            }
            timeRemaining = newRemaining
            if totalTime > 0 {
                preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
            }
        }
        isTimerRunning = false
        targetEndDate = nil
        updateMasterEngine()
    }

    public func toggleTimer() {
        if isTimerRunning {
            stopTimer()
        } else {
            startTimer()
        }
    }

    public func resetFocusTimer() {
        stopTimer()
        fractionalRemaining = nil
        timeRemaining = totalTime
        preciseProgress = 1.0
    }

    public func resetTimer() {
        resetFocusTimer()
    }

    // MARK: Stopwatch Core Controls
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
                    focusedSeconds += delta
                }
            }
            stopwatchFractional = elapsed
            stopwatchTime = newTime
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
        isStopwatchRunning = false
        stopwatchStartDate = nil
        updateMasterEngine()
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
        lapTimes.removeAll()
        preciseStopwatchProgress = 0.0
    }

    public func recordLap() {
        lapTimes.insert(stopwatchTimeString, at: 0)
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
    }

    public func resetTaskTime(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks[index].timeSpentSeconds = 0
    }

    public func saveNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(trimmed, at: 0)
        noteDraft = ""
        showNoteEditor = false
    }

    public func removeLap(at index: Int) {
        guard lapTimes.indices.contains(index) else { return }
        lapTimes.remove(at: index)
    }

    public func requestPresetChange(name: String, minutes: Int) {
        guard minutes > 0 else { return }
        if timeRemaining < totalTime {
            pendingPreset = (name, minutes)
            showPresetAlert = true
        } else {
            applyPreset(name: name, minutes: minutes)
        }
    }

    public func setCustomDuration(minutes: Int, seconds: Int) {
        let safeM = max(0, min(minutes, 360))
        let safeS = max(0, min(seconds, 59))
        let total = max(5, safeM * 60 + safeS)

        customMinutes = total / 60
        customSeconds = total % 60
        customDurationSeconds = total

        if isTimerRunning { stopTimer() }
        fractionalRemaining = nil
        activeMode = "Custom Timer"
        activePreset = "Custom"
        totalTime = total
        timeRemaining = total
        preciseProgress = 1.0
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
    }

    public func applyPendingPreset() {
        if let preset = pendingPreset {
            applyPreset(name: preset.name, minutes: preset.minutes)
            pendingPreset = nil
        }
    }

    public func cancelPendingPreset() {
        pendingPreset = nil
    }

    private func applyPreset(name: String, minutes: Int) {
        stopTimer()
        fractionalRemaining = nil
        activeMode = "Pomodoro"
        activePreset = name
        totalTime = minutes * 60
        timeRemaining = totalTime
        preciseProgress = 1.0
    }

    // MARK: Session Flow
    public func skipSession() {
        stopTimer()
        fractionalRemaining = nil
        if isBreakPreset {
            applyPreset(name: "Focus", minutes: 25)
        } else {
            advanceSession()
        }
    }

    private func handleSessionComplete() {
        stopTimer()
        fractionalRemaining = nil

        // Completion chime (native macOS alert sound)
        if let chime = NSSound(named: NSSound.Name("Glass")) {
            chime.play()
        } else {
            NSSound.beep()
        }

        if isFocusPreset {
            completedSessions += 1
            if tasks.indices.contains(activeTaskIndex) {
                tasks[activeTaskIndex].isCompleted = true
                advanceToNextAvailableTask(after: activeTaskIndex)
            }

            let isFinalSession = currentSession >= totalSessions
            currentSession = isFinalSession ? (autoStartNextSession ? currentSession : 1) : currentSession + 1
            let nextBreakPreset = isFinalSession ? "Long Break" : "Short Break"
            let nextBreakMinutes = isFinalSession ? 15 : 5

            applyPreset(name: nextBreakPreset, minutes: nextBreakMinutes)
            if autoStartNextSession {
                startTimer()
            }
            return
        } else {
            if activePreset == "Long Break" {
                currentSession = 1
            }
            applyPreset(name: "Focus", minutes: 25)
            if autoStartNextSession {
                startTimer()
            }
            return
        }
    }

    private func advanceSession() {
        if currentSession < totalSessions {
            currentSession += 1
        } else {
            currentSession = 1
        }

        // Advance to next task if available
        advanceToNextAvailableTask(after: activeTaskIndex)

        timeRemaining = totalTime
        preciseProgress = 1.0
    }

    private func advanceToNextAvailableTask(after index: Int) {
        guard !tasks.isEmpty else { activeTaskIndex = 0; return }
        for offset in 1...tasks.count {
            let candidate = (max(index, -1) + offset) % tasks.count
            if !tasks[candidate].isCompleted {
                activeTaskIndex = candidate
                return
            }
        }
        activeTaskIndex = -1
    }

    // MARK: UI Helpers
    public var timerTimeString: String {
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var stopwatchTimeString: String {
        let minutes = stopwatchTime / 60
        let seconds = stopwatchTime % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var timeString: String {
        timerTimeString
    }

    public var formattedCustomDuration: String {
        let m = totalTime / 60
        let s = totalTime % 60
        if m > 0 && s > 0 {
            return "\(m)m \(s)s"
        } else if m > 0 {
            return "\(m) min"
        } else {
            return "\(s)s"
        }
    }

    public var fillAmount: Double {
        preciseProgress
    }
}
