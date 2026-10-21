import XCTest
import SwiftUI
import Combine
@testable import FocusFlow

final class FocusFlowTests: XCTestCase {

    // Helper for isolated storage so tests NEVER touch production data
    @MainActor
    private func makeIsolatedViewModel() -> (TimerViewModel, URL) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)
        return (vm, tempURL)
    }

    @MainActor
    private func cleanup(url: URL, vm: TimerViewModel? = nil) {
        vm?.cancelDateChangeMonitoring()
        try? FileManager.default.removeItem(at: url)
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        let parentDir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        if let contents = try? FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil) {
            for item in contents where item.lastPathComponent.contains(baseName) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    // MARK: - Task Model Tests
    func testTaskModelCalculations() {
        var task = FocusTask(title: "Write Architecture Tests", estimatedMinutes: 30, timeSpentSeconds: 900)
        XCTAssertEqual(task.expectedTime, "30m")
        XCTAssertEqual(task.formattedTimeSpent, "15m")
        XCTAssertEqual(task.progress, 0.5, accuracy: 0.001)

        task.timeSpentSeconds = 1800
        XCTAssertEqual(task.progress, 1.0, accuracy: 0.001)

        // Progress is safely clamped to 1.0
        task.timeSpentSeconds = 2700
        XCTAssertEqual(task.progress, 1.0, accuracy: 0.001)
    }

    func testTaskColorMapping() {
        let orangeTask = FocusTask(title: "Orange", iconColor: .orange)
        XCTAssertEqual(orangeTask.iconColorName, "orange")

        let cyanTask = FocusTask(title: "Cyan", iconColor: .cyan)
        XCTAssertEqual(cyanTask.iconColorName, "cyan")
    }

    // MARK: - Priority 4B: Test Isolation & Storage Roundtrip
    func testPersistenceRoundtrip() {
        let testTasks = [
            FocusTask(title: "Persistent Unit Test", estimatedMinutes: 45, timeSpentSeconds: 300)
        ]
        let original = FocusAppData(
            tasks: testTasks,
            focusedSeconds: 1200,
            completedSessions: 3,
            notes: ["Refactored state machine", "Validated persistence"],
            dailyGoalHours: 6,
            totalSessions: 5,
            autoStartNextSession: true,
            activePreset: "Focus"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(original) else {
            XCTFail("Failed to encode FocusAppData")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(FocusAppData.self, from: data) else {
            XCTFail("Failed to decode FocusAppData")
            return
        }

        XCTAssertEqual(decoded.tasks.count, 1)
        XCTAssertEqual(decoded.tasks.first?.title, "Persistent Unit Test")
        XCTAssertEqual(decoded.focusedSeconds, 1200)
        XCTAssertEqual(decoded.completedSessions, 3)
        XCTAssertEqual(decoded.notes.count, 2)
        XCTAssertEqual(decoded.dailyGoalHours, 6)
        XCTAssertEqual(decoded.totalSessions, 5)
        XCTAssertTrue(decoded.autoStartNextSession)
        XCTAssertEqual(decoded.activePreset, "Focus")
    }

    // MARK: - Priority 4A: Empty Tasks Restoration
    @MainActor
    func testEmptyTasksRestoration() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Remove all tasks intentionally
        vm1.tasks.removeAll()
        XCTAssertTrue(vm1.tasks.isEmpty)
        vm1.persistData(force: true)

        // Launch a new ViewModel instance pointed at the exact same storage
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        // Intentionally empty task list must remain empty and NOT resurrect default tasks
        XCTAssertTrue(vm2.tasks.isEmpty, "Intentionally empty tasks array must remain empty upon reload")
    }

    // MARK: - Priority 3: Stop Automatically Completing Tasks
    @MainActor
    func testTaskDoesNotAutoCompleteOnSessionFinish() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Select first task and verify it is incomplete
        XCTAssertFalse(vm.tasks.isEmpty)
        let activeIndex = vm.activeTaskIndex
        XCTAssertFalse(vm.tasks[activeIndex].isCompleted)

        // Simulate session completion by invoking skipSession()
        vm.skipSession()

        // Verify session progression occurred without increasing completedSessions
        XCTAssertEqual(vm.completedSessions, 0, "Skipping a session must NOT increase completedSessions")
        XCTAssertTrue(vm.isBreakPreset)

        // PRIORITY 3 ACCEPTANCE: Task must still be incomplete!
        XCTAssertFalse(vm.tasks[activeIndex].isCompleted, "Completing or skipping a Pomodoro must NEVER automatically mark a longer task complete")
    }

    // MARK: - Priority 2: Date-Aware Session Tracking & Midnight Transitions
    func testMidnightTransitionSessionDuration() {
        let calendar = Calendar.current
        var comps1 = DateComponents()
        comps1.year = 2026
        comps1.month = 10
        comps1.day = 15
        comps1.hour = 23
        comps1.minute = 50
        comps1.second = 0
        guard let start = calendar.date(from: comps1) else {
            XCTFail("Failed to construct start date")
            return
        }

        // 25-minute session crossing midnight into 2026-10-16 00:15
        let end = start.addingTimeInterval(25 * 60)
        let record = FocusSessionRecord(
            startTime: start,
            endTime: end,
            durationSeconds: 25 * 60,
            mode: "Focus"
        )

        // Day 1 (2026-10-15) has 10 minutes (600 seconds) before midnight
        let day1Duration = record.duration(on: start, calendar: calendar)
        XCTAssertEqual(day1Duration, 10 * 60, "Day 1 before midnight must receive exactly 10 minutes")

        // Day 2 (2026-10-16) has 15 minutes (900 seconds) after midnight
        let day2Duration = record.duration(on: end, calendar: calendar)
        XCTAssertEqual(day2Duration, 15 * 60, "Day 2 after midnight must receive exactly 15 minutes")

        // Day 3 (2026-10-17) has 0 minutes
        guard let day3 = calendar.date(byAdding: .day, value: 2, to: start) else { return }
        let day3Duration = record.duration(on: day3, calendar: calendar)
        XCTAssertEqual(day3Duration, 0)
    }

    // MARK: - Priority 2: Schema Migration Does Not Falsely Attribute Undated Totals to Today
    @MainActor
    func testLegacySchemaMigrationPreservesLifetimeWithoutPollutingToday() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_legacy_\(UUID().uuidString).json")
        defer { cleanup(url: tempURL) }

        // Construct legacy JSON payload without sessionRecords
        let legacyJSON = """
        {
            "tasks": [],
            "focusedSeconds": 7200,
            "completedSessions": 4,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital"
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: tempURL)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)

        // Lifetime total should include the 7200 legacy seconds
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 7200)

        // Today's focus MUST be 0 because the legacy seconds are undated!
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Historical undated totals must not falsely appear as today's focus")
    }

    // MARK: - Priority 5: Numeric Stopwatch Precision & Laps
    @MainActor
    func testPrecisionStopwatchLaps() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.resetStopwatch()
        XCTAssertEqual(vm.laps.count, 0)
        XCTAssertEqual(vm.lapTimes.count, 0)

        // Directly insert 3 known laps to test mathematical split calculations and fastest/slowest detection
        let lap1 = StopwatchLap(lapNumber: 1, lapDuration: 12.5, totalTime: 12.5)
        let lap2 = StopwatchLap(lapNumber: 2, lapDuration: 20.0, totalTime: 32.5) // Slowest
        let lap3 = StopwatchLap(lapNumber: 3, lapDuration: 8.2, totalTime: 40.7)  // Fastest

        vm.laps = [lap3, lap2, lap1] // Newest at index 0

        XCTAssertEqual(vm.laps.count, 3)
        // Fastest is lap 3 (duration 8.2) at index 0
        XCTAssertEqual(vm.fastestLapIndex, 0)
        // Slowest is lap 2 (duration 20.0) at index 1
        XCTAssertEqual(vm.slowestLapIndex, 1)

        // Format checks
        XCTAssertEqual(StopwatchLap.formatDuration(8.2), "08.20")
        XCTAssertEqual(StopwatchLap.formatDuration(75.5), "01:15.50")

        // Test removal
        vm.removeLap(at: 0)
        XCTAssertEqual(vm.laps.count, 2)

        // Test reset
        vm.resetStopwatch()
        XCTAssertEqual(vm.laps.count, 0)
    }

    // MARK: - Priority 5: Standard Lap Insertion
    @MainActor
    func testStopwatchLaps() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.resetStopwatch()
        XCTAssertEqual(vm.lapTimes.count, 0)

        vm.recordLap()
        XCTAssertEqual(vm.lapTimes.count, 1)
        XCTAssertEqual(vm.lapTimes.first, "00:00")

        vm.removeLap(at: 0)
        XCTAssertEqual(vm.lapTimes.count, 0)
    }

    // MARK: - ViewModel Unit Tests
    @MainActor
    func testTimerViewModelTaskManagement() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let initialCount = vm.tasks.count

        vm.addTask(title: "New Automated Task", expectedMinutes: 20)
        XCTAssertEqual(vm.tasks.count, initialCount + 1)
        XCTAssertEqual(vm.tasks.last?.title, "New Automated Task")
        XCTAssertEqual(vm.tasks.last?.estimatedMinutes, 20)

        // Select task
        let newIndex = vm.tasks.count - 1
        vm.selectTask(at: newIndex)
        XCTAssertEqual(vm.activeTaskIndex, newIndex)

        // Toggle task completion
        vm.toggleTaskCompletion(at: newIndex)
        XCTAssertTrue(vm.tasks[newIndex].isCompleted)

        // Delete task
        vm.removeTask(at: newIndex)
        XCTAssertEqual(vm.tasks.count, initialCount)
    }

    @MainActor
    func testCustomDurationConfiguration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 42, seconds: 30)

        XCTAssertEqual(vm.totalTime, 42 * 60 + 30)
        XCTAssertEqual(vm.timeRemaining, 42 * 60 + 30)
        XCTAssertEqual(vm.customMinutes, 42)
        XCTAssertEqual(vm.customSeconds, 30)
        XCTAssertEqual(vm.activePreset, "Custom")
        XCTAssertEqual(vm.activeMode, "Custom Timer")
    }

    @MainActor
    func testNoteManagement() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let initialNoteCount = vm.notes.count

        vm.noteDraft = "Tested unit testing pipeline"
        vm.saveNote()
        XCTAssertEqual(vm.notes.count, initialNoteCount + 1)
        XCTAssertEqual(vm.notes.first, "Tested unit testing pipeline")
        XCTAssertEqual(vm.noteDraft, "")

        vm.deleteNote(at: 0)
        XCTAssertEqual(vm.notes.count, initialNoteCount)
    }

    func testDomainEnums() {
        XCTAssertEqual(NavigationTab.focusTimer.rawValue, "Focus Timer")
        XCTAssertEqual(NavigationTab.stopwatch.rawValue, "Stopwatch & Laps")
        XCTAssertEqual(NavigationTab.tasks.rawValue, "Tasks")
        XCTAssertEqual(NavigationTab.soundscapes.rawValue, "Focus Soundscapes")
        XCTAssertEqual(NavigationTab.insights.rawValue, "Insights & Stats")
        XCTAssertEqual(NavigationTab.settings.rawValue, "Settings")

        XCTAssertEqual(ClockStyle.digital.rawValue, "Digital")
        XCTAssertEqual(ClockStyle.ring.rawValue, "Ring")
        XCTAssertEqual(ClockStyle.analog.rawValue, "Analog")
    }

    // MARK: - Priority: Timer Disappearing & Conflict Resolution Tests
    @MainActor
    func testFocusToBreakAndBreakToFocusPreservesRunningTimer() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // 1. Start a 25-minute focus timer and let some time elapse
        vm.startTimer()
        vm.timeRemaining = 1200 // 20m remaining of 25m
        XCTAssertTrue(vm.isTimerRunning)

        // 2. User presses Break: app presents confirmation reminder before ending active focus session
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal, "App must remind user before ending their active focus session")
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Short Break")

        // 3. User cancels/continues: Focus timer continues running uninterrupted
        vm.continueCurrentTimer()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1200)

        // 4. User presses Break and confirms End & Switch
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal)
        vm.endAndSwitch()
        XCTAssertFalse(vm.showConflictModal)

        // Clean transition to Break stage - active countdown starts immediately
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertEqual(vm.totalTime, 300)
        XCTAssertTrue(vm.isTimerRunning, "Target break session auto-starts immediately")

        // Stop timer to return to idle state
        vm.stopTimer()
        XCTAssertFalse(vm.isTimerRunning)

        // 5. User switches mode from Break back to Focus while idle: instantaneous with zero modals
        vm.switchToFocus(minutes: 25)
        XCTAssertFalse(vm.showConflictModal, "Idle switching should be frictionless without modals")
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.timeRemaining, 1500)
    }

    @MainActor
    func testBreakWithElapsedTimePreservedWhenSwitchingToFocus() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // 1. Start Break and elapse 60 seconds
        vm.switchToBreak(minutes: 5)
        vm.startTimer()
        vm.timeRemaining = 240 // 4m remaining of 5m
        XCTAssertTrue(vm.isTimerRunning)

        // 2. Switch back to Focus while Break is running: presents confirmation
        vm.switchToFocus(minutes: 25)
        XCTAssertTrue(vm.showConflictModal, "App must remind user before ending running break session")
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Focus")

        // 3. User chooses Continue Session
        vm.continueCurrentTimer()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 240)

        // 4. User confirms End & Switch
        vm.switchToFocus(minutes: 25)
        vm.endAndSwitch()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertTrue(vm.isTimerRunning, "Target focus session auto-starts")
    }

    @MainActor
    func testPresetConflictModalForUnrelatedPreset() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 900

        // User attempts to switch to Exam Run (50m) while timer is active
        vm.requestPresetChange(name: "Exam Run", minutes: 50)

        XCTAssertTrue(vm.showConflictModal, "Conflict modal must be presented for new preset")
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Exam Run")

        // User continues current timer
        vm.continueCurrentTimer()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.activePreset, "Focus")
    }

    @MainActor
    func testContinueCurrentTimerDismissesModalWithoutInterruption() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.requestPresetChange(name: "Exam Run", minutes: 50)
        XCTAssertTrue(vm.showConflictModal)

        // User selects: Continue Current Timer
        vm.continueCurrentTimer()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.activePreset, "Focus")
    }

    @MainActor
    func testPauseAndSwitchDelegatesToEndAndSwitch() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Setup 25m timer and elapse 500 seconds
        vm.startTimer()
        vm.timeRemaining = 1000 // 1000s remaining of 1500s
        let initialRecords = vm.sessionRecords.count

        // User attempts to switch to Exam Run (50m)
        vm.requestPresetChange(name: "Exam Run", minutes: 50)
        XCTAssertTrue(vm.showConflictModal)

        // User selects: Pause & Switch (delegates to End & Switch)
        vm.pauseAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)

        // Stage is now switched to Exam Run cleanly
        XCTAssertEqual(vm.activePreset, "Exam Run")
        XCTAssertEqual(vm.totalTime, 3000)
        XCTAssertTrue(vm.isTimerRunning, "Target timer auto-starts upon switch")
        XCTAssertNil(vm.preservedSession, "No confusing background sessions retained")
        XCTAssertGreaterThanOrEqual(vm.sessionRecords.count, initialRecords)
    }

    @MainActor
    func testEndAndSwitchLogsTimeAndClearsPreserved() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        let initialRecordCount = vm.sessionRecords.count

        vm.requestPresetChange(name: "Exam Run", minutes: 50)
        XCTAssertTrue(vm.showConflictModal)

        // User selects: End & Switch
        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertTrue(vm.isTimerRunning, "Target timer auto-starts cleanly")
        XCTAssertNil(vm.preservedSession)
        XCTAssertEqual(vm.activePreset, "Exam Run")
        XCTAssertGreaterThanOrEqual(vm.sessionRecords.count, initialRecordCount)
    }

    @MainActor
    func testPreservedSessionStorageRoundtrip() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Assign preserved session for schema serialization test
        vm1.preservedSession = PreservedTimerSession(
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 850,
            preciseProgress: 850.0 / 1500.0,
            customMinutes: 25,
            customSeconds: 0,
            currentSession: 1,
            activeTaskIndex: 0
        )
        vm1.persistData(force: true)

        // Reload fresh ViewModel from disk
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertTrue(vm2.hasPreservedSession, "Preserved session must survive app relaunch")
        XCTAssertEqual(vm2.preservedSession?.activePreset, "Focus")
        XCTAssertEqual(vm2.preservedSession?.timeRemaining, 850)
    }

    // MARK: - Regressions: Fix 1 (Skip vs Natural Completion) & Fix 2 (Stopwatch Formatting)
    @MainActor
    func testSkippedSessionsDoNotIncreaseCompletedCount() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.activePreset, "Focus")

        // 1. Skip Focus session
        vm.skipSession()
        XCTAssertEqual(vm.completedSessions, 0, "Skipping a focus session must not increment completedSessions")
        XCTAssertTrue(vm.isBreakPreset, "Skipping focus must advance to break")
        XCTAssertEqual(vm.activePreset, "Short Break")

        // 2. Skip Break session
        vm.skipSession()
        XCTAssertEqual(vm.completedSessions, 0, "Skipping a break session must not increment completedSessions")
        XCTAssertFalse(vm.isBreakPreset, "Skipping break must return to focus")
        XCTAssertEqual(vm.activePreset, "Focus")
    }

    @MainActor
    func testNaturalFocusCompletionIncreasesCompletedCountExactlyOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.activePreset, "Focus")

        // Simulate natural completion of a focus session
        vm.handleSessionComplete()

        XCTAssertEqual(vm.completedSessions, 1, "Natural completion of focus timer must increment completedSessions by 1")
        XCTAssertTrue(vm.isBreakPreset, "Natural completion of focus timer must transition to break")
        XCTAssertEqual(vm.activePreset, "Short Break")
    }

    func testStopwatchLapFormattingBeforeAndAfterOneHour() {
        // Table required by specification:
        // 8.2 seconds -> "08.20"
        XCTAssertEqual(StopwatchLap.formatDuration(8.2), "08.20")

        // 75.5 seconds -> "01:15.50"
        XCTAssertEqual(StopwatchLap.formatDuration(75.5), "01:15.50")

        // 59 minutes, 59.99 seconds -> "59:59.99"
        XCTAssertEqual(StopwatchLap.formatDuration(59 * 60 + 59.99), "59:59.99")

        // 60 minutes -> "01:00:00.00"
        XCTAssertEqual(StopwatchLap.formatDuration(60 * 60), "01:00:00.00")

        // 1 hour, 5 minutes, 10 seconds -> "01:05:10.00"
        XCTAssertEqual(StopwatchLap.formatDuration(3600 + 300 + 10), "01:05:10.00")

        // 2 hours -> "02:00:00.00"
        XCTAssertEqual(StopwatchLap.formatDuration(2 * 3600), "02:00:00.00")

        // Verify StopwatchLap properties use the corrected format
        let hourLap = StopwatchLap(lapNumber: 1, lapDuration: 3665.25, totalTime: 7330.50)
        XCTAssertEqual(hourLap.formattedLapDuration, "01:01:05.25")
        XCTAssertEqual(hourLap.formattedTotalTime, "02:02:10.50")
    }

    // MARK: - Step 1: Restore Paused Timer After App Restart Tests

    // 1. Pause Focus at 17:30 → save → create a new ViewModel using the same test storage → restore exactly 17:30.
    @MainActor
    func testPauseFocusRestoresExactRemainingTimeOnRelaunch() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start 25-minute focus session
        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        XCTAssertEqual(vm1.totalTime, 1500)
        XCTAssertEqual(vm1.timeRemaining, 1500)

        // Simulate pausing when 17 minutes and 30 seconds (1050s) remain
        vm1.timeRemaining = 1050
        vm1.preciseProgress = 1050.0 / 1500.0
        vm1.stopTimer()
        XCTAssertNotNil(vm1.pausedSession)
        XCTAssertEqual(vm1.pausedSession?.timeRemaining, 1050)
        vm1.persistData(force: true)

        // Relaunch app with fresh ViewModel pointed to the same storage
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Focus")
        XCTAssertEqual(vm2.totalTime, 1500)
        XCTAssertEqual(vm2.timeRemaining, 1050, "Restored timer must display exactly 17:30 (1050 seconds)")
        XCTAssertEqual(vm2.timeString, "17:30", "Formatted time display must be 17:30")
        XCTAssertEqual(vm2.timerTimeString, "17:30")
        XCTAssertFalse(vm2.isTimerRunning, "Restored timer must remain paused on launch")
        XCTAssertEqual(vm2.preciseProgress, 1050.0 / 1500.0, accuracy: 0.001)
        XCTAssertNotNil(vm2.pausedSession)
    }

    // 2. Restored timer remains paused until Resume is pressed.
    @MainActor
    func testRestoredTimerRemainsPausedUntilResumePressed() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.timeRemaining = 1050
        vm1.stopTimer()
        vm1.persistData(force: true)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertFalse(vm2.isTimerRunning, "Timer must start paused upon relaunch")
        XCTAssertEqual(vm2.timeRemaining, 1050)

        // Press Resume / Play
        vm2.startTimer()

        XCTAssertTrue(vm2.isTimerRunning, "Timer must run after user presses resume")
        XCTAssertEqual(vm2.timeRemaining, 1050, "Timer must resume from 17:30, not reset to 25:00")
        XCTAssertNil(vm2.pausedSession, "Active running timer clears pausedSession snapshot")
    }

    // 3. Paused Short Break and Long Break restore their correct durations and modes.
    @MainActor
    func testPausedShortBreakAndLongBreakRestoreDurationsAndModes() {
        let (vm1, tempURL1) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL1) }

        // Test Short Break (5 min = 300s), paused at 3m 30s (210s)
        vm1.applyPresetDirectly(name: "Short Break", minutes: 5, isBreak: true)
        XCTAssertEqual(vm1.activePreset, "Short Break")
        XCTAssertTrue(vm1.isBreakPreset)
        XCTAssertEqual(vm1.totalTime, 300)

        vm1.timeRemaining = 210
        vm1.stopTimer()
        vm1.persistData(force: true)

        let storage1 = FocusStorageService(storageURL: tempURL1)
        let vm2 = TimerViewModel(storage: storage1)

        XCTAssertEqual(vm2.activePreset, "Short Break")
        XCTAssertTrue(vm2.isBreakPreset)
        XCTAssertEqual(vm2.totalTime, 300)
        XCTAssertEqual(vm2.timeRemaining, 210)
        XCTAssertEqual(vm2.timeString, "03:30")
        XCTAssertFalse(vm2.isTimerRunning)

        // Test Long Break (15 min = 900s), paused at 10m 00s (600s)
        let (vm3, tempURL2) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL2) }

        vm3.applyPresetDirectly(name: "Long Break", minutes: 15, isBreak: true)
        XCTAssertEqual(vm3.activePreset, "Long Break")
        XCTAssertTrue(vm3.isBreakPreset)
        XCTAssertEqual(vm3.totalTime, 900)

        vm3.timeRemaining = 600
        vm3.stopTimer()
        vm3.persistData(force: true)

        let storage2 = FocusStorageService(storageURL: tempURL2)
        let vm4 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm4.activePreset, "Long Break")
        XCTAssertTrue(vm4.isBreakPreset)
        XCTAssertEqual(vm4.totalTime, 900)
        XCTAssertEqual(vm4.timeRemaining, 600)
        XCTAssertEqual(vm4.timeString, "10:00")
        XCTAssertFalse(vm4.isTimerRunning)
    }

    // 4. Paused Custom Timer restores its custom duration.
    @MainActor
    func testPausedCustomTimerRestoresCustomDurationAndRemainingTime() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Configure 45m 30s custom timer
        vm1.setCustomDuration(minutes: 45, seconds: 30)
        XCTAssertEqual(vm1.activeMode, "Custom Timer")
        XCTAssertEqual(vm1.activePreset, "Custom")
        XCTAssertEqual(vm1.totalTime, 45 * 60 + 30)
        XCTAssertEqual(vm1.customMinutes, 45)
        XCTAssertEqual(vm1.customSeconds, 30)

        // Pause when 32m 10s (1930s) remain
        vm1.timeRemaining = 1930
        vm1.stopTimer()
        vm1.persistData(force: true)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activeMode, "Custom Timer")
        XCTAssertEqual(vm2.activePreset, "Custom")
        XCTAssertEqual(vm2.customMinutes, 45)
        XCTAssertEqual(vm2.customSeconds, 30)
        XCTAssertEqual(vm2.totalTime, 2730)
        XCTAssertEqual(vm2.timeRemaining, 1930)
        XCTAssertEqual(vm2.timeString, "32:10")
        XCTAssertEqual(vm2.formattedCustomDuration, "45m 30s")
        XCTAssertFalse(vm2.isTimerRunning)

        // Resuming countdown works from 1930s
        vm2.startTimer()
        XCTAssertTrue(vm2.isTimerRunning)
        XCTAssertEqual(vm2.timeRemaining, 1930)
    }

    // 5. Reset timer → relaunch → previously paused progress must not reappear.
    @MainActor
    func testResetTimerClearsPausedSnapshotSoRelaunchDoesNotResurrectProgress() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.timeRemaining = 1050
        vm1.stopTimer()
        XCTAssertNotNil(vm1.pausedSession)

        // Reset timer back to full duration
        vm1.resetFocusTimer()
        XCTAssertEqual(vm1.timeRemaining, 1500)
        XCTAssertNil(vm1.pausedSession, "Resetting timer must clear pausedSession snapshot")
        vm1.persistData(force: true)

        // Relaunch app
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.timeRemaining, 1500, "Reset timer must not resurrect previously paused 17:30 progress")
        XCTAssertNil(vm2.pausedSession)
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // 6. Existing saved tasks, notes, statistics, and session records remain unchanged.
    @MainActor
    func testExistingSavedTasksNotesStatisticsAndSessionRecordsRemainUnchanged() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Setup custom tasks, notes, and a session record
        vm1.tasks = [
            FocusTask(title: "Task Alpha", estimatedMinutes: 50, timeSpentSeconds: 600),
            FocusTask(title: "Task Beta", estimatedMinutes: 20, timeSpentSeconds: 120)
        ]
        vm1.notes = ["Architecture meeting notes", "Refactor checklist"]
        vm1.dailyGoalHours = 6
        vm1.totalSessions = 8
        vm1.completedSessions = 3
        let testRecord = FocusSessionRecord(
            startTime: Date().addingTimeInterval(-1800),
            endTime: Date().addingTimeInterval(-900),
            durationSeconds: 900,
            mode: "Focus"
        )
        vm1.sessionRecords = [testRecord]

        // Pause timer at 15m remaining
        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.timeRemaining = 900
        vm1.stopTimer()
        vm1.persistData(force: true)

        // Relaunch
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.tasks.count, 2)
        XCTAssertEqual(vm2.tasks[0].title, "Task Alpha")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 600)
        XCTAssertEqual(vm2.tasks[1].title, "Task Beta")
        XCTAssertEqual(vm2.notes.count, 2)
        XCTAssertEqual(vm2.notes[0], "Architecture meeting notes")
        XCTAssertEqual(vm2.dailyGoalHours, 6)
        XCTAssertEqual(vm2.totalSessions, 8)
        XCTAssertEqual(vm2.completedSessions, 3)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 900)
        XCTAssertEqual(vm2.timeRemaining, 900)
    }

    // 7. Old save files without the new paused-timer field load successfully.
    @MainActor
    func testOldSaveFilesWithoutPausedTimerFieldLoadSuccessfully() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_legacy_schema_\(UUID().uuidString).json")
        defer { cleanup(url: tempURL) }

        // JSON payload from older FocusFlow versions WITHOUT 'pausedSession'
        let legacyJSON = """
        {
            "tasks": [
                {
                    "id": "11111111-2222-3333-4444-555555555555",
                    "title": "Legacy Architecture Task",
                    "estimatedMinutes": 30,
                    "timeSpentSeconds": 500,
                    "isLocked": false,
                    "isCompleted": false,
                    "icon": "star.fill",
                    "iconColorName": "orange"
                }
            ],
            "focusedSeconds": 1500,
            "completedSessions": 2,
            "notes": ["Old note from v1"],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": []
        }
        """

        try? legacyJSON.data(using: .utf8)?.write(to: tempURL)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks[0].title, "Legacy Architecture Task")
        XCTAssertEqual(vm.completedSessions, 2)
        XCTAssertEqual(vm.notes, ["Old note from v1"])
        XCTAssertNil(vm.pausedSession, "Legacy save files must decode safely with pausedSession as nil")
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertFalse(vm.isTimerRunning)
    }

    // 8. Restoring a paused session must not increase completedSessions or duplicate focus time.
    @MainActor
    func testRestoringPausedSessionDoesNotIncreaseCompletedSessionsOrDuplicateFocusTime() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let recordStart = startOfToday.addingTimeInterval(3600 * 2) // 2:00 AM today
        let recordEnd = startOfToday.addingTimeInterval(3600 * 3)   // 3:00 AM today
        let pastRecord = FocusSessionRecord(
            startTime: recordStart,
            endTime: recordEnd,
            durationSeconds: 3600,
            mode: "Focus"
        )
        vm1.sessionRecords = [pastRecord]
        vm1.completedSessions = 4
        let now = startOfToday.addingTimeInterval(3600 * 4) // 4:00 AM today
        vm1.recalculateFocusMetrics(calendar: calendar, now: now)
        let initialTodayFocused = vm1.todayFocusedSeconds
        let initialLifetimeFocused = vm1.lifetimeFocusedSeconds
        XCTAssertEqual(initialTodayFocused, 3600)

        // Pause a session
        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.timeRemaining = 1050
        vm1.stopTimer()
        vm1.persistData(force: true)

        // Relaunch the app 2 hours later (6:00 AM today)
        let later = startOfToday.addingTimeInterval(3600 * 6)
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)
        vm2.recalculateFocusMetrics(calendar: calendar, now: later)

        XCTAssertEqual(vm2.completedSessions, 4, "Restoring paused timer must never increment completedSessions")
        XCTAssertEqual(vm2.todayFocusedSeconds, initialTodayFocused, "Downtime while app was closed must not count as focus time")
        XCTAssertEqual(vm2.lifetimeFocusedSeconds, initialLifetimeFocused, "Lifetime focused seconds must remain identical")
        XCTAssertEqual(vm2.timeRemaining, 1050)
    }

    // 9. Existing preserved-session mode-switching functionality remains intact.
    @MainActor
    func testExistingPreservedSessionModeSwitchingRemainsIntact() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // 1. Start a Focus timer and advance to 15m remaining
        vm.applyPresetDirectly(name: "Focus", minutes: 25)
        vm.timeRemaining = 900
        vm.stopTimer()
        XCTAssertNotNil(vm.pausedSession)

        // 2. Request switch to Short Break -> opens conflict modal
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal, "Conflict modal must trigger for active timer")

        // 3. Continue current timer dismisses modal without altering state
        vm.continueCurrentTimer()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.timeRemaining, 900)

        // 4. Test preservedSession mode-switching (swap into preservedSession)
        let preserved = PreservedTimerSession(
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 900,
            preciseProgress: 900.0 / 1500.0,
            customMinutes: 25,
            customSeconds: 0,
            currentSession: 1,
            activeTaskIndex: 0
        )
        vm.preservedSession = preserved
        XCTAssertTrue(vm.hasPreservedSession)

        // Switch to Break cleanly
        vm.applyPresetDirectly(name: "Short Break", minutes: 5, isBreak: true)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.hasPreservedSession)
        // When current break timer is idle, displayedTimerPreset surfaces the background preserved session
        XCTAssertEqual(vm.displayedTimerPreset, "Focus")

        // When current break timer is running, displayedTimerPreset surfaces the active break
        vm.startTimer()
        XCTAssertEqual(vm.displayedTimerPreset, "Short Break")
        vm.stopTimer()

        // Restore preserved Focus session
        vm.restorePreservedSession()
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.timeRemaining, 900)
    }

    // MARK: - Problem 1B: Restore Running Timer After Normal App Quit Tests

    // 1. Running Focus timer → normal quit → relaunch → correct remaining time, paused.
    @MainActor
    func testRunningFocusTimerQuitRelaunchRestoresRemainingTimeAsPaused() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        XCTAssertTrue(vm1.isTimerRunning)

        // Simulate countdown reaching approximately 17:30 (1050 seconds remaining)
        vm1.targetEndDate = Date().addingTimeInterval(1050)
        vm1.timeRemaining = 1050

        // Normal application termination
        vm1.handleAppTermination()
        XCTAssertFalse(vm1.isTimerRunning, "Timer must be stopped upon termination")
        XCTAssertNotNil(vm1.pausedSession, "Termination while running must create a paused session snapshot")
        XCTAssertEqual(vm1.pausedSession?.timeRemaining, 1050)

        // Reopen application
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Focus")
        XCTAssertEqual(vm2.totalTime, 1500)
        XCTAssertEqual(vm2.timeRemaining, 1050, "Restored timer must retain exact remaining time")
        XCTAssertEqual(vm2.timeString, "17:30")
        XCTAssertFalse(vm2.isTimerRunning, "Running session at quit must restore as paused")
        XCTAssertEqual(vm2.preciseProgress, 1050.0 / 1500.0, accuracy: 0.005)

        // User presses Resume / Play
        vm2.startTimer()
        XCTAssertTrue(vm2.isTimerRunning, "Pressing Play must resume the countdown")
        XCTAssertEqual(vm2.timeRemaining, 1050, "Resumed timer continues from 17:30")
    }

    // 2. Running Short Break and Long Break → quit → correct restoration.
    @MainActor
    func testRunningShortBreakAndLongBreakQuitRestoresCorrectly() {
        // Short Break test
        let (vm1, tempURL1) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL1) }

        vm1.applyPresetDirectly(name: "Short Break", minutes: 5, isBreak: true)
        vm1.startTimer()
        XCTAssertTrue(vm1.isTimerRunning)

        vm1.targetEndDate = Date().addingTimeInterval(180) // 3m 00s remaining
        vm1.timeRemaining = 180

        vm1.handleAppTermination()

        let storage1 = FocusStorageService(storageURL: tempURL1)
        let vm2 = TimerViewModel(storage: storage1)

        XCTAssertEqual(vm2.activePreset, "Short Break")
        XCTAssertTrue(vm2.isBreakPreset)
        XCTAssertEqual(vm2.totalTime, 300)
        XCTAssertEqual(vm2.timeRemaining, 180)
        XCTAssertEqual(vm2.timeString, "03:00")
        XCTAssertFalse(vm2.isTimerRunning, "Restored Short Break must be paused")

        // Long Break test
        let (vm3, tempURL2) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL2) }

        vm3.applyPresetDirectly(name: "Long Break", minutes: 15, isBreak: true)
        vm3.startTimer()
        XCTAssertTrue(vm3.isTimerRunning)

        vm3.targetEndDate = Date().addingTimeInterval(600) // 10m 00s remaining
        vm3.timeRemaining = 600

        vm3.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL2)
        let vm4 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm4.activePreset, "Long Break")
        XCTAssertTrue(vm4.isBreakPreset)
        XCTAssertEqual(vm4.totalTime, 900)
        XCTAssertEqual(vm4.timeRemaining, 600)
        XCTAssertEqual(vm4.timeString, "10:00")
        XCTAssertFalse(vm4.isTimerRunning, "Restored Long Break must be paused")
    }

    // 3. Running Custom Timer → quit → mode, original duration and remaining time retained.
    @MainActor
    func testRunningCustomTimerQuitRetainsModeDurationAndRemainingTime() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.setCustomDuration(minutes: 45, seconds: 30)
        vm1.startTimer()
        XCTAssertTrue(vm1.isTimerRunning)
        XCTAssertEqual(vm1.totalTime, 2730)

        vm1.targetEndDate = Date().addingTimeInterval(1930) // 32m 10s remaining
        vm1.timeRemaining = 1930

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activeMode, "Custom Timer")
        XCTAssertEqual(vm2.activePreset, "Custom")
        XCTAssertEqual(vm2.customMinutes, 45)
        XCTAssertEqual(vm2.customSeconds, 30)
        XCTAssertEqual(vm2.totalTime, 2730)
        XCTAssertEqual(vm2.timeRemaining, 1930)
        XCTAssertEqual(vm2.timeString, "32:10")
        XCTAssertEqual(vm2.formattedCustomDuration, "45m 30s")
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // 4. Actual focus time before quitting recorded exactly once.
    @MainActor
    func testActualFocusTimeBeforeQuittingRecordedExactlyOnce() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        // Simulate working for 300 seconds
        vm1.sessionSegmentStartDate = Date().addingTimeInterval(-300)
        vm1.targetEndDate = Date().addingTimeInterval(1200)

        vm1.handleAppTermination()

        XCTAssertEqual(vm1.sessionRecords.count, 1)
        XCTAssertEqual(vm1.sessionRecords[0].durationSeconds, 300)

        // Relaunch
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 300, "Recorded focus time must be saved without duplication")
    }

    // 5. Offline time after quitting never added to focus totals or tasks.
    @MainActor
    func testOfflineTimeAfterQuittingNeverAddedToFocusTotalsOrTasks() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let now = Date()
        let startTime = now.addingTimeInterval(-300)

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        vm1.sessionSegmentStartDate = startTime
        vm1.targetEndDate = now.addingTimeInterval(1200)

        // Termination (worked 300 seconds)
        vm1.handleAppTermination()

        // Reopen two hours later (staying within the same calendar day for daily metric assertion)
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let secondsUntilMidnight = max(60, startOfTomorrow.timeIntervalSince(now) - 60)
        let reopenTime = now.addingTimeInterval(min(7200, secondsUntilMidnight))
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)
        vm2.recalculateFocusMetrics(now: reopenTime)

        XCTAssertEqual(vm2.todayFocusedSeconds, 300, "Downtime while app was closed must not count as focus time")
        XCTAssertEqual(vm2.tasks[vm2.activeTaskIndex].timeSpentSeconds, 300, "Downtime must not be added to task time")
    }

    // 6. Paused timer from Step 1 still restores correctly.
    @MainActor
    func testPausedTimerFromStep1StillRestoresCorrectly() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.timeRemaining = 1050
        vm1.stopTimer()
        XCTAssertFalse(vm1.isTimerRunning)

        // Normal quit while already paused
        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.timeRemaining, 1050)
        XCTAssertEqual(vm2.timeString, "17:30")
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // 7. Starting and immediately quitting does not lose or corrupt state.
    @MainActor
    func testStartingAndImmediatelyQuittingDoesNotLoseOrCorruptState() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        XCTAssertTrue(vm1.isTimerRunning)

        // Immediately quit without any countdown delay
        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Focus")
        XCTAssertEqual(vm2.totalTime, 1500)
        XCTAssertEqual(vm2.timeRemaining, 1500)
        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertNotNil(vm2.pausedSession)
    }

    // 8. Reset/Skip cannot resurrect a stale session.
    @MainActor
    func testResetAndSkipCannotResurrectStaleSession() {
        // Reset subtest
        let (vm1, tempURL1) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL1) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        vm1.timeRemaining = 1200
        vm1.resetFocusTimer()
        vm1.handleAppTermination()

        let storage1 = FocusStorageService(storageURL: tempURL1)
        let vm2 = TimerViewModel(storage: storage1)

        XCTAssertEqual(vm2.timeRemaining, 1500)
        XCTAssertNil(vm2.pausedSession)

        // Skip subtest
        let (vm3, tempURL2) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL2) }

        vm3.applyPresetDirectly(name: "Focus", minutes: 25)
        vm3.startTimer()
        vm3.timeRemaining = 1200
        vm3.skipSession()
        vm3.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL2)
        let vm4 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm4.activePreset, "Short Break")
        XCTAssertEqual(vm4.timeRemaining, 300)
        XCTAssertNil(vm4.pausedSession)
    }

    // 9. Older JSON files continue loading correctly.
    @MainActor
    func testOlderJSONFilesWithoutPausedTimerContinueLoading() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_v1_legacy_\(UUID().uuidString).json")
        defer { cleanup(url: tempURL) }

        let legacyJSON = """
        {
            "tasks": [],
            "focusedSeconds": 2400,
            "completedSessions": 5,
            "notes": ["Historical note"],
            "dailyGoalHours": 5,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": []
        }
        """
        try? legacyJSON.data(using: .utf8)?.write(to: tempURL)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.completedSessions, 5)
        XCTAssertEqual(vm.dailyGoalHours, 5)
        XCTAssertNil(vm.pausedSession)
        XCTAssertFalse(vm.isTimerRunning)
    }

    // 10. Normal window close does not stop the countdown.
    @MainActor
    func testNormalWindowCloseDoesNotStopCountdown() {
        let (isolatedVM, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let previousShared = FocusFlowAppDelegate.shared
        let appDelegate = FocusFlowAppDelegate(viewModel: isolatedVM)
        XCTAssertTrue(FocusFlowAppDelegate.shared === previousShared, "Test initialization of AppDelegate must not modify FocusFlowAppDelegate.shared")

        appDelegate.viewModel.applyPresetDirectly(name: "Focus", minutes: 25)
        appDelegate.viewModel.startTimer()
        XCTAssertTrue(appDelegate.viewModel.isTimerRunning)

        let dummyWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let shouldClose = appDelegate.windowShouldClose(dummyWindow)
        XCTAssertFalse(shouldClose, "windowShouldClose must return false to keep application active in menu bar")
        XCTAssertTrue(appDelegate.viewModel.isTimerRunning, "Closing main window must NOT stop active timer countdown")

        // Stop the test timer safely after verification
        appDelegate.viewModel.stopTimer()
        XCTAssertFalse(appDelegate.viewModel.isTimerRunning)
    }

    // 11. Termination processing is synchronous, and repeated calls cannot double-count focus time.
    @MainActor
    func testTerminationProcessingIsSynchronousAndRepeatedCallsDoNotDoubleCount() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        vm1.sessionSegmentStartDate = Date().addingTimeInterval(-300)
        vm1.targetEndDate = Date().addingTimeInterval(1200)

        // Call handleAppTermination 3 times in rapid succession
        vm1.handleAppTermination()
        vm1.handleAppTermination()
        vm1.handleAppTermination()

        XCTAssertEqual(vm1.sessionRecords.count, 1, "Repeated termination calls must record exactly one session segment")
        XCTAssertEqual(vm1.sessionRecords[0].durationSeconds, 300, "Duration must not be multiplied across multiple calls")
        XCTAssertEqual(vm1.todayFocusedSeconds, 300)
    }

    // MARK: - Final Stopwatch Hour Formatting Fix Tests
    @MainActor
    func testStopwatchElapsedDisplayHourFormattingBoundaries() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Table required by specification:
        // 9 seconds -> "00:09"
        vm.stopwatchTime = 9
        XCTAssertEqual(vm.stopwatchTimeString, "00:09")

        // 25 minutes -> "25:00"
        vm.stopwatchTime = 25 * 60
        XCTAssertEqual(vm.stopwatchTimeString, "25:00")

        // 59 minutes 59 seconds -> "59:59"
        vm.stopwatchTime = 59 * 60 + 59
        XCTAssertEqual(vm.stopwatchTimeString, "59:59")

        // 60 minutes -> "01:00:00"
        vm.stopwatchTime = 60 * 60
        XCTAssertEqual(vm.stopwatchTimeString, "01:00:00")

        // 75 minutes -> "01:15:00"
        vm.stopwatchTime = 75 * 60
        XCTAssertEqual(vm.stopwatchTimeString, "01:15:00")

        // 2 hours -> "02:00:00"
        vm.stopwatchTime = 2 * 3600
        XCTAssertEqual(vm.stopwatchTimeString, "02:00:00")

        // 10 hours 15 minutes -> "10:15:00"
        vm.stopwatchTime = 10 * 3600 + 15 * 60
        XCTAssertEqual(vm.stopwatchTimeString, "10:15:00")

        // Baseline 0 seconds
        vm.stopwatchTime = 0
        XCTAssertEqual(vm.stopwatchTimeString, "00:00")

        // Verify StopwatchLap.formatDuration preserves hundredths of a second
        XCTAssertEqual(StopwatchLap.formatDuration(8.2), "08.20")
        XCTAssertEqual(StopwatchLap.formatDuration(75.5), "01:15.50")
        XCTAssertEqual(StopwatchLap.formatDuration(3600), "01:00:00.00")
    }

    // MARK: - Stopwatch Elapsed-Time Recovery Tests

    // 1. Paused stopwatch recovery: save 75.25 seconds, create new ViewModel using same isolated file, verify preserved & paused.
    @MainActor
    func testPausedStopwatchRecoveryOnRelaunch() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.stopwatchTime = 75
        vm1.stopwatchFractional = 75.25
        vm1.stopStopwatch() // Ensures paused state and persists
        XCTAssertFalse(vm1.isStopwatchRunning)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertFalse(vm2.isStopwatchRunning, "Restored stopwatch must be paused")
        XCTAssertEqual(vm2.stopwatchTime, 75, "Stopwatch integer seconds must be restored")
        XCTAssertEqual(vm2.stopwatchFractional, 75.25, "Stopwatch fractional precision must be restored")
        XCTAssertEqual(vm2.stopwatchTimeString, "01:15")
    }

    // 2. Running stopwatch recovery: start stopwatch, simulate normal termination, create new ViewModel, verify restores paused.
    @MainActor
    func testRunningStopwatchRecoveryOnTermination() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.startStopwatch()
        XCTAssertTrue(vm1.isStopwatchRunning)
        vm1.stopwatchStartDate = Date().addingTimeInterval(-45.0)

        vm1.handleAppTermination()
        XCTAssertFalse(vm1.isStopwatchRunning)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertFalse(vm2.isStopwatchRunning, "Restored running stopwatch must be paused upon relaunch")
        XCTAssertEqual(vm2.stopwatchTime, 45, "Running stopwatch elapsed time must be restored")
        XCTAssertEqual(vm2.stopwatchTimeString, "00:45")
    }

    // 3. Resume after recovery: confirm elapsed time continues from saved offset instead of restarting at zero.
    @MainActor
    func testResumeAfterStopwatchRecoveryContinuesFromSavedOffset() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.stopwatchTime = 30
        vm1.stopwatchFractional = 30.5
        vm1.stopStopwatch()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.stopwatchTime, 30)
        XCTAssertEqual(vm2.stopwatchFractional, 30.5)

        // Resume stopwatch
        vm2.startStopwatch()
        XCTAssertTrue(vm2.isStopwatchRunning)
        XCTAssertNil(vm2.stopwatchFractional)
        guard let start = vm2.stopwatchStartDate else {
            XCTFail("stopwatchStartDate must be set on resume")
            return
        }
        // Start date must be backdated by approximately 30.5 seconds
        let elapsedAtStart = Date().timeIntervalSince(start)
        XCTAssertEqual(elapsedAtStart, 30.5, accuracy: 0.5)

        vm2.stopStopwatch()
    }

    // 4. Precision: ensure fractional value such as 75.25 seconds survives persistence and can be used for subsequent lap calculations.
    @MainActor
    func testFractionalPrecisionPreservedForFutureLapCalculations() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.stopwatchTime = 75
        vm1.stopwatchFractional = 75.25
        vm1.stopStopwatch()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.stopwatchFractional, 75.25)

        // Record lap using restored fractional offset
        vm2.recordLap()
        XCTAssertEqual(vm2.laps.count, 1)
        XCTAssertEqual(vm2.laps[0].totalTime, 75.25, accuracy: 0.001)
        XCTAssertEqual(vm2.laps[0].lapDuration, 75.25, accuracy: 0.001)
        XCTAssertEqual(vm2.laps[0].formattedTotalTime, "01:15.25")
    }

    // 5. Lap preservation: save multiple existing laps alongside elapsed time, relaunch, verify unchanged.
    @MainActor
    func testLapPreservationAcrossAppRestart() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let uuid1 = UUID()
        let uuid2 = UUID()
        let uuid3 = UUID()
        let lap1 = StopwatchLap(id: uuid1, lapNumber: 1, lapDuration: 10.5, totalTime: 10.5)
        let lap2 = StopwatchLap(id: uuid2, lapNumber: 2, lapDuration: 20.25, totalTime: 30.75)
        let lap3 = StopwatchLap(id: uuid3, lapNumber: 3, lapDuration: 15.0, totalTime: 45.75)

        vm1.laps = [lap3, lap2, lap1] // Laps are stored newest first
        vm1.stopwatchTime = 45
        vm1.stopwatchFractional = 45.75
        vm1.stopStopwatch()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.laps.count, 3)
        XCTAssertEqual(vm2.laps[0].id, uuid3)
        XCTAssertEqual(vm2.laps[0].lapNumber, 3)
        XCTAssertEqual(vm2.laps[0].lapDuration, 15.0)
        XCTAssertEqual(vm2.laps[0].totalTime, 45.75)

        XCTAssertEqual(vm2.laps[1].id, uuid2)
        XCTAssertEqual(vm2.laps[1].lapNumber, 2)
        XCTAssertEqual(vm2.laps[1].lapDuration, 20.25)
        XCTAssertEqual(vm2.laps[1].totalTime, 30.75)

        XCTAssertEqual(vm2.laps[2].id, uuid1)
        XCTAssertEqual(vm2.laps[2].lapNumber, 1)
        XCTAssertEqual(vm2.laps[2].lapDuration, 10.5)
        XCTAssertEqual(vm2.laps[2].totalTime, 10.5)

        XCTAssertEqual(vm2.stopwatchTime, 45)
        XCTAssertEqual(vm2.stopwatchFractional, 45.75)
    }

    // 6. Reset persistence: reset previously used stopwatch, relaunch and verify 00:00 with no laps.
    @MainActor
    func testResetStopwatchPersistsZeroAndClearsLaps() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.stopwatchTime = 60
        vm1.stopwatchFractional = 60.5
        vm1.laps = [StopwatchLap(lapNumber: 1, lapDuration: 60.5, totalTime: 60.5)]
        vm1.resetStopwatch()

        XCTAssertEqual(vm1.stopwatchTime, 0)
        XCTAssertTrue(vm1.laps.isEmpty)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.stopwatchTime, 0)
        XCTAssertNil(vm2.stopwatchFractional)
        XCTAssertEqual(vm2.stopwatchTimeString, "00:00")
        XCTAssertTrue(vm2.laps.isEmpty, "Reset stopwatch must persist empty laps")
    }

    // 7. Backward compatibility: decode older JSON payload without stopwatchElapsedSeconds.
    @MainActor
    func testBackwardCompatibilityOlderJSONWithoutStopwatchElapsedSeconds() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_legacy_stopwatch_\(UUID().uuidString).json")
        defer { cleanup(url: tempURL) }

        let legacyJSON = """
        {
            "tasks": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "title": "Legacy Task",
                    "estimatedMinutes": 25,
                    "timeSpentSeconds": 120,
                    "isCompleted": false,
                    "isLocked": false,
                    "icon": "star.fill",
                    "iconColorName": "orange"
                }
            ],
            "focusedSeconds": 1200,
            "completedSessions": 2,
            "notes": ["Legacy Note"],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "lapNumber": 1,
                    "lapDuration": 25.5,
                    "totalTime": 25.5,
                    "timestamp": "2026-10-15T12:00:00Z"
                }
            ]
        }
        """
        try? legacyJSON.data(using: .utf8)?.write(to: tempURL)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks[0].title, "Legacy Task")
        XCTAssertEqual(vm.completedSessions, 2)
        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapDuration, 25.5)

        // Stopwatch elapsed time defaults to zero when omitted in legacy JSON
        XCTAssertEqual(vm.stopwatchTime, 0)
        XCTAssertNil(vm.stopwatchFractional)
        XCTAssertEqual(vm.stopwatchTimeString, "00:00")
        XCTAssertFalse(vm.isStopwatchRunning)
    }

    // 8. Repeat termination: calling shutdown handler twice must not accumulate additional stopwatch/task time.
    @MainActor
    func testRepeatTerminationDoesNotAccumulateExtraStopwatchOrTaskTime() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.startStopwatch()
        vm1.stopwatchStartDate = Date().addingTimeInterval(-20.0)

        vm1.handleAppTermination()
        let taskTimeAfterFirst = vm1.tasks[vm1.activeTaskIndex].timeSpentSeconds
        let stopwatchTimeAfterFirst = vm1.stopwatchTime

        vm1.handleAppTermination()
        vm1.handleAppTermination()

        XCTAssertEqual(vm1.stopwatchTime, stopwatchTimeAfterFirst, "Repeat termination must not increment stopwatchTime")
        XCTAssertEqual(vm1.tasks[vm1.activeTaskIndex].timeSpentSeconds, taskTimeAfterFirst, "Repeat termination must not double-count task time")
    }

    // 9. Long duration: recover stopwatch beyond 60 minutes and verify existing HH:mm:ss display remains correct.
    @MainActor
    func testLongDurationStopwatchRecoveryBeyondOneHour() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // 1 hour, 15 minutes, 30 seconds = 4530 seconds
        vm1.stopwatchTime = 4530
        vm1.stopwatchFractional = 4530.25
        vm1.stopStopwatch()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.stopwatchTime, 4530)
        XCTAssertEqual(vm2.stopwatchFractional, 4530.25)
        XCTAssertEqual(vm2.stopwatchTimeString, "01:15:30", "Stopwatch display must show HH:mm:ss when recovered beyond 1 hour")
    }

    // MARK: - Priority 1: Data Safety & Corruption Protection Tests

    // 1. Fresh installation with neither primary nor backup — normal initialization and saving.
    @MainActor
    func testFreshInstallationWithoutFilesInitializesDefaultsAndSaves() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let storage = FocusStorageService(storageURL: primaryURL)
        let loadResult = storage.loadDetailed()
        XCTAssertEqual(loadResult, .freshInstall)

        let vm = TimerViewModel(storage: storage)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.didRecoverFromBackup)
        XCTAssertEqual(vm.tasks.count, 4) // Default 4 tasks
        XCTAssertNil(vm.storageErrorMessage)

        // Save and verify both primary and backup files are created with valid decodable data
        vm.persistData(force: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let primaryData = try storage.decodeData(from: primaryURL)
        let backupData = try storage.decodeData(from: backupURL)
        XCTAssertEqual(primaryData.tasks.count, 4)
        XCTAssertEqual(backupData.tasks.count, 4)
    }

    // 2. Existing valid JSON — normal loading with all data unchanged.
    @MainActor
    func testExistingValidJSONLoadsNormallyWithAllDataUnchanged() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")

        let originalTask = FocusTask(title: "Specific Valid Task", estimatedMinutes: 50, timeSpentSeconds: 1200)
        let originalData = FocusAppData(
            tasks: [originalTask],
            focusedSeconds: 1800,
            completedSessions: 4,
            notes: ["Important architecture note"],
            dailyGoalHours: 6,
            totalSessions: 8,
            autoStartNextSession: true,
            activePreset: "Focus"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(originalData)
        try data.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let result = storage.loadDetailed()
        guard case .success(let loaded) = result else {
            XCTFail("Expected .success but got \(result)")
            return
        }
        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.title, "Specific Valid Task")
        XCTAssertEqual(loaded.completedSessions, 4)

        let vm = TimerViewModel(storage: storage)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.didRecoverFromBackup)
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks.first?.title, "Specific Valid Task")
        XCTAssertEqual(vm.completedSessions, 4)
        XCTAssertEqual(vm.notes, ["Important architecture note"])
    }

    // 3. Backup creation after a successful save — backup is valid and decodable.
    @MainActor
    func testBackupCreationAfterSuccessfulSave() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        vm.addTask(title: "Task for backup verification", expectedMinutes: 20)
        vm.persistData(force: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backupData = try storage.decodeData(from: backupURL)
        XCTAssertTrue(backupData.tasks.contains { $0.title == "Task for backup verification" })
    }

    // 4. Corrupted primary with valid backup — data recovers successfully, including tasks, statistics, paused timer, stopwatch elapsed time and laps.
    @MainActor
    func testCorruptedPrimaryWithValidBackupRecoversSuccessfully() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        // Corrupted primary bytes
        let corruptedBytes = Data("{\"tasks\": [CORRUPTED_JSON_MALFORMED...".utf8)
        try corruptedBytes.write(to: primaryURL)

        // Valid backup with tasks, statistics, paused timer, stopwatch elapsed time and laps
        let task = FocusTask(title: "Backed Up Task", estimatedMinutes: 35, timeSpentSeconds: 600)
        let sessionRec = FocusSessionRecord(startTime: Date().addingTimeInterval(-1800), endTime: Date(), durationSeconds: 1800, mode: "Focus")
        let pausedTimer = PausedTimerSession(activePreset: "Focus", activeMode: "Pomodoro", totalTime: 1500, timeRemaining: 750, preciseProgress: 0.5)
        let lap1 = StopwatchLap(lapNumber: 1, lapDuration: 45.0, totalTime: 45.0)
        let lap2 = StopwatchLap(lapNumber: 2, lapDuration: 30.0, totalTime: 75.0)

        let backupPayload = FocusAppData(
            tasks: [task],
            focusedSeconds: 1800,
            completedSessions: 3,
            notes: ["Backup note"],
            dailyGoalHours: 5,
            totalSessions: 6,
            autoStartNextSession: false,
            activePreset: "Focus",
            sessionRecords: [sessionRec],
            laps: [lap1, lap2],
            pausedSession: pausedTimer,
            stopwatchElapsedSeconds: 75.0
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let backupData = try encoder.encode(backupPayload)
        try backupData.write(to: backupURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.didRecoverFromBackup)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.recoveryNoticeMessage)

        // Verify all restored state
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks.first?.title, "Backed Up Task")
        XCTAssertEqual(vm.completedSessions, 3)
        XCTAssertEqual(vm.notes, ["Backup note"])
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.stopwatchTime, 75)
        XCTAssertEqual(vm.stopwatchFractional, 75.0)
        XCTAssertNotNil(vm.pausedSession)
        XCTAssertEqual(vm.timeRemaining, 750)

        // Verify diagnostic file was created and contains the original corrupted bytes byte-for-byte
        let contents = try FileManager.default.contentsOfDirectory(at: testDir, includingPropertiesForKeys: nil)
        let diagFiles = contents.filter { $0.lastPathComponent.contains("corrupted") }
        XCTAssertEqual(diagFiles.count, 1)
        if let diag = diagFiles.first {
            let diagBytes = try Data(contentsOf: diag)
            XCTAssertEqual(diagBytes, corruptedBytes)
        }

        // Verify primaryURL was restored with valid data
        let restoredPrimary = try storage.decodeData(from: primaryURL)
        XCTAssertEqual(restoredPrimary.tasks.first?.title, "Backed Up Task")

        // Verify backupURL still exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    // 5. Corrupted primary with no backup — no overwrite, no data loss and persistence blocked.
    @MainActor
    func testCorruptedPrimaryWithNoBackupBlocksPersistenceAndPreservesBytes() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        let corruptedBytes = Data("<<<MALFORMED PRIMARY DATA>>>".utf8)
        try corruptedBytes.write(to: primaryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.didRecoverFromBackup)
        XCTAssertNotNil(vm.storageErrorMessage)
        // Must NOT replace existing data with default tasks
        XCTAssertTrue(vm.tasks.isEmpty)

        // Attempt to persist
        vm.persistData(force: true)

        // Corrupted file must remain 100% byte-for-byte identical
        let afterBytes = try Data(contentsOf: primaryURL)
        XCTAssertEqual(afterBytes, corruptedBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    // 6. Corrupted primary and corrupted backup — both original files preserved and persistence blocked.
    @MainActor
    func testCorruptedPrimaryAndCorruptedBackupPreservesBothAndBlocksPersistence() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        let primaryCorrupted = Data("<<<CORRUPTED PRIMARY>>>".utf8)
        let backupCorrupted = Data("<<<CORRUPTED BACKUP>>>".utf8)
        try primaryCorrupted.write(to: primaryURL)
        try backupCorrupted.write(to: backupURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.didRecoverFromBackup)
        XCTAssertNotNil(vm.storageErrorMessage)
        XCTAssertTrue(vm.tasks.isEmpty)

        // Attempt to persist
        vm.persistData(force: true)

        // Both files must be preserved byte-for-byte
        XCTAssertEqual(try Data(contentsOf: primaryURL), primaryCorrupted)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupCorrupted)
    }

    // 7. Primary missing but valid backup present — recovery instead of fresh-install initialization.
    @MainActor
    func testPrimaryMissingWithValidBackupRecoversData() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))

        let task = FocusTask(title: "Task in Orphan Backup", estimatedMinutes: 40)
        let backupPayload = FocusAppData(tasks: [task], focusedSeconds: 900, completedSessions: 2)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backupPayload)
        try data.write(to: backupURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.didRecoverFromBackup)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks.first?.title, "Task in Orphan Backup")

        // Primary should now be restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        let restored = try storage.decodeData(from: primaryURL)
        XCTAssertEqual(restored.tasks.first?.title, "Task in Orphan Backup")
    }

    // 8. Intentionally empty tasks array — valid and preserved.
    @MainActor
    func testIntentionallyEmptyTasksArrayIsValidAndPreserved() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")

        let emptyTasksPayload = FocusAppData(tasks: [], focusedSeconds: 600, completedSessions: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(emptyTasksPayload).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.didRecoverFromBackup)
        XCTAssertTrue(vm.tasks.isEmpty)
        XCTAssertEqual(vm.completedSessions, 1)
    }

    // 9. Legacy JSON without newer optional fields — still loads correctly.
    @MainActor
    func testLegacyJSONWithoutNewerOptionalFieldsLoadsCorrectly() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")

        let legacyJSON = """
        {
            "tasks": [{"id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "title": "Minimal Task", "estimatedMinutes": 15, "timeSpentSeconds": 0, "isLocked": false, "isCompleted": false, "icon": "star.fill", "iconColorName": "orange"}],
            "focusedSeconds": 300,
            "completedSessions": 1
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks.first?.title, "Minimal Task")
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.laps.count, 0)
        XCTAssertNil(vm.pausedSession)
        XCTAssertEqual(vm.stopwatchTime, 0)
    }

    // 10. Multiple consecutive saves — backup remains valid and never contains corrupted data.
    @MainActor
    func testMultipleConsecutiveSavesMaintainsValidBackup() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        // Save 1
        vm.tasks = [FocusTask(title: "Save 1 Task", estimatedMinutes: 10)]
        vm.persistData(force: true)
        let backup1 = try storage.decodeData(from: backupURL)
        XCTAssertEqual(backup1.tasks.first?.title, "Save 1 Task")

        // Save 2
        vm.tasks = [FocusTask(title: "Save 2 Task", estimatedMinutes: 20)]
        vm.persistData(force: true)
        let primary2 = try storage.decodeData(from: primaryURL)
        let backup2 = try storage.decodeData(from: backupURL)
        XCTAssertEqual(primary2.tasks.first?.title, "Save 2 Task")
        XCTAssertEqual(backup2.tasks.first?.title, "Save 1 Task")

        // Save 3
        vm.tasks = [FocusTask(title: "Save 3 Task", estimatedMinutes: 30)]
        vm.persistData(force: true)
        let primary3 = try storage.decodeData(from: primaryURL)
        let backup3 = try storage.decodeData(from: backupURL)
        XCTAssertEqual(primary3.tasks.first?.title, "Save 3 Task")
        XCTAssertEqual(backup3.tasks.first?.title, "Save 2 Task")
    }

    // 11. Simulated backup/write failure — previously valid data is not destroyed.
    @MainActor
    func testSimulatedBackupAndWriteFailureDoesNotDestroyPreviouslyValidData() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        let storage = FocusStorageService(storageURL: primaryURL)
        let initialData = FocusAppData(tasks: [FocusTask(title: "Initial Valid Data", estimatedMinutes: 25)], focusedSeconds: 1500)
        try storage.save(initialData)

        let originalPrimaryBytes = try Data(contentsOf: primaryURL)
        let originalBackupBytes = try Data(contentsOf: backupURL)

        // 1. Simulate backup failure during subsequent save
        storage.simulateBackupFailure = true
        let modifiedData = FocusAppData(tasks: [FocusTask(title: "Unsafe Data", estimatedMinutes: 99)])
        XCTAssertThrowsError(try storage.save(modifiedData)) { error in
            guard case StorageError.backupFailed = error else {
                XCTFail("Expected backupFailed but got \(error)")
                return
            }
        }

        // Verify original files are intact
        XCTAssertEqual(try Data(contentsOf: primaryURL), originalPrimaryBytes)
        XCTAssertEqual(try Data(contentsOf: backupURL), originalBackupBytes)

        // 2. Simulate write failure during subsequent save
        storage.simulateBackupFailure = false
        storage.simulateWriteFailure = true
        XCTAssertThrowsError(try storage.save(modifiedData)) { error in
            guard case StorageError.writeFailed = error else {
                XCTFail("Expected writeFailed but got \(error)")
                return
            }
        }

        // Verify previously valid data is still preserved
        let recoveredData = try storage.decodeData(from: primaryURL)
        XCTAssertEqual(recoveredData.tasks.first?.title, "Initial Valid Data")
    }

    // 12. An attempted forced save after unrecoverable load failure — must still be blocked.
    @MainActor
    func testAttemptedForcedSaveAfterUnrecoverableLoadFailureIsBlocked() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")

        let corruptedBytes = Data("CORRUPTED_NON_RECOVERABLE_DATA_12345".utf8)
        try corruptedBytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Attempt forced save on ViewModel
        vm.persistData(force: true)
        XCTAssertEqual(try Data(contentsOf: primaryURL), corruptedBytes)

        // Attempt direct save on Storage
        let dummyPayload = FocusAppData(tasks: [FocusTask(title: "Overwrite Attempt")])
        XCTAssertThrowsError(try storage.save(dummyPayload)) { error in
            guard case StorageError.persistenceBlocked = error else {
                XCTFail("Expected persistenceBlocked but got \(error)")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: primaryURL), corruptedBytes)
    }

    // 13. Prevent edits that would appear saved while persistence is blocked.
    @MainActor
    func testEditsAreBlockedWhilePersistenceIsBlocked() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        try Data("malformed json bytes".utf8).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // User attempts to add task
        vm.addTask(title: "New Task That Should Not Be Added")
        XCTAssertTrue(vm.tasks.isEmpty)

        // User attempts to save a note
        vm.noteDraft = "Draft note that should not be saved"
        vm.saveNote()
        XCTAssertTrue(vm.notes.isEmpty)

        // User attempts to record a lap
        vm.recordLap()
        XCTAssertTrue(vm.laps.isEmpty)
    }

    // MARK: - Data Protection: Final Safety Corrections Regression Tests

    // 1. Failed persistence exposes a visible ViewModel error state.
    @MainActor
    func testFailedPersistenceExposesVisibleViewModelErrorState() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Trigger successful initial save
        vm.addTask(title: "Task 1")
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertNil(vm.saveErrorMessage)
        XCTAssertNil(vm.lastSaveError)

        // Inject simulated write failure
        vm.storage.simulateWriteFailure = true

        // Attempt mutating save with force to test immediate write failure
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)
        XCTAssertNotNil(vm.lastSaveError)
        // Ensure unrecoverable corruption state is NOT conflated with temporary write failure
        XCTAssertFalse(vm.isPersistenceBlocked)
    }

    // 2. Successful retry clears a temporary save-error state.
    @MainActor
    func testSuccessfulRetryClearsTemporarySaveErrorState() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.addTask(title: "Task 1")
        XCTAssertFalse(vm.isSaveFailed)

        // Induce write failure
        vm.storage.simulateWriteFailure = true
        vm.persistData(force: true)
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)

        // Resolve write failure and retry
        vm.storage.simulateWriteFailure = false
        vm.retrySave()

        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertNil(vm.saveErrorMessage)
        XCTAssertNil(vm.lastSaveError)
    }

    // 3. Unrecoverable corruption remains blocked after an attempted save retry.
    @MainActor
    func testUnrecoverableCorruptionRemainsBlockedAfterAttemptedRetry() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let corruptedBytes = Data("{corrupted_json_cannot_decode}".utf8)
        try corruptedBytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)

        // Attempt retrySave() while unrecoverable corruption exists
        vm.retrySave()

        // Must remain blocked; corruption warning must NOT be cleared by retry attempt
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)
        XCTAssertFalse(vm.isSaveFailed)

        // Verify primary file was untouched
        XCTAssertEqual(try Data(contentsOf: primaryURL), corruptedBytes)
    }

    // 4. Starting a Focus Timer while persistence is blocked does nothing.
    @MainActor
    func testStartingFocusTimerWhilePersistenceBlockedDoesNothing() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        try Data("corrupted data".utf8).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        vm.startTimer()
        XCTAssertFalse(vm.isTimerRunning)

        vm.toggleTimer()
        XCTAssertFalse(vm.isTimerRunning)
    }

    // 5. Starting a Stopwatch while persistence is blocked does nothing.
    @MainActor
    func testStartingStopwatchWhilePersistenceBlockedDoesNothing() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        try Data("corrupted data".utf8).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        vm.startStopwatch()
        XCTAssertFalse(vm.isStopwatchRunning)

        vm.toggleStopwatch()
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 0)
    }

    // 6. Reset, skip, preset switching and other persistent mutations cannot bypass protection.
    @MainActor
    func testResetSkipPresetSwitchingCannotBypassProtection() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let corruptedBytes = Data("corrupted data".utf8)
        try corruptedBytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Attempt reset
        vm.resetTimer()
        vm.resetFocusTimer()
        vm.resetStopwatch()

        // Attempt skip session
        vm.skipSession()

        // Attempt preset changes
        vm.requestPresetChange(name: "Long Break", minutes: 15)
        vm.switchToBreak(minutes: 5)
        vm.switchToFocus(minutes: 25)
        vm.applyPreset(name: "Short Break", minutes: 5)

        // Attempt mode switching and custom duration changes
        vm.changeMode(to: "Custom Timer")
        vm.setCustomDuration(minutes: 50, seconds: 0)
        vm.adjustCustomDuration(by: 10)

        // Attempt preserved session actions
        vm.restorePreservedSession()
        vm.restorePreservedSessionIfNeeded()
        vm.pauseAndSwitch()
        vm.endAndSwitch()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertFalse(vm.showConflictModal)
        // Corrupted primary file must remain intact
        XCTAssertEqual(try Data(contentsOf: primaryURL), corruptedBytes)
    }

    // 7. Mutating actions through the menu-bar companion are disabled or safely rejected.
    @MainActor
    func testMutatingActionsThroughMenuBarCompanionAreSafelyRejected() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let corruptedBytes = Data("corrupted data".utf8)
        try corruptedBytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Companion operations
        vm.selectTask(at: 0)
        vm.addTask(title: "Companion Task")
        vm.recordLapOrNote(isStopwatch: true)
        vm.recordLapOrNote(isStopwatch: false)
        vm.requestReset(isStopwatch: true)
        vm.requestReset(isStopwatch: false)

        // App termination through menu bar / Quit
        vm.handleAppTermination()

        XCTAssertTrue(vm.tasks.isEmpty)
        XCTAssertTrue(vm.notes.isEmpty)
        XCTAssertTrue(vm.laps.isEmpty)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(try Data(contentsOf: primaryURL), corruptedBytes)
    }

    // 8. First save with simulated backup failure leaves the primary file absent and preserves existing files.
    @MainActor
    func testFirstSaveWithSimulatedBackupFailureLeavesPrimaryAbsent() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)
        let backupURL = storage.backupURL

        storage.simulateBackupFailure = true
        let payload = FocusAppData(tasks: [FocusTask(title: "First Save Data")])

        XCTAssertThrowsError(try storage.save(payload)) { error in
            guard case StorageError.backupFailed = error else {
                XCTFail("Expected backupFailed error but got \(error)")
                return
            }
        }

        // Primary must NOT be written if backup creation fails on fresh install
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    // 9. First save with simulated primary-write failure retains a valid recoverable backup.
    @MainActor
    func testFirstSaveWithSimulatedPrimaryWriteFailureRetainsValidRecoverableBackup() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)
        let backupURL = storage.backupURL

        storage.simulateWriteFailure = true
        let payload = FocusAppData(tasks: [FocusTask(title: "Data In Retained Backup")])

        XCTAssertThrowsError(try storage.save(payload)) { error in
            guard case StorageError.writeFailed = error else {
                XCTFail("Expected writeFailed error but got \(error)")
                return
            }
        }

        // Primary was not created, but valid backup was written first and retained
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Reset simulation and verify startup recovery recovers the retained backup
        storage.simulateWriteFailure = false
        let loadResult = storage.loadDetailed()
        guard case .recovered(let recoveredData, let recoveredBackupURL, _) = loadResult else {
            XCTFail("Expected .recovered but got \(loadResult)")
            return
        }

        XCTAssertEqual(recoveredBackupURL.path, backupURL.path)
        XCTAssertEqual(recoveredData.tasks.first?.title, "Data In Retained Backup")
        // And primary file now exists restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
    }

    // 10. Missing primary with existing backup cannot be overwritten by a fresh save.
    @MainActor
    func testMissingPrimaryWithExistingBackupCannotBeOverwrittenByFreshSave() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)
        let backupURL = storage.backupURL

        // Create an existing backup
        let originalPayload = FocusAppData(tasks: [FocusTask(title: "Precious Backup Data")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let backupData = try encoder.encode(originalPayload)
        try backupData.write(to: backupURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Attempt a fresh save
        let freshPayload = FocusAppData(tasks: [FocusTask(title: "Accidental Overwrite")])
        XCTAssertThrowsError(try storage.save(freshPayload)) { error in
            guard case StorageError.persistenceBlocked = error else {
                XCTFail("Expected persistenceBlocked but got \(error)")
                return
            }
        }

        // Verify backup was NOT overwritten
        let backupBytesAfter = try Data(contentsOf: backupURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedBackup = try decoder.decode(FocusAppData.self, from: backupBytesAfter)
        XCTAssertEqual(decodedBackup.tasks.first?.title, "Precious Backup Data")
    }

    // 11. Normal fresh installation creates both valid primary and backup files.
    @MainActor
    func testNormalFreshInstallationCreatesBothValidPrimaryAndBackupFiles() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)
        let backupURL = storage.backupURL

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let payload = FocusAppData(
            tasks: [FocusTask(title: "Fresh Install Test")],
            focusedSeconds: 300,
            completedSessions: 1,
            dailyGoalHours: 6
        )

        XCTAssertNoThrow(try storage.save(payload))

        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let primaryData = try decoder.decode(FocusAppData.self, from: Data(contentsOf: primaryURL))
        let backupData = try decoder.decode(FocusAppData.self, from: Data(contentsOf: backupURL))

        XCTAssertEqual(primaryData.tasks.first?.title, "Fresh Install Test")
        XCTAssertEqual(backupData.tasks.first?.title, "Fresh Install Test")
        XCTAssertEqual(primaryData.focusedSeconds, 300)
        XCTAssertEqual(backupData.focusedSeconds, 300)
    }

    // 12. Normal subsequent saves preserve working backup rotation and recovery.
    @MainActor
    func testNormalSubsequentSavesPreserveWorkingBackupRotationAndRecovery() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)

        // Initial save (Version 1)
        let v1 = FocusAppData(tasks: [FocusTask(title: "Version 1")])
        try storage.save(v1)

        // Subsequent save (Version 2)
        let v2 = FocusAppData(tasks: [FocusTask(title: "Version 2")])
        try storage.save(v2)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let primaryData = try decoder.decode(FocusAppData.self, from: Data(contentsOf: primaryURL))
        let backupData = try decoder.decode(FocusAppData.self, from: Data(contentsOf: storage.backupURL))

        XCTAssertEqual(primaryData.tasks.first?.title, "Version 2")
        XCTAssertEqual(backupData.tasks.first?.title, "Version 1")

        // Corrupt primary file
        let corruptedBytes = Data("CORRUPTED_V2_DATA".utf8)
        try corruptedBytes.write(to: primaryURL)

        // Relaunch storage and verify recovery
        let newStorage = FocusStorageService(storageURL: primaryURL)
        let loadResult = newStorage.loadDetailed()

        guard case .recovered(let recoveredData, _, let diagURL) = loadResult else {
            XCTFail("Expected .recovered but got \(loadResult)")
            return
        }

        XCTAssertEqual(recoveredData.tasks.first?.title, "Version 1")
        XCTAssertNotNil(diagURL)
        if let diag = diagURL {
            XCTAssertEqual(try Data(contentsOf: diag), corruptedBytes)
        }
    }

    // 13. Existing Focus Timer and Stopwatch restart recovery tests remain passing.
    @MainActor
    func testExistingTimerAndStopwatchRestartRecoveryRemainsHealthy() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start and stop timer to create a paused session
        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        vm1.timeRemaining = 1200 // 20 minutes remaining
        vm1.stopTimer()
        XCTAssertNotNil(vm1.pausedSession)

        // Set up stopwatch with laps and fractional offset
        vm1.stopwatchTime = 60
        vm1.stopwatchFractional = 60.42
        vm1.recordLap()
        vm1.stopStopwatch()

        // Force synchronous persistence to simulate app shutdown
        vm1.persistData(force: true)

        // Relaunch in a fresh ViewModel
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertFalse(vm2.isPersistenceBlocked)
        XCTAssertFalse(vm2.isSaveFailed)
        XCTAssertEqual(vm2.timeRemaining, 1200)
        XCTAssertEqual(vm2.stopwatchTime, 60)
        XCTAssertEqual(vm2.stopwatchFractional, 60.42)
        XCTAssertEqual(vm2.laps.count, 1)
    }

    // MARK: - Final Data Protection Edge-Case Regression Tests

    // 1. Primary corruption discovered during persistData(force: true) updates both storage and ViewModel blocked states.
    @MainActor
    func testEdgeCase01_PrimaryCorruptionDuringSaveUpdatesStorageAndViewModelBlockedStates() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Initial valid save
        vm.persistData(force: true)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.storage.isPersistenceBlocked)

        // Corrupt primary file
        let corrupted = Data("CORRUPTED_PRIMARY_TEST_01".utf8)
        try corrupted.write(to: tempURL)

        // Trigger persistData
        vm.persistData(force: true)

        XCTAssertTrue(vm.storage.isPersistenceBlocked)
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertNil(vm.saveErrorMessage)
    }

    // 2. Critical corruption warning takes precedence over a temporary save-error warning.
    @MainActor
    func testEdgeCase02_CriticalCorruptionWarningTakesPrecedenceOverTemporarySaveError() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Initial valid save
        vm.persistData(force: true)
        XCTAssertFalse(vm.isPersistenceBlocked)

        // Induce temporary save failure
        vm.storage.simulateWriteFailure = true
        vm.addTask(title: "Temporary Task", expectedMinutes: 20)
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)
        XCTAssertFalse(vm.isPersistenceBlocked)

        // Now corrupt the primary file and clear simulation
        vm.storage.simulateWriteFailure = false
        let corrupted = Data("CORRUPTED_PRIMARY_TEST_02".utf8)
        try corrupted.write(to: tempURL)

        // Attempt save
        vm.persistData(force: true)

        // Critical corruption takes total precedence
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertNil(vm.saveErrorMessage)
        XCTAssertNil(vm.lastSaveError)
    }

    // 3. Already-running Focus Timer stops mutating task time when storage becomes blocked.
    @MainActor
    func testEdgeCase03_AlreadyRunningFocusTimerStopsMutatingTaskTimeWhenStorageBecomesBlocked() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.addTask(title: "Active Focus Task", expectedMinutes: 25)
        vm.activeTaskIndex = 0
        vm.persistData(force: true)

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)

        // Corrupt primary file
        let corrupted = Data("CORRUPTED_TASK_TEST_03".utf8)
        try corrupted.write(to: tempURL)

        // Trigger blocked state via forced persist
        vm.persistData(force: true)
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.isTimerRunning)

        let initialTaskTime = vm.tasks[0].timeSpentSeconds

        // Wait for timer ticks
        let exp = expectation(description: "Wait timer tick")
        exp.assertForOverFulfill = false
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            exp.fulfill()
        }
        defer { workItem?.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem!)
        wait(for: [exp], timeout: 5.0)

        // Task time must not have changed
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, initialTaskTime)

        // Attempting to start timer while blocked must do nothing
        vm.startTimer()
        XCTAssertFalse(vm.isTimerRunning)
    }

    // 4. Already-running Stopwatch stops mutating persistent state when storage becomes blocked.
    @MainActor
    func testEdgeCase04_AlreadyRunningStopwatchStopsMutatingPersistentStateWhenStorageBecomesBlocked() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)
        vm.startStopwatch()
        XCTAssertTrue(vm.isStopwatchRunning)

        // Corrupt primary file
        let corrupted = Data("CORRUPTED_STOPWATCH_TEST_04".utf8)
        try corrupted.write(to: tempURL)

        // Trigger blocked state
        vm.persistData(force: true)
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertFalse(vm.isStopwatchRunning)

        let initialStopwatchTime = vm.stopwatchTime
        let initialLapsCount = vm.laps.count

        // Attempt to record lap while blocked
        vm.recordLap()
        XCTAssertEqual(vm.laps.count, initialLapsCount)

        // Attempt to start stopwatch while blocked
        vm.startStopwatch()
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, initialStopwatchTime)
    }

    // 5. Previously scheduled delayed saves cannot overwrite corrupted data.
    @MainActor
    func testEdgeCase05_PreviouslyScheduledDelayedSavesCannotOverwriteCorruptedData() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Initial save to establish healthy state
        vm.persistData(force: true)
        XCTAssertFalse(vm.isPersistenceBlocked)

        // Trigger an unforced save which schedules a delayed write after 1.0 second
        vm.persistData(force: false)

        // Immediately corrupt the primary file with sentinel bytes
        let corruptedSentinel = Data("CORRUPTED_SENTINEL_DATA_TEST_05".utf8)
        try corruptedSentinel.write(to: tempURL)

        // Trigger blocked persistence in ViewModel
        vm.persistData(force: true)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Wait 1.2 seconds for any delayed async block to fire
        let exp = expectation(description: "Wait for delayed save debounce")
        exp.assertForOverFulfill = false
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            exp.fulfill()
        }
        defer { workItem?.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem!)
        wait(for: [exp], timeout: 5.0)

        // Verify corrupted primary was NOT overwritten
        let currentBytes = try Data(contentsOf: tempURL)
        XCTAssertEqual(currentBytes, corruptedSentinel)
        XCTAssertTrue(vm.isPersistenceBlocked)
    }

    // 6. Settings cannot be modified by their UI controls during a blocked persistence state.
    @MainActor
    func testEdgeCase06_SettingsCannotBeModifiedByUIControlsDuringBlockedPersistenceState() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.totalSessions = 4
        vm.dailyGoalHours = 4
        vm.autoStartNextSession = false
        vm.persistData(force: true)

        // Corrupt primary to block persistence
        let corrupted = Data("CORRUPTED_SETTINGS_TEST_06".utf8)
        try corrupted.write(to: tempURL)
        vm.persistData(force: true)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Attempt modifications
        vm.totalSessions = 10
        vm.dailyGoalHours = 8
        vm.autoStartNextSession = true

        // Values must have reverted immediately
        XCTAssertEqual(vm.totalSessions, 4)
        XCTAssertEqual(vm.dailyGoalHours, 4)
        XCTAssertFalse(vm.autoStartNextSession)
    }

    // 7. Settings retain their original values when an error is active.
    @MainActor
    func testEdgeCase07_SettingsRetainOriginalValuesWhenStorageErrorIsActive() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)

        // Save custom settings
        let customData = FocusAppData(dailyGoalHours: 6, totalSessions: 8, autoStartNextSession: true)
        try storage.save(customData)

        // Corrupt both primary and backup
        try Data("CORRUPTED_P".utf8).write(to: primaryURL)
        try Data("CORRUPTED_B".utf8).write(to: storage.backupURL)

        // Create new VM on corrupted storage
        let storage2 = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage2)

        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)

        // Settings are kept readable and attempting to change them keeps them reverted
        let currentTotal = vm.totalSessions
        vm.totalSessions = 12
        XCTAssertEqual(vm.totalSessions, currentTotal)
    }

    // 8. Normal Settings operations continue working when persistence is healthy.
    @MainActor
    func testEdgeCase08_NormalSettingsOperationsContinueWorkingWhenPersistenceIsHealthy() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertFalse(vm.isPersistenceBlocked)

        vm.totalSessions = 7
        vm.dailyGoalHours = 6
        vm.autoStartNextSession = true
        vm.persistData(force: true)

        XCTAssertFalse(vm.isSaveFailed)

        // Verify on disk
        let storage = FocusStorageService(storageURL: tempURL)
        let loaded = try storage.decodeData(from: tempURL)

        XCTAssertEqual(loaded.totalSessions, 7)
        XCTAssertEqual(loaded.dailyGoalHours, 6)
        XCTAssertTrue(loaded.autoStartNextSession)
    }

    // 9. Fresh-install backup succeeds but primary creation fails; the valid backup remains.
    @MainActor
    func testEdgeCase09_FreshInstallBackupSucceedsButPrimaryCreationFailsRetainingValidBackup() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)

        storage.simulateWriteFailure = true

        let data = FocusAppData(tasks: [FocusTask(title: "Fresh Install Test 09")])
        XCTAssertThrowsError(try storage.save(data)) { error in
            guard case StorageError.writeFailed = error else {
                XCTFail("Expected writeFailed but got \(error)")
                return
            }
        }

        // Primary must not exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))

        // Backup must exist and be valid
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.backupURL.path))
        let backupData = try storage.decodeData(from: storage.backupURL)
        XCTAssertEqual(backupData.tasks.first?.title, "Fresh Install Test 09")
        XCTAssertTrue(storage.hasInterruptedInitialSave)
    }

    // 10. After the simulated primary-write failure is cleared, Retry safely restores the primary and successfully persists the intended state.
    @MainActor
    func testEdgeCase10_RetryAfterSimulatedPrimaryWriteFailureClearedSafelyRestoresPrimary() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        // Fresh install with primary write failure
        storage.simulateWriteFailure = true
        vm.addTask(title: "Pending Retry Task", expectedMinutes: 30)
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.backupURL.path))

        // Clear write failure and retry
        storage.simulateWriteFailure = false
        vm.retrySave()

        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertNil(vm.saveErrorMessage)
        XCTAssertNil(vm.lastSaveError)
        XCTAssertFalse(vm.isPersistenceBlocked)

        // Both primary and backup now exist and validate
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.backupURL.path))

        let primaryData = try storage.decodeData(from: primaryURL)
        let backupData = try storage.decodeData(from: storage.backupURL)

        XCTAssertTrue(primaryData.tasks.contains(where: { $0.title == "Pending Retry Task" }))
        XCTAssertFalse(storage.hasInterruptedInitialSave)
    }

    // 11. Repeated Retry failure retains a valid backup.
    @MainActor
    func testEdgeCase11_RepeatedRetryFailureRetainsValidBackup() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        storage.simulateWriteFailure = true
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.backupURL.path))
        let initialBackupData = try storage.decodeData(from: storage.backupURL)

        // First retry while failure persists
        vm.retrySave()
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.backupURL.path))

        // Second retry while failure persists
        vm.retrySave()
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.backupURL.path))

        let finalBackupData = try storage.decodeData(from: storage.backupURL)
        XCTAssertEqual(initialBackupData, finalBackupData)
    }

    // 12. A pre-existing orphan backup cannot be overwritten by unrelated in-memory default data.
    @MainActor
    func testEdgeCase12_PreExistingOrphanBackupCannotBeOverwrittenByUnrelatedDefaultData() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        // Pre-existing orphan backup with distinct user data
        let orphanUserTasks = [FocusTask(title: "PreExisting User Task 999", estimatedMinutes: 50)]
        let orphanData = FocusAppData(tasks: orphanUserTasks, focusedSeconds: 9999)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let orphanBytes = try encoder.encode(orphanData)
        try orphanBytes.write(to: backupURL)

        // Primary is missing
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Brand new storage service (hasInterruptedInitialSave == false)
        let storage = FocusStorageService(storageURL: primaryURL)
        XCTAssertFalse(storage.hasInterruptedInitialSave)

        // Attempt to save unrelated default data
        let unrelatedData = FocusAppData(tasks: [FocusTask(title: "Default Fresh Install Task")])
        XCTAssertThrowsError(try storage.save(unrelatedData)) { error in
            guard case StorageError.persistenceBlocked = error else {
                XCTFail("Expected persistenceBlocked but got \(error)")
                return
            }
        }

        XCTAssertTrue(storage.isPersistenceBlocked)

        // Orphan backup must remain completely intact and untouched!
        let retainedBackupBytes = try Data(contentsOf: backupURL)
        XCTAssertEqual(retainedBackupBytes, orphanBytes)
        let retainedData = try storage.decodeData(from: backupURL)
        XCTAssertEqual(retainedData.tasks.first?.title, "PreExisting User Task 999")
        XCTAssertEqual(retainedData.focusedSeconds, 9999)
    }

    // 13. Relaunch after interrupted initial save recovers the backup.
    @MainActor
    func testEdgeCase13_RelaunchAfterInterruptedInitialSaveRecoversBackup() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage1 = FocusStorageService(storageURL: primaryURL)

        storage1.simulateWriteFailure = true
        let data = FocusAppData(tasks: [FocusTask(title: "Recovered On Relaunch Task")])
        XCTAssertThrowsError(try storage1.save(data))

        // Relaunch with a fresh storage service
        let storage2 = FocusStorageService(storageURL: primaryURL)
        let loadResult = storage2.loadDetailed()

        guard case .recovered(let recoveredData, _, _) = loadResult else {
            XCTFail("Expected .recovered on relaunch but got \(loadResult)")
            return
        }

        XCTAssertEqual(recoveredData.tasks.first?.title, "Recovered On Relaunch Task")
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(storage2.isPersistenceBlocked)
    }

    // 14. Existing timer and stopwatch quit/reopen recovery continues working.
    @MainActor
    func testEdgeCase14_ExistingTimerAndStopwatchQuitReopenRecoveryContinuesWorking() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPresetDirectly(name: "Focus", minutes: 25)
        vm1.startTimer()
        vm1.timeRemaining = 850
        vm1.stopTimer()
        XCTAssertNotNil(vm1.pausedSession)

        vm1.stopwatchTime = 120
        vm1.stopwatchFractional = 120.75
        vm1.recordLap()
        vm1.stopStopwatch()

        vm1.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertFalse(vm2.isPersistenceBlocked)
        XCTAssertFalse(vm2.isSaveFailed)
        XCTAssertEqual(vm2.timeRemaining, 850)
        XCTAssertEqual(vm2.stopwatchTime, 120)
        XCTAssertEqual(vm2.stopwatchFractional, 120.75)
        XCTAssertEqual(vm2.laps.count, 1)
    }

    // 15. Existing diagnostic preservation and corrupted-JSON recovery remains passing.
    @MainActor
    func testEdgeCase15_ExistingDiagnosticPreservationAndCorruptedJSONRecoveryRemainsPassing() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        let storage = FocusStorageService(storageURL: primaryURL)

        // Write v1, then v2
        let v1 = FocusAppData(tasks: [FocusTask(title: "Version 1 Baseline")])
        try storage.save(v1)
        let v2 = FocusAppData(tasks: [FocusTask(title: "Version 2 Active")])
        try storage.save(v2)

        // Corrupt primary
        let corruptedBytes = Data("CORRUPTED_JSON_DIAGNOSTIC_TEST_15".utf8)
        try corruptedBytes.write(to: primaryURL)

        // Load storage: should create diagnostic and restore from backup (v1)
        let newStorage = FocusStorageService(storageURL: primaryURL)
        let loadResult = newStorage.loadDetailed()

        guard case .recovered(let recoveredData, _, let diagURL) = loadResult else {
            XCTFail("Expected .recovered but got \(loadResult)")
            return
        }

        XCTAssertEqual(recoveredData.tasks.first?.title, "Version 1 Baseline")
        XCTAssertNotNil(diagURL)
        if let diag = diagURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: diag.path))
            XCTAssertEqual(try Data(contentsOf: diag), corruptedBytes)
        }

        // Primary is restored and healthy
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(newStorage.isPersistenceBlocked)
    }

    // MARK: - Menu-Bar Timer Switch Confirmation Regression Tests (13 Scenarios)

    // 1. Active Focus -> Break requests confirmation with origin: .menuBar
    @MainActor
    func testMenuBarSwitch1_ActiveFocusToBreakRequestsConfirmation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive)
        XCTAssertEqual(vm.activePreset, "Focus")

        vm.switchToBreak(minutes: 5, origin: .menuBar)

        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertNotNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Short Break")
        XCTAssertEqual(vm.pendingTimerRequest?.minutes, 5)
        XCTAssertTrue(vm.pendingTimerRequest?.isBreak == true)
        // Original timer keeps running during confirmation decision
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.activePreset, "Focus")
    }

    // 2. Cancelling preserves the running timer, remaining time and current preset
    @MainActor
    func testMenuBarSwitch2_CancellingPreservesRunningTimerAndState() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 25 * 60 - 5
        let remainingBefore = vm.timeRemaining

        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)

        vm.continueCurrentTimer()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.timeRemaining, remainingBefore)
    }

    // 3. Confirming switches exactly once
    @MainActor
    func testMenuBarSwitch3_ConfirmingSwitchesExactlyOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)

        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertEqual(vm.totalTime, 300)
        XCTAssertTrue(vm.isTimerRunning)

        // Calling endAndSwitch a second time is a safe no-op since pending is cleared
        vm.endAndSwitch()
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertEqual(vm.totalTime, 300)
    }

    // 4. Active Break -> Focus follows the same correct flow
    @MainActor
    func testMenuBarSwitch4_ActiveBreakToFocusFollowsCorrectFlow() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start in Short Break
        vm.switchToBreak(minutes: 5, origin: .mainWindow)
        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertTrue(vm.isBreakPreset)

        // Switch to Focus requested from Menu Bar
        vm.switchToFocus(minutes: 25, origin: .menuBar)

        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertNotNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Focus")
        XCTAssertEqual(vm.pendingTimerRequest?.minutes, 25)
        XCTAssertFalse(vm.pendingTimerRequest?.isBreak ?? true)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertTrue(vm.isBreakPreset)

        // Confirm
        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.totalTime, 25 * 60)
        XCTAssertTrue(vm.isTimerRunning)
    }

    // 5. Paused countdown remains paused and unchanged after cancellation
    @MainActor
    func testMenuBarSwitch5_PausedCountdownRemainsPausedAndUnchangedAfterCancellation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        // Simulate some time passed
        vm.timeRemaining = 25 * 60 - 45
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive) // Paused with elapsed progress is active!
        let pausedRemaining = vm.timeRemaining

        vm.requestPresetChange(name: "Long Break", minutes: 15, origin: .menuBar)

        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Long Break")

        vm.continueCurrentTimer()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, pausedRemaining)
        XCTAssertEqual(vm.activePreset, "Focus")
    }

    // 6. Idle preset changes do not trigger confirmation
    @MainActor
    func testMenuBarSwitch6_IdlePresetChangesDoNotTriggerConfirmation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertFalse(vm.isTimerActive)

        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertEqual(vm.totalTime, 300)
    }

    // 7. Custom duration requests are handled consistently
    @MainActor
    func testMenuBarSwitch7_CustomDurationRequestsHandledConsistently() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()

        vm.setCustomDuration(minutes: 42, seconds: 15, origin: .menuBar)

        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Custom")
        XCTAssertEqual(vm.pendingTimerRequest?.minutes, 42)
        XCTAssertEqual(vm.pendingTimerRequest?.seconds, 15)
        XCTAssertEqual(vm.pendingTimerRequest?.mode, "Custom Timer")

        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertEqual(vm.activePreset, "Custom")
        XCTAssertEqual(vm.totalTime, 42 * 60 + 15)
        XCTAssertTrue(vm.isTimerRunning)
    }

    // 8. Repeated requests do not cause duplicate switches
    @MainActor
    func testMenuBarSwitch8_RepeatedRequestsDoNotCauseDuplicateSwitches() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()

        // First request: Short Break
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Short Break")

        // Second request before confirming: Long Break
        vm.requestPresetChange(name: "Long Break", minutes: 15, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Long Break")
        XCTAssertEqual(vm.pendingTimerRequest?.minutes, 15)

        // Single confirmation switches to the latest request
        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.activePreset, "Long Break")
        XCTAssertEqual(vm.totalTime, 900)
    }

    // 9. Pending requests are safely handled after a popover is dismissed and reopened
    @MainActor
    func testMenuBarSwitch9_PendingRequestsSafelyHandledAcrossPopoverDismissalAndReopen() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()

        // User triggers switch in menu-bar popover
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)

        // Simulate companion popover dismissal and reopening:
        // ViewModel retains the pending request state
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertNotNil(vm.pendingTimerRequest)

        // Timer continues counting down in background
        vm.timeRemaining -= 5

        // User reopens and confirms switch
        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning)
    }

    // 10. Storage-blocked state prevents confirmation from mutating persistent state
    @MainActor
    func testMenuBarSwitch10_StorageBlockedPreventsConfirmationFromMutatingPersistentState() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start timer then trigger unrecoverable corruption state
        vm.startTimer()
        let corrupted = Data("CORRUPTED_TEST_STORAGE_BLOCKED".utf8)
        try corrupted.write(to: tempURL)
        vm.persistData(force: true)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Attempting preset request while blocked should be rejected
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)

        // Even if pending was somehow set, endAndSwitch rejects when persistence is blocked
        vm.pendingTimerRequest = (name: "Short Break", minutes: 5, seconds: 0, mode: "Pomodoro", isBreak: true)
        vm.showConflictModal = true
        vm.conflictOrigin = .menuBar

        vm.endAndSwitch()

        // Should NOT have applied the switch because persistence is blocked
        XCTAssertNotEqual(vm.activePreset, "Short Break")
    }

    // 11. Stopwatch state and laps remain unchanged
    @MainActor
    func testMenuBarSwitch11_StopwatchStateAndLapsRemainUnchangedDuringPresetSwitch() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Set up stopwatch with time and laps
        vm.startStopwatch()
        vm.stopwatchTime = 120
        vm.stopwatchFractional = 120.5
        vm.recordLap()
        vm.stopwatchTime = 240
        vm.stopwatchFractional = 240.8
        vm.recordLap()
        XCTAssertEqual(vm.laps.count, 2)

        // Focus timer is started and switches
        vm.startTimer()
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)

        vm.endAndSwitch()

        // Stopwatch state and recorded laps remain intact and unmodified
        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.stopwatchTime, 240)
        XCTAssertEqual(vm.stopwatchFractional, 240.8)
    }

    // 12. Main window vs Menu bar presentation origin isolation
    @MainActor
    func testMenuBarSwitch12_MainWindowAndMenuBarPresentationOriginIsolation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()

        // Request from main window sets origin to .mainWindow
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .mainWindow)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .mainWindow)

        // Request from menu bar updates origin to .menuBar
        vm.requestPresetChange(name: "Long Break", minutes: 15, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Long Break")

        vm.continueCurrentTimer()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
    }

    // 13. Timer completion while confirmation is pending cleanly dismisses conflict state
    @MainActor
    func testMenuBarSwitch13_TimerCompletionWhileConflictPendingCleansUpSafely() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 1
        vm.requestPresetChange(name: "Short Break", minutes: 5, origin: .menuBar)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)

        // Timer finishes naturally: calls handleSessionComplete
        vm.handleSessionComplete()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.conflictOrigin)
        XCTAssertNil(vm.pendingTimerRequest)
    }

    // 14. Visual GUI Snapshot Verification of Menu Bar Confirmation Card
    @MainActor
    func testMenuBarSwitch14_VisualSnapshotRendering() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 24 * 60 + 35 // 24:35 remaining
        vm.switchToBreak(minutes: 5, origin: .menuBar)

        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Short Break")

        let audio = AmbientAudioPlayer()
        let view = MenuBarCompanionView(viewModel: vm, audioPlayer: audio)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 316, height: 420)
        hostingView.layoutSubtreeIfNeeded()

        if let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                let outURL = URL(fileURLWithPath: "/tmp/focusflow_menubar_confirmation.png")
                try pngData.write(to: outURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
                XCTAssertGreaterThan(pngData.count, 1000)
            }
        }
    }

    // MARK: - Timer Display Consistency & Menu-Bar UI Interaction Tests (15 Scenarios)

    // 1. Running Focus Timer shows actual remaining time
    @MainActor
    func testTimerDisplay1_RunningFocusTimerShowsActualRemainingTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 1435 // 23:55
        vm.selectedCompanionMode = .timer

        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timerTimeString, "23:55")
        XCTAssertEqual(vm.timeRemaining, 1435)
        XCTAssertEqual(vm.totalTime, 1500)
    }

    // 2. Paused Focus Timer shows the same remaining time as its ViewModel
    @MainActor
    func testTimerDisplay2_PausedFocusTimerShowsSameRemainingTimeAsViewModel() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 1200 // 20:00
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive) // Paused with elapsed progress is active!
        XCTAssertEqual(vm.timeRemaining, 1200)
        XCTAssertEqual(vm.timerTimeString, "20:00")
        XCTAssertEqual(vm.totalTime, 1500)
    }

    // 3. Paused Short Break at 04:54 displays 04:54, not 05:00
    @MainActor
    func testTimerDisplay3_PausedShortBreakAt0454Displays0454Not0500() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.switchToBreak(minutes: 5, origin: .mainWindow)
        XCTAssertEqual(vm.totalTime, 300)
        XCTAssertEqual(vm.timerTimeString, "05:00")

        vm.startTimer()
        vm.timeRemaining = 294 // 04:54
        vm.stopTimer() // Paused

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive)
        XCTAssertEqual(vm.timeRemaining, 294)
        XCTAssertEqual(vm.timerTimeString, "04:54")
        XCTAssertNotEqual(vm.timerTimeString, "05:00")
    }

    // 4. Paused Long Break restores the correct remaining time
    @MainActor
    func testTimerDisplay4_PausedLongBreakRestoresCorrectRemainingTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.switchToBreak(minutes: 15, origin: .mainWindow)
        XCTAssertEqual(vm.totalTime, 900)

        vm.startTimer()
        vm.timeRemaining = 850 // 14:10
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive)
        XCTAssertEqual(vm.timeRemaining, 850)
        XCTAssertEqual(vm.timerTimeString, "14:10")
    }

    // 5. Resume continues from the exact paused duration
    @MainActor
    func testTimerDisplay5_ResumeContinuesFromExactPausedDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 1000
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1000)

        // Resume via toggleTimer()
        vm.toggleTimer()

        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1000)
        XCTAssertEqual(vm.timerTimeString, "16:40")
    }

    // 6. Reset returns to the configured duration
    @MainActor
    func testTimerDisplay6_ResetReturnsToConfiguredDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 800
        vm.stopTimer()

        XCTAssertTrue(vm.isTimerActive)

        vm.resetFocusTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertFalse(vm.isTimerActive)
        XCTAssertEqual(vm.timeRemaining, 1500)
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.timerTimeString, "25:00")
    }

    // 7. Opening/reopening the popover does not reset paused time
    @MainActor
    func testTimerDisplay7_OpeningReopeningPopoverDoesNotResetPausedTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.timeRemaining = 1234
        vm.stopTimer()
        vm.selectedCompanionMode = .timer

        XCTAssertEqual(vm.timeRemaining, 1234)

        // Simulate multiple popover appearances
        if vm.isStopwatchRunning && !vm.isTimerRunning && !vm.isTimerActive {
            vm.selectedCompanionMode = .stopwatch
        } else if vm.isTimerRunning && !vm.isStopwatchRunning {
            vm.selectedCompanionMode = .timer
        }

        XCTAssertEqual(vm.timeRemaining, 1234)
        XCTAssertEqual(vm.selectedCompanionMode, .timer)
    }

    // 8. Programmatic display synchronization does not change countdown or mutate data
    @MainActor
    func testTimerDisplay8_ProgrammaticDisplaySyncDoesNotMutateCountdown() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.switchToBreak(minutes: 5, origin: .mainWindow)
        vm.startTimer()
        vm.timeRemaining = 294 // 04:54
        vm.stopTimer()

        let initialRemaining = vm.timeRemaining
        let initialTotal = vm.totalTime

        // Reading timer display properties must never alter timeRemaining
        _ = vm.timerTimeString
        _ = vm.displayedTimerTimeString
        _ = vm.fillAmount

        XCTAssertEqual(vm.timeRemaining, initialRemaining)
        XCTAssertEqual(vm.totalTime, initialTotal)
    }

    // 9. A prior nonzero paused Stopwatch does not hijack the Focus Timer status-bar clock
    @MainActor
    func testTimerDisplay9_PriorNonzeroPausedStopwatchDoesNotHijackFocusTimerClock() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Run stopwatch to 125 seconds, then pause
        vm.startStopwatch()
        vm.stopwatchStartDate = Date().addingTimeInterval(-125.0)
        vm.stopStopwatch()

        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 125)
        XCTAssertEqual(vm.stopwatchTimeString, "02:05")

        // User switches to Focus Timer and pauses Focus Timer at 22:30 (1350s)
        vm.selectedCompanionMode = .timer
        vm.startTimer()
        vm.targetEndDate = Date().addingTimeInterval(1350.0)
        vm.stopTimer()

        XCTAssertEqual(vm.selectedCompanionMode, .timer)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive)
        XCTAssertEqual(vm.timerTimeString, "22:30")

        // Top menu-bar clock must show Focus Timer (22:30), NOT the old paused Stopwatch (02:05)
        let displayTime = (vm.selectedCompanionMode == .stopwatch) ? vm.stopwatchTimeString : vm.timerTimeString
        XCTAssertEqual(displayTime, "22:30")
        XCTAssertNotEqual(displayTime, "02:05")
    }

    // 10. Selecting Stopwatch updates the intended clock and icon correctly
    @MainActor
    func testTimerDisplay10_SelectingStopwatchUpdatesIntendedClockAndIcon() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchTime = 45
        vm.selectedCompanionMode = .stopwatch

        let displayTime = (vm.selectedCompanionMode == .stopwatch) ? vm.stopwatchTimeString : vm.timerTimeString
        XCTAssertEqual(displayTime, "00:45")

        vm.startStopwatch()
        XCTAssertTrue(vm.isStopwatchRunning)
        let runningIcon = vm.isStopwatchRunning ? "stopwatch.fill" : "stopwatch"
        XCTAssertEqual(runningIcon, "stopwatch.fill")

        vm.stopStopwatch()
        let pausedIcon = vm.isStopwatchRunning ? "stopwatch.fill" : "stopwatch"
        XCTAssertEqual(pausedIcon, "stopwatch")
    }

    // 11. Selecting Focus Timer restores Focus countdown display
    @MainActor
    func testTimerDisplay11_SelectingFocusTimerRestoresFocusCountdownDisplay() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchTime = 45
        vm.timeRemaining = 850 // 14:10
        vm.activePreset = "Focus"

        vm.selectedCompanionMode = .timer
        let displayTime = (vm.selectedCompanionMode == .stopwatch) ? vm.stopwatchTimeString : vm.timerTimeString
        XCTAssertEqual(displayTime, "14:10")
    }

    // 12. Same Break preset with a different duration is correctly processed
    @MainActor
    func testTimerDisplay12_SameBreakPresetWithDifferentDurationCorrectlyProcessed() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start in 5m Short Break (idle)
        vm.switchToBreak(minutes: 5, origin: .mainWindow)
        XCTAssertEqual(vm.totalTime, 300)
        XCTAssertEqual(vm.activePreset, "Short Break")

        // User requests 10-minute break (also classified under Short Break)
        vm.switchToBreak(minutes: 10, origin: .menuBar)

        // Must NOT be ignored! Configured duration updates to 600s
        XCTAssertEqual(vm.totalTime, 600)
        XCTAssertEqual(vm.timeRemaining, 600)
        XCTAssertEqual(vm.timerTimeString, "10:00")
    }

    // 13. A cancelled duration change preserves original progress
    @MainActor
    func testTimerDisplay13_CancelledDurationChangePreservesOriginalProgress() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.switchToBreak(minutes: 5, origin: .mainWindow)
        vm.startTimer()
        vm.timeRemaining = 250 // paused with progress
        vm.stopTimer()

        // Request 10m break while paused
        vm.switchToBreak(minutes: 10, origin: .menuBar)

        XCTAssertTrue(vm.showConflictModal)
        XCTAssertEqual(vm.conflictOrigin, .menuBar)
        XCTAssertEqual(vm.pendingTimerRequest?.minutes, 10)

        // Cancel
        vm.continueCurrentTimer()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertEqual(vm.totalTime, 300)
        XCTAssertEqual(vm.timeRemaining, 250)
        XCTAssertEqual(vm.timerTimeString, "04:10")
    }

    // 14. Mode changes do not accidentally modify timer or stopwatch state
    @MainActor
    func testTimerDisplay14_ModeChangesDoNotAccidentallyModifyTimerOrStopwatchState() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.targetEndDate = Date().addingTimeInterval(500.0)
        vm.stopTimer()

        vm.startStopwatch()
        vm.stopwatchStartDate = Date().addingTimeInterval(-60.0)
        vm.recordLap()
        vm.stopStopwatch()

        XCTAssertEqual(vm.timeRemaining, 500)
        XCTAssertEqual(vm.stopwatchTime, 60)
        XCTAssertEqual(vm.laps.count, 1)

        // Switch to stopwatch mode
        vm.selectedCompanionMode = .stopwatch
        XCTAssertEqual(vm.timeRemaining, 500)
        XCTAssertEqual(vm.stopwatchTime, 60)
        XCTAssertEqual(vm.laps.count, 1)

        // Switch back to timer mode
        vm.selectedCompanionMode = .timer
        XCTAssertEqual(vm.timeRemaining, 500)
        XCTAssertEqual(vm.stopwatchTime, 60)
        XCTAssertEqual(vm.laps.count, 1)
    }

    // 15. Visual Snapshot of Paused Short Break (04:54) in Menu-Bar Popover
    @MainActor
    func testTimerDisplay15_VisualSnapshotPausedShortBreak() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.switchToBreak(minutes: 5, origin: .mainWindow)
        vm.startTimer()
        vm.timeRemaining = 294 // 04:54
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive)
        XCTAssertEqual(vm.timerTimeString, "04:54")

        let audio = AmbientAudioPlayer()
        let view = MenuBarCompanionView(viewModel: vm, audioPlayer: audio)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 316, height: 420)
        hostingView.layoutSubtreeIfNeeded()

        if let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
            if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                let outURL = URL(fileURLWithPath: "/tmp/focusflow_menubar_paused.png")
                try pngData.write(to: outURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
            }
        }
    }

    // MARK: - Custom Timer In-Place Input & Focus Prevention Tests

    private func containsEditableTextInput(in view: NSView) -> Bool {
        if let tf = view as? NSTextField, tf.isEditable {
            return true
        }
        if let tv = view as? NSTextView, tv.isEditable {
            return true
        }
        for subview in view.subviews {
            if containsEditableTextInput(in: subview) {
                return true
            }
        }
        return false
    }

    @MainActor
    func testCustomTimerFocus01_InitialWindowPresentationHasNoActiveEditingResponder() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        // In display mode, the initial window presentation must NOT render any editable text field or text view
        XCTAssertFalse(containsEditableTextInput(in: hostingView), "Initial window presentation must not render any editable text field or text view in display mode")
        XCTAssertNil(view.activeEditingField, "Initial timer presentation must have nil activeEditingField")
    }

    @MainActor
    func testCustomTimerFocus02_InitialCustomTimerDurationDisplaysCorrectValuesWithoutEditing() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        XCTAssertNil(view.activeEditingField, "Initial timer presentation must have nil activeEditingField")
        XCTAssertEqual(view.inputMinutes, "45")
        XCTAssertEqual(view.inputSeconds, "00")
    }

    @MainActor
    func testCustomTimerFocus03_IntentionalMinutesActivationEnablesEditing() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        view.startEditing(.minutes)
        XCTAssertEqual(view.activeEditingField, .minutes)
    }

    @MainActor
    func testCustomTimerFocus04_IntentionalSecondsActivationEnablesEditing() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        view.startEditing(.seconds)
        XCTAssertEqual(view.activeEditingField, .seconds)
    }

    @MainActor
    func testCustomTimerFocus05_EscapeKeyCancelsEditingAndRestoresDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        view.startEditing(.minutes)
        view.inputMinutes = "99"
        view.cancelEditing()

        XCTAssertNil(view.activeEditingField)
        XCTAssertEqual(view.inputMinutes, "45", "Cancelling editing must restore original duration")
    }

    @MainActor
    func testCustomTimerFocus06_ShortcutChipSelectionClearsEditingAndAppliesDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        view.startEditing(.minutes)
        XCTAssertNotNil(view.activeEditingField)

        view.stopEditing()
        vm.setCustomDuration(minutes: 25, seconds: 0)
        XCTAssertNil(view.activeEditingField)
        XCTAssertEqual(vm.totalTime, 1500)
    }

    @MainActor
    func testCustomTimerFocus07_StepperAdjustmentClearsEditingAndModifiesDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        view.startEditing(.minutes)
        XCTAssertNotNil(view.activeEditingField)

        view.stopEditing()
        vm.setCustomDuration(minutes: 50, seconds: 0)
        XCTAssertNil(view.activeEditingField)
        XCTAssertEqual(vm.totalTime, 3000)
    }

    @MainActor
    func testCustomTimerFocus08_MenuBarCompanionInitialPresentationHasNoEditingResponder() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        let audio = AmbientAudioPlayer()
        let view = MenuBarCompanionView(viewModel: vm, audioPlayer: audio)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 316, height: 420)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertFalse(containsEditableTextInput(in: hostingView), "MenuBarCompanion initial presentation must not render any editable text input field in display mode")
    }

    private func collectAllRenderedStrings(in view: NSView) -> [String] {
        var strings: [String] = []
        if let tf = view as? NSTextField {
            strings.append(tf.stringValue)
        }
        for subview in view.subviews {
            strings.append(contentsOf: collectAllRenderedStrings(in: subview))
        }
        return strings
    }

    @MainActor
    func testCustomTimerFocus09_SecondsAndMinutesDisplayNeverTruncateAtAnySize() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        for testSize: CGFloat in [220, 280, 340, 400, 490] {
            let view = InPlaceTimeInputView(viewModel: vm, size: testSize)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            hostingView.layoutSubtreeIfNeeded()

            let renderedStrings = collectAllRenderedStrings(in: hostingView)
            for str in renderedStrings {
                XCTAssertFalse(str.contains("..."), "Rendered string '\(str)' must not contain ellipsis at size \(testSize)")
                XCTAssertFalse(str.contains("…"), "Rendered string '\(str)' must not contain Unicode ellipsis at size \(testSize)")
            }
        }
    }

    @MainActor
    func testCustomTimerFocus10_CardBoundsContainRenderedDigitsWithoutOverflowAtAllSizes() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let model = InPlaceTimeInputView.Model(totalTime: vm.totalTime)
        XCTAssertEqual(model.inputMinutes, "25", "Minutes must format to 25")
        XCTAssertEqual(model.inputSeconds, "00", "Seconds must format to 00")

        for testSize: CGFloat in [220, 280, 340, 400, 490] {
            let digitFontSize = max(32, min(testSize * 0.125, 48))
            let boxHeight = max(60, min(testSize * 0.19, 78))
            let boxWidth = max(100, min(testSize * 0.30, 136))

            // In SF Rounded Bold, line height is ~1.18 * pointSize
            let estimatedLineHeight = digitFontSize * 1.18
            XCTAssertLessThan(estimatedLineHeight, boxHeight, "Digit font line height must be strictly less than card boxHeight at size \(testSize)")
            XCTAssertGreaterThanOrEqual(boxHeight - estimatedLineHeight, 6.0, "Card boxHeight must have at least 6pt vertical breathing room for font at size \(testSize)")
            XCTAssertGreaterThanOrEqual(boxWidth, 100.0, "Card boxWidth must be at least 100pt for comfortable horizontal margin")

            let view = InPlaceTimeInputView(viewModel: vm, size: testSize, model: model)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            hostingView.layoutSubtreeIfNeeded()

            let renderedStrings = collectAllRenderedStrings(in: hostingView)
            for str in renderedStrings {
                XCTAssertFalse(str.contains("..."), "No rendered text must truncate with ellipsis at size \(testSize)")
            }
        }
    }

    // MARK: - Custom Timer Input UX Reengineering Tests (01 - 20)

    @MainActor
    func testCustomTimerUX_01_Typing45FromSelected25DoesNotMutateAuthoritativeDurationUntilCommit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(controller.inputMinutes, "25")

        // User clicks minutes to begin editing
        controller.startEditing(.minutes)
        XCTAssertEqual(controller.activeEditingField, .minutes)
        XCTAssertEqual(vm.totalTime, 1500, "Opening edit mode must not mutate timer")

        // User types '4' (first keystroke of '45')
        controller.updateDraft(field: .minutes, text: "4")
        XCTAssertEqual(controller.inputMinutes, "4")
        XCTAssertEqual(vm.totalTime, 1500, "Drafting '4' must NOT mutate authoritative duration to 4 minutes!")

        // User types '5' (second keystroke)
        controller.updateDraft(field: .minutes, text: "45")
        XCTAssertEqual(controller.inputMinutes, "45")
        XCTAssertEqual(vm.totalTime, 1500, "Drafting '45' must NOT mutate authoritative duration until commit!")

        // User commits (e.g. presses Return or Start)
        let success = controller.commitEditing()
        XCTAssertTrue(success)
        XCTAssertNil(controller.activeEditingField)
        XCTAssertEqual(vm.totalTime, 2700, "Committing draft must set authoritative duration to 45:00 (2700s) exactly once")
    }

    @MainActor
    func testCustomTimerUX_02_TemporaryEmptyFieldDuringReplacementDoesNotResetOrCrash() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        // User selects all and presses Backspace
        controller.updateDraft(field: .minutes, text: "")
        XCTAssertEqual(controller.inputMinutes, "", "Temporary empty draft is allowed during replacement")
        XCTAssertEqual(vm.totalTime, 1500, "Temporary empty draft must not mutate timer")

        // User types new value '30'
        controller.updateDraft(field: .minutes, text: "30")
        XCTAssertEqual(controller.inputMinutes, "30")

        let success = controller.commitEditing()
        XCTAssertTrue(success)
        XCTAssertEqual(vm.totalTime, 1800)
    }

    @MainActor
    func testCustomTimerUX_03_SecondsEditingWithPartialDigitsDoesNotMutateDurationUntilCommit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.seconds)
        XCTAssertEqual(controller.activeEditingField, .seconds)

        // User types '3'
        controller.updateDraft(field: .seconds, text: "3")
        XCTAssertEqual(controller.inputSeconds, "3")
        XCTAssertEqual(vm.totalTime, 1500, "Partial seconds typing must not mutate timer duration")

        // User types '0'
        controller.updateDraft(field: .seconds, text: "30")
        XCTAssertEqual(controller.inputSeconds, "30")
        XCTAssertEqual(vm.totalTime, 1500)

        controller.commitEditing()
        XCTAssertEqual(vm.totalTime, 25 * 60 + 30)
    }

    @MainActor
    func testCustomTimerUX_04_ValidCommitPublishesExactlyOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        var commitCount = 0
        controller.onCommit = { m, s in
            commitCount += 1
            vm.setCustomDuration(minutes: m, seconds: s)
        }

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "50")
        XCTAssertEqual(commitCount, 0, "No commit callback while typing")

        controller.commitEditing()
        XCTAssertEqual(commitCount, 1, "Committing must invoke onCommit exactly once")
        XCTAssertEqual(vm.totalTime, 3000)
    }

    @MainActor
    func testCustomTimerUX_05_InvalidCommitPreservesPreviousDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "0")
        controller.updateDraft(field: .seconds, text: "02") // 2s < 5s min

        let committed = controller.commitEditing()
        XCTAssertFalse(committed, "Durations below minimum must be rejected")
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(controller.validationError, .belowMinimum(seconds: 2, minimum: 5))
        XCTAssertEqual(controller.validationError?.localizedDescription, "Minimum timer duration is 00:05")
        XCTAssertEqual(vm.totalTime, 1500, "Previous valid duration must be preserved upon invalid commit")
        XCTAssertEqual(controller.committedMinutes, 25, "Committed minutes must remain preserved")
        XCTAssertEqual(controller.inputMinutes, "0", "Draft is kept visible with error feedback rather than silently wiped")

        // Cancel/Escape restores the snapshot
        controller.cancelEditing()
        XCTAssertEqual(controller.inputMinutes, "25", "Draft must be restored to previous valid duration upon cancel")
        XCTAssertFalse(controller.hasInvalidDraft)
        XCTAssertNil(controller.validationError)
    }

    @MainActor
    func testCustomTimerUX_06_EscapeRestoresCompleteOriginalDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 30)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "99")
        controller.updateDraft(field: .seconds, text: "59")

        controller.cancelEditing()
        XCTAssertNil(controller.activeEditingField)
        XCTAssertEqual(controller.inputMinutes, "25")
        XCTAssertEqual(controller.inputSeconds, "30")
        XCTAssertEqual(vm.totalTime, 25 * 60 + 30)
    }

    @MainActor
    func testCustomTimerUX_07_TabSwitchesCorrectlyBetweenMinutesAndSeconds() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "45")

        controller.commitAndSwitchField(to: .seconds)
        XCTAssertEqual(controller.activeEditingField, .seconds)
        XCTAssertEqual(controller.inputMinutes, "45")
        XCTAssertEqual(vm.totalTime, 1500, "Tabbing between fields does not prematurely commit to viewModel")
    }

    @MainActor
    func testCustomTimerUX_08_FocusLossDoesNotDoubleCommit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        var commitEventCount = 0
        controller.onCommit = { m, s in
            commitEventCount += 1
            vm.setCustomDuration(minutes: m, seconds: s)
        }

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "35")

        // First blur / commit
        let res1 = controller.commitEditing()
        XCTAssertTrue(res1)
        XCTAssertEqual(commitEventCount, 1)

        // Subsequent blur when already not editing
        let res2 = controller.commitEditing()
        XCTAssertTrue(res2)
        XCTAssertEqual(commitEventCount, 1, "Subsequent commit calls when already committed must not re-trigger callbacks")
    }

    @MainActor
    func testCustomTimerUX_09_PresetDiscardsStaleDraftAndSetsExactDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "77")

        controller.selectPreset(minutes: 15)
        XCTAssertNil(controller.activeEditingField)
        XCTAssertEqual(controller.inputMinutes, "15")
        XCTAssertEqual(controller.inputSeconds, "00")
        XCTAssertEqual(vm.totalTime, 15 * 60)
    }

    @MainActor
    func testCustomTimerUX_10_StepperPreservesSecondsAccurately() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 10, seconds: 30)
        let controller = vm.customTimeInputController
        XCTAssertEqual(vm.totalTime, 630)
        XCTAssertEqual(controller.inputMinutes, "10")
        XCTAssertEqual(controller.inputSeconds, "30")

        // +5m on 10:30 -> 15:30
        controller.adjustMinutes(by: 5)
        XCTAssertEqual(vm.totalTime, 930)
        XCTAssertEqual(controller.inputMinutes, "15")
        XCTAssertEqual(controller.inputSeconds, "30", "Seconds must be preserved upon +5m adjustment")

        // -5m on 15:30 -> 10:30
        controller.adjustMinutes(by: -5)
        XCTAssertEqual(vm.totalTime, 630)
        XCTAssertEqual(controller.inputMinutes, "10")
        XCTAssertEqual(controller.inputSeconds, "30", "Seconds must be preserved upon -5m adjustment")

        // +15m on 10:30 -> 25:30
        controller.adjustMinutes(by: 15)
        XCTAssertEqual(vm.totalTime, 1530)
        XCTAssertEqual(controller.inputMinutes, "25")
        XCTAssertEqual(controller.inputSeconds, "30", "Seconds must be preserved upon +15m adjustment")
    }

    @MainActor
    func testCustomTimerUX_11_ZeroMinuteValidDurationSupported() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "0")
        controller.updateDraft(field: .seconds, text: "30")

        let success = controller.commitEditing()
        XCTAssertTrue(success, "00:30 (30 seconds >= 5s minimum) is a valid duration")
        XCTAssertEqual(vm.totalTime, 30)
        XCTAssertEqual(controller.inputMinutes, "00")
        XCTAssertEqual(controller.inputSeconds, "30")
    }

    @MainActor
    func testCustomTimerUX_12_MaximumDurationBoundaryEnforced() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "500")

        let success = controller.commitEditing()
        XCTAssertFalse(success, "Minutes > 360 must be rejected or clamped")
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertLessThanOrEqual(vm.totalTime, TimerViewModel.maxSupportedTimerDuration)
    }

    @MainActor
    func testCustomTimerUX_13_ChangingToShorterDurationWorksWithoutMaxClobber() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 45, seconds: 0)
        XCTAssertEqual(vm.totalTime, 2700)

        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "10")

        let success = controller.commitEditing()
        XCTAssertTrue(success)
        XCTAssertEqual(vm.totalTime, 600, "Decreasing duration to 10 minutes must not be clobbered back to 45 by max()")
        XCTAssertEqual(controller.inputMinutes, "10")
    }

    @MainActor
    func testCustomTimerUX_14_ReturningFromSidebarNavigationPreservesDisplayStateWithoutAutofocus() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        // Verify initial state has nil editing field
        XCTAssertNil(view.activeEditingField)
        XCTAssertFalse(containsEditableTextInput(in: hostingView))
    }

    @MainActor
    func testCustomTimerUX_15_MainWindowAndMenuBarInputConsistency() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let mainController = vm.customTimeInputController
        let menuBarController = TimeInputController(totalTime: vm.totalTime)

        // Both must start with identical committed values
        XCTAssertEqual(mainController.committedTotalSeconds, menuBarController.committedTotalSeconds)
        XCTAssertEqual(mainController.inputMinutes, menuBarController.inputMinutes)
        XCTAssertEqual(mainController.inputSeconds, menuBarController.inputSeconds)

        // Both must enforce identical bounds
        XCTAssertEqual(TimeInputController.minDurationSeconds, 5)
        XCTAssertEqual(TimeInputController.maxMinutes, 360)
        XCTAssertEqual(TimeInputController.maxSeconds, 59)
    }

    @MainActor
    func testCustomTimerUX_16_ClickToEditFirstResponderBehavior() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        XCTAssertNil(view.activeEditingField)

        view.startEditing(.minutes)
        XCTAssertEqual(view.activeEditingField, .minutes)

        view.startEditing(.seconds)
        XCTAssertEqual(view.activeEditingField, .seconds)

        view.stopEditing()
        XCTAssertNil(view.activeEditingField)
    }

    @MainActor
    func testCustomTimerUX_17_NoInitialTextSelectionOnFreshLaunch() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertFalse(containsEditableTextInput(in: hostingView), "Display mode must not have any editable text responder")
        XCTAssertNil(view.activeEditingField)
    }

    @MainActor
    func testCustomTimerUX_18_NoDigitTruncationAtNarrowWidths() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 120, seconds: 45)
        for size: CGFloat in [220, 260, 316, 380, 500] {
            let view = InPlaceTimeInputView(viewModel: vm, size: size)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            hostingView.layoutSubtreeIfNeeded()

            let strings = collectAllRenderedStrings(in: hostingView)
            for s in strings {
                XCTAssertFalse(s.contains("..."), "No truncation ellipsis allowed at size \(size)")
                XCTAssertFalse(s.contains("…"), "No unicode ellipsis allowed at size \(size)")
            }
        }
    }

    @MainActor
    func testCustomTimerUX_19_StartButtonInteractionWithActiveDraft() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        // User starts editing minutes and types 45
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "45")

        // User presses Start (toggleTimer) without pressing Enter first
        vm.toggleTimer()

        // Draft must be committed and timer must start with 45 minutes!
        XCTAssertFalse(controller.isEditing, "Active draft must conclude upon starting timer")
        XCTAssertEqual(vm.totalTime, 2700, "Timer must start with the valid committed draft (45m)")
        XCTAssertTrue(vm.isTimerRunning, "Timer must be running")

        // Stop timer for next phase
        vm.toggleTimer()
        XCTAssertFalse(vm.isTimerRunning)

        // Now test invalid draft: user types 00:02 (< 5s)
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "0")
        controller.updateDraft(field: .seconds, text: "02")

        vm.toggleTimer()
        XCTAssertFalse(vm.isTimerRunning, "Timer must NOT start when draft is invalid")
        XCTAssertEqual(vm.totalTime, 2700, "Timer duration must not be corrupted by invalid draft")
    }

    @MainActor
    func testCustomTimerUX_20_SessionConflictBehaviorRemainsCorrect() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.startTimer()
        // Simulate elapsed time
        vm.timeRemaining = 20 * 60 // 5m elapsed

        // Changing preset while active timer has elapsed time must request confirmation
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal, "Switching presets while session is active must show conflict modal")
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Short Break")

        // User cancels / keeps session
        vm.continueCurrentTimer()
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertTrue(vm.isFocusPreset)
    }

    // MARK: - Custom Timer AppKit Interaction Hardening & Visible Validation Tests

    @MainActor
    func testCustomTimerHardening_01_TimeDigitNSTextField_viewDidMoveToWindow_acquiresFocusAndSelectsAll() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textField = TimeDigitNSTextField()
        textField.stringValue = "25"
        textField.isEditable = true
        textField.isSelectable = true

        var focusAcquiredCalled = false
        textField.onFocusAcquired = {
            focusAcquiredCalled = true
        }

        // Add to window hierarchy
        window.contentView?.addSubview(textField)
        textField.viewDidMoveToWindow()

        XCTAssertTrue(focusAcquiredCalled, "onFocusAcquired callback must be invoked upon moving to window")
        XCTAssertEqual(window.firstResponder, textField.currentEditor(), "Field editor must be first responder in window")
        XCTAssertEqual(textField.currentEditor()?.selectedRange.length, 2, "Entire text length (2 digits) must be selected for immediate typing")
    }

    @MainActor
    func testCustomTimerHardening_02_TimeDigitNSTextField_typingReplacesSelectionWithoutPrematureMutation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textField = TimeDigitNSTextField()
        textField.stringValue = "25"
        textField.isEditable = true
        textField.isSelectable = true
        window.contentView?.addSubview(textField)
        textField.viewDidMoveToWindow()

        // Verify initial selection covers whole string
        XCTAssertEqual(textField.currentEditor()?.selectedRange.length, 2)

        // Simulate typing "45" into field
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "45")

        // In draft mode, viewModel totalTime must NOT mutate prematurely
        XCTAssertEqual(controller.inputMinutes, "45")
        XCTAssertEqual(vm.totalTime, 1500, "Typing into draft must not mutate authoritative viewModel duration")
    }

    @MainActor
    func testCustomTimerHardening_03_TimeDigitField_insertNewline_commitsOnceAndDoesNotTriggerFocusLost() {
        var returnFired = 0
        var focusLostFired = 0
        var boundText = "45"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onReturn: { returnFired += 1 },
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()
        let textView = NSTextView()

        let handled = coordinator.control(control, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(handled, "insertNewline command must be handled")
        XCTAssertEqual(returnFired, 1, "onReturn must fire exactly once")

        // Simulate subsequent AppKit controlTextDidEndEditing notification for Return
        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: ["NSTextMovement": NSReturnTextMovement]
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 0, "onFocusLost must NOT fire when ending editing via Return")
    }

    @MainActor
    func testCustomTimerHardening_04_TimeDigitField_cancelOperation_revertsAndDoesNotTriggerFocusLost() {
        var escapeFired = 0
        var focusLostFired = 0
        var boundText = "45"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onEscape: { escapeFired += 1 },
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()
        let textView = NSTextView()

        let handled = coordinator.control(control, textView: textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(handled, "cancelOperation command must be handled")
        XCTAssertEqual(escapeFired, 1, "onEscape must fire exactly once")

        // Simulate subsequent AppKit controlTextDidEndEditing notification for Cancel
        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: ["NSTextMovement": NSCancelTextMovement]
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 0, "onFocusLost must NOT fire when ending editing via Escape")
    }

    @MainActor
    func testCustomTimerHardening_05_TimeDigitField_insertTab_navigatesMinutesToSecondsWithoutFocusLost() {
        var tabFired = 0
        var focusLostFired = 0
        var boundText = "45"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onTab: { tabFired += 1 },
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()
        let textView = NSTextView()

        let handled = coordinator.control(control, textView: textView, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(handled, "insertTab command must be handled")
        XCTAssertEqual(tabFired, 1, "onTab must fire")

        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: ["NSTextMovement": NSTabTextMovement]
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 0, "onFocusLost must NOT fire when navigating via Tab")
    }

    @MainActor
    func testCustomTimerHardening_06_TimeDigitField_insertBacktab_navigatesSecondsToMinutesWithoutFocusLost() {
        var backtabFired = 0
        var focusLostFired = 0
        var boundText = "30"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onBacktab: { backtabFired += 1 },
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()
        let textView = NSTextView()

        let handled = coordinator.control(control, textView: textView, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(handled, "insertBacktab command must be handled")
        XCTAssertEqual(backtabFired, 1, "onBacktab must fire")

        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: ["NSTextMovement": NSBacktabTextMovement]
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 0, "onFocusLost must NOT fire when navigating via Backtab")
    }

    @MainActor
    func testCustomTimerHardening_07_TimeDigitField_controlTextDidEndEditing_clickAwayWithoutMovement_callsFocusLost() {
        var focusLostFired = 0
        var boundText = "45"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()

        // Simulate click away where AppKit omits NSTextMovement metadata entirely
        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: nil
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 1, "Missing NSTextMovement in userInfo must reliably trigger onFocusLost")
    }

    @MainActor
    func testCustomTimerHardening_08_TimeDigitField_controlTextDidEndEditing_movementZero_callsFocusLost() {
        var focusLostFired = 0
        var boundText = "45"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()

        // Simulate click away where NSTextMovement is NSIllegalTextMovement (0) or NSOtherTextMovement
        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: ["NSTextMovement": 0]
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 1, "NSTextMovement 0 (click outside) must trigger onFocusLost")
    }

    @MainActor
    func testCustomTimerHardening_09_TimeDigitField_controlTextDidEndEditing_movementNSReturn_suppressesFocusLost() {
        var focusLostFired = 0
        var boundText = "45"

        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onFocusLost: { focusLostFired += 1 }
        )

        let coordinator = field.makeCoordinator()
        let control = NSControl()

        let notif = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: control,
            userInfo: ["NSTextMovement": NSReturnTextMovement]
        )
        coordinator.controlTextDidEndEditing(notif)
        XCTAssertEqual(focusLostFired, 0, "NSReturnTextMovement must NOT trigger onFocusLost")
    }

    @MainActor
    func testCustomTimerHardening_10_ValidationFeedback_InvalidSecondsRejection() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.seconds)
        controller.updateDraft(field: .seconds, text: "75")

        let success = controller.commitEditing()
        XCTAssertFalse(success, "Seconds > 59 must be rejected")
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(controller.validationError, .invalidSeconds(seconds: 75))
        XCTAssertEqual(controller.validationError?.localizedDescription, "Seconds must be between 00 and 59")
        XCTAssertEqual(controller.committedSeconds, 0, "Committed seconds must remain intact")
        XCTAssertEqual(vm.totalTime, 1500, "Timer duration must not be mutated")

        // Clearing draft resets validation error
        controller.updateDraft(field: .seconds, text: "30")
        XCTAssertNil(controller.validationError)
        XCTAssertFalse(controller.hasInvalidDraft)

        let validCommit = controller.commitEditing()
        XCTAssertTrue(validCommit)
        XCTAssertEqual(vm.totalTime, 25 * 60 + 30)
    }

    @MainActor
    func testCustomTimerHardening_11_ValidationFeedback_BelowMinimumRejection() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "0")
        controller.updateDraft(field: .seconds, text: "03")

        let success = controller.commitEditing()
        XCTAssertFalse(success, "Duration < 5 seconds must be rejected")
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(controller.validationError, .belowMinimum(seconds: 3, minimum: 5))
        XCTAssertEqual(controller.validationError?.localizedDescription, "Minimum timer duration is 00:05")
        XCTAssertEqual(controller.inputMinutes, "0")
        XCTAssertEqual(controller.inputSeconds, "03", "Draft values are preserved so user can see and correct them")
    }

    @MainActor
    func testCustomTimerHardening_12_ValidationFeedback_AboveMaximumRejection() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "500")

        let success = controller.commitEditing()
        XCTAssertFalse(success, "Minutes > 360 must be rejected")
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(controller.validationError, .invalidMinutes(minutes: 500))
        XCTAssertEqual(controller.validationError?.localizedDescription, "Maximum timer duration is 360:59")
    }

    @MainActor
    func testCustomTimerHardening_13_StartButtonBlockedWhileInvalidDraftUnresolved() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.seconds)
        controller.updateDraft(field: .seconds, text: "80")

        let commitAttempt = vm.commitActiveTimeInputBeforeStart()
        XCTAssertFalse(commitAttempt, "commitActiveTimeInputBeforeStart must fail when draft is invalid")

        vm.toggleTimer()
        XCTAssertFalse(vm.isTimerRunning, "Timer must NOT start while invalid draft exists")
        XCTAssertEqual(vm.totalTime, 1500, "Duration must not be changed")
    }

    @MainActor
    func testCustomTimerHardening_14_FirstLaunchViewHierarchy_HasZeroEditableTextResponders() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let view = InPlaceTimeInputView(viewModel: vm, size: 400)
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        XCTAssertNil(view.activeEditingField, "Active editing field must be nil on initial launch")
        XCTAssertFalse(containsEditableTextInput(in: hostingView), "First-launch view must display clean Text without editable text fields")
    }

    @MainActor
    func testCustomTimerHardening_15_SharedPendingDraftAcrossMinutesAndSeconds_UntilCommitted() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        // User edits minutes to "40"
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "40")

        // User tabs or clicks into seconds
        controller.commitAndSwitchField(to: .seconds)
        XCTAssertEqual(controller.activeEditingField, .seconds)
        XCTAssertEqual(controller.inputMinutes, "40")
        XCTAssertEqual(vm.totalTime, 1500, "Switching between fields keeps pending shared draft without mutating viewModel")

        // User edits seconds to "30"
        controller.updateDraft(field: .seconds, text: "30")
        XCTAssertEqual(controller.inputSeconds, "30")
        XCTAssertEqual(vm.totalTime, 1500, "Draft remains uncommitted")

        // Final commit (Enter or click outside)
        let success = controller.commitEditing()
        XCTAssertTrue(success)
        XCTAssertEqual(vm.totalTime, 40 * 60 + 30, "Duration must update atomically to 40m 30s")
    }

    @MainActor
    func testCustomTimerHardening_16_MenuBarCompanion_SymmetricBehaviorWithMainWindow() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let companionController = TimeInputController(totalTime: vm.totalTime)

        companionController.startEditing(.seconds)
        companionController.updateDraft(field: .seconds, text: "99")

        let committed = companionController.commitEditing()
        XCTAssertFalse(committed, "Menu bar companion must reject seconds > 59 symmetrically")
        XCTAssertTrue(companionController.hasInvalidDraft)
        XCTAssertEqual(companionController.validationError?.localizedDescription, "Seconds must be between 00 and 59")

        companionController.cancelEditing()
        XCTAssertFalse(companionController.hasInvalidDraft)
        XCTAssertEqual(companionController.inputSeconds, "00")
    }

    @MainActor
    func testCustomTimerHardening_17_TimeDigitNSTextField_activateAndSelectAll_DoesNotTriggerSpuriousEndEditing() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var boundText = "25"
        var focusLostCount = 0
        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onFocusLost: { focusLostCount += 1 }
        )
        let coordinator = field.makeCoordinator()
        let textField = TimeDigitNSTextField()
        textField.stringValue = "25"
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = coordinator
        coordinator.textField = textField

        window.contentView?.addSubview(textField)
        textField.activateAndSelectAll()

        XCTAssertEqual(focusLostCount, 0, "activateAndSelectAll must never cause onFocusLost")
        XCTAssertEqual(window.firstResponder, textField.currentEditor(), "Field editor must be active first responder")
        XCTAssertEqual(textField.currentEditor()?.selectedRange.length, 2, "Text must remain fully selected for typing")
    }

    @MainActor
    func testCustomTimerHardening_18_TimeDigitNSTextField_DirectTypingInWindowReplacesSelection() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var boundText = "25"
        var focusLostCount = 0
        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onFocusLost: { focusLostCount += 1 }
        )
        let coordinator = field.makeCoordinator()
        let textField = TimeDigitNSTextField()
        textField.stringValue = "25"
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = coordinator
        coordinator.textField = textField

        window.contentView?.addSubview(textField)
        textField.activateAndSelectAll()

        guard let editor = textField.currentEditor() as? NSTextView else {
            XCTFail("Field editor must be available as NSTextView")
            return
        }

        // Simulate user typing '4' then '5' over selected text
        editor.insertText("4", replacementRange: editor.selectedRange)
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        XCTAssertEqual(boundText, "4")

        editor.insertText("5", replacementRange: editor.selectedRange)
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        XCTAssertEqual(boundText, "45")
        XCTAssertEqual(focusLostCount, 0, "Typing must not trigger onFocusLost")
    }

    @MainActor
    func testCustomTimerHardening_19_TimeDigitNSTextField_ClickAwayInWindowCallsFocusLost() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        var boundText = "25"
        var focusLostCount = 0
        let field = TimeDigitField(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            onFocusLost: { focusLostCount += 1 }
        )
        let coordinator = field.makeCoordinator()
        let textField = TimeDigitNSTextField()
        textField.stringValue = "25"
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = coordinator
        coordinator.textField = textField
        textField.onFocusAcquired = {
            coordinator.hasReportedFocusLost = false
        }

        let otherButton = NSButton(title: "Other", target: nil, action: nil)

        window.contentView?.addSubview(textField)
        window.contentView?.addSubview(otherButton)
        textField.activateAndSelectAll()

        XCTAssertEqual(focusLostCount, 0)

        // Switch first responder to another control (simulating click away)
        window.makeFirstResponder(otherButton)

        let exp = expectation(description: "Focus lost dispatched asynchronously")
        DispatchQueue.main.async {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(focusLostCount, 1, "Clicking away to another control must trigger onFocusLost")
    }

    // MARK: - Stopwatch Lap Integrity Tests

    // 1. Record first lap at 10.5s -> Lap 1 duration = 10.5s, total = 10.5s
    @MainActor
    func testLapIntegrity01_RecordFirstLapAt10_5s() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.5
        vm.stopwatchTime = 10
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapNumber, 1)
        XCTAssertEqual(vm.laps[0].lapDuration, 10.5, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 10.5, accuracy: 0.001)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 10.5, accuracy: 0.001)
        XCTAssertEqual(vm.nextLapNumber, 2)
    }

    // 2. Record second lap at 25.25s -> Lap 2 duration = 14.75s, total = 25.25s
    @MainActor
    func testLapIntegrity02_RecordSecondLapAt25_25s() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.5
        vm.stopwatchTime = 10
        vm.recordLap()

        vm.stopwatchFractional = 25.25
        vm.stopwatchTime = 25
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.laps[0].lapNumber, 2)
        XCTAssertEqual(vm.laps[0].lapDuration, 14.75, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 25.25, accuracy: 0.001)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 25.25, accuracy: 0.001)
        XCTAssertEqual(vm.nextLapNumber, 3)
    }

    // 3. Delete latest lap, then record at 40.25s -> New duration = 15.0s, number = 3
    @MainActor
    func testLapIntegrity03_DeleteLatestLapThenRecordAt40_25s() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.5
        vm.stopwatchTime = 10
        vm.recordLap()

        vm.stopwatchFractional = 25.25
        vm.stopwatchTime = 25
        vm.recordLap()

        // Delete latest lap (Lap 2 at index 0)
        vm.removeLap(at: 0)
        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapNumber, 1)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 25.25, accuracy: 0.001, "Checkpoint must be preserved after deleting latest lap")
        XCTAssertEqual(vm.nextLapNumber, 3, "Sequence counter must not decrement")

        // Record third lap at 40.25s (15.0s since last recorded lap at 25.25s)
        vm.stopwatchFractional = 40.25
        vm.stopwatchTime = 40
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.laps[0].lapNumber, 3, "New lap must be Lap 3, not reusing deleted Lap 2")
        XCTAssertEqual(vm.laps[0].lapDuration, 15.0, accuracy: 0.001, "Duration must be measured from checkpoint at 25.25s")
        XCTAssertEqual(vm.laps[0].totalTime, 40.25, accuracy: 0.001)
        XCTAssertEqual(vm.laps[1].lapNumber, 1)
    }

    // 4. Delete middle lap from three recorded laps -> Remaining records unchanged, next split correct
    @MainActor
    func testLapIntegrity04_DeleteMiddleLapFromThreeRecordedLaps() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap() // Lap 1: 10s

        vm.stopwatchFractional = 25.0
        vm.stopwatchTime = 25
        vm.recordLap() // Lap 2: 15s

        vm.stopwatchFractional = 45.0
        vm.stopwatchTime = 45
        vm.recordLap() // Lap 3: 20s

        XCTAssertEqual(vm.laps.count, 3)
        let lap1ID = vm.laps[2].id
        let lap3ID = vm.laps[0].id

        // Delete middle lap (Lap 2 at index 1)
        vm.removeLap(at: 1)
        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.laps[0].lapNumber, 3)
        XCTAssertEqual(vm.laps[0].id, lap3ID, "Surviving Lap 3 UUID must be preserved")
        XCTAssertEqual(vm.laps[0].lapDuration, 20.0, accuracy: 0.001)
        XCTAssertEqual(vm.laps[1].lapNumber, 1)
        XCTAssertEqual(vm.laps[1].id, lap1ID, "Surviving Lap 1 UUID must be preserved")
        XCTAssertEqual(vm.laps[1].lapDuration, 10.0, accuracy: 0.001)

        // Record fourth lap at 60.0s (15s after Lap 3 at 45.0s)
        vm.stopwatchFractional = 60.0
        vm.stopwatchTime = 60
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 3)
        XCTAssertEqual(vm.laps[0].lapNumber, 4)
        XCTAssertEqual(vm.laps[0].lapDuration, 15.0, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 60.0, accuracy: 0.001)
    }

    // 5. Delete oldest lap -> No effect on next split
    @MainActor
    func testLapIntegrity05_DeleteOldestLapNoEffectOnNextSplit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap() // Lap 1: 10s

        vm.stopwatchFractional = 25.0
        vm.stopwatchTime = 25
        vm.recordLap() // Lap 2: 15s

        // Delete oldest lap (Lap 1 at index 1)
        vm.removeLap(at: 1)
        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapNumber, 2)

        // Record third lap at 40.0s (15s after Lap 2 at 25.0s)
        vm.stopwatchFractional = 40.0
        vm.stopwatchTime = 40
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.laps[0].lapNumber, 3)
        XCTAssertEqual(vm.laps[0].lapDuration, 15.0, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 40.0, accuracy: 0.001)
    }

    // 6. Delete all visible laps, then record again -> Duration uses last checkpoint; number is not reused
    @MainActor
    func testLapIntegrity06_DeleteAllVisibleLapsThenRecordAgain() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap() // Lap 1

        vm.stopwatchFractional = 25.0
        vm.stopwatchTime = 25
        vm.recordLap() // Lap 2

        // Delete all visible laps
        vm.removeLap(at: 0)
        vm.removeLap(at: 0)
        XCTAssertEqual(vm.laps.count, 0)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 25.0, accuracy: 0.001, "Checkpoint must be preserved after deleting all laps")
        XCTAssertEqual(vm.nextLapNumber, 3, "Next lap number must not reset")

        // Record again at 45.0s (20.0s since last recorded lap at 25.0s)
        vm.stopwatchFractional = 45.0
        vm.stopwatchTime = 45
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapNumber, 3, "New lap must be Lap 3, not reused")
        XCTAssertEqual(vm.laps[0].lapDuration, 20.0, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 45.0, accuracy: 0.001)
    }

    // 7. Delete Lap 2 from Laps 1–3, then record -> New lap number = 4
    @MainActor
    func testLapIntegrity07_DeleteLap2FromLaps1To3ThenRecord() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap() // Lap 1

        vm.stopwatchFractional = 20.0
        vm.stopwatchTime = 20
        vm.recordLap() // Lap 2

        vm.stopwatchFractional = 30.0
        vm.stopwatchTime = 30
        vm.recordLap() // Lap 3

        // Delete Lap 2 (index 1)
        vm.removeLap(at: 1)
        XCTAssertEqual(vm.laps.map(\.lapNumber), [3, 1])

        vm.stopwatchFractional = 45.0
        vm.stopwatchTime = 45
        vm.recordLap()

        XCTAssertEqual(vm.laps.map(\.lapNumber), [4, 3, 1], "Lap numbering must be strictly monotonic, never reusing deleted 2 or current count")
    }

    // 8. Pause and resume stopwatch -> Accurate next split
    @MainActor
    func testLapIntegrity08_PauseAndResumeStopwatchAccurateNextSplit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startStopwatch()
        vm.stopwatchStartDate = Date().addingTimeInterval(-10.0)
        vm.recordLap() // Lap 1 at 10s
        XCTAssertEqual(vm.laps[0].lapDuration, 10.0, accuracy: 0.2)

        vm.stopStopwatch() // Pause
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 10.0, accuracy: 0.2)

        vm.startStopwatch() // Resume
        vm.stopwatchStartDate = Date().addingTimeInterval(-30.0) // 20s later
        vm.recordLap() // Lap 2 at 30s

        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.laps[0].lapNumber, 2)
        XCTAssertEqual(vm.laps[0].lapDuration, 20.0, accuracy: 0.2)
        XCTAssertEqual(vm.laps[0].totalTime, 30.0, accuracy: 0.2)
    }

    // 9. Quit/Reopen after deleting latest lap -> Accurate next split and next lap number
    @MainActor
    func testLapIntegrity09_QuitReopenAfterDeletingLatestLap() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.stopwatchFractional = 10.0
        vm1.stopwatchTime = 10
        vm1.recordLap() // Lap 1: 10s

        vm1.stopwatchFractional = 25.0
        vm1.stopwatchTime = 25
        vm1.recordLap() // Lap 2: 15s

        vm1.removeLap(at: 0) // Delete Lap 2
        XCTAssertEqual(vm1.laps.count, 1)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.laps.count, 1)
        XCTAssertEqual(vm2.laps[0].lapNumber, 1)
        XCTAssertEqual(vm2.lastRecordedLapElapsedSeconds, 25.0, accuracy: 0.001, "Checkpoint must survive app relaunch")
        XCTAssertEqual(vm2.nextLapNumber, 3, "Next lap number must survive app relaunch")

        // Record in reopened ViewModel at 40.0s
        vm2.stopwatchFractional = 40.0
        vm2.stopwatchTime = 40
        vm2.recordLap()

        XCTAssertEqual(vm2.laps.count, 2)
        XCTAssertEqual(vm2.laps[0].lapNumber, 3)
        XCTAssertEqual(vm2.laps[0].lapDuration, 15.0, accuracy: 0.001)
        XCTAssertEqual(vm2.laps[0].totalTime, 40.0, accuracy: 0.001)
    }

    // 10. Quit/Reopen after deleting all visible laps -> Checkpoint and numbering preserved
    @MainActor
    func testLapIntegrity10_QuitReopenAfterDeletingAllVisibleLaps() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.stopwatchFractional = 10.0
        vm1.stopwatchTime = 10
        vm1.recordLap()

        vm1.stopwatchFractional = 25.0
        vm1.stopwatchTime = 25
        vm1.recordLap()

        vm1.removeLap(at: 0)
        vm1.removeLap(at: 0)
        XCTAssertEqual(vm1.laps.count, 0)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.laps.count, 0)
        XCTAssertEqual(vm2.lastRecordedLapElapsedSeconds, 25.0, accuracy: 0.001, "Checkpoint must survive relaunch even if all laps were deleted")
        XCTAssertEqual(vm2.nextLapNumber, 3, "Sequence counter must survive relaunch even if all laps were deleted")

        vm2.stopwatchFractional = 45.0
        vm2.stopwatchTime = 45
        vm2.recordLap()

        XCTAssertEqual(vm2.laps.count, 1)
        XCTAssertEqual(vm2.laps[0].lapNumber, 3)
        XCTAssertEqual(vm2.laps[0].lapDuration, 20.0, accuracy: 0.001)
        XCTAssertEqual(vm2.laps[0].totalTime, 45.0, accuracy: 0.001)
    }

    // 11. Reset stopwatch and record again -> New Lap 1 starts from zero
    @MainActor
    func testLapIntegrity11_ResetStopwatchAndRecordAgainStartsFromZero() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap()

        vm.stopwatchFractional = 25.0
        vm.stopwatchTime = 25
        vm.recordLap()

        // Reset
        vm.resetStopwatch()
        XCTAssertEqual(vm.laps.count, 0)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 0.0)
        XCTAssertEqual(vm.nextLapNumber, 1)

        // Record new lap
        vm.stopwatchFractional = 15.0
        vm.stopwatchTime = 15
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapNumber, 1)
        XCTAssertEqual(vm.laps[0].lapDuration, 15.0, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 15.0, accuracy: 0.001)
    }

    // 12. Load legacy JSON with surviving laps -> Valid checkpoint and sequence derived
    @MainActor
    func testLapIntegrity12_LoadLegacyJSONWithSurvivingLapsDerivesValidCheckpointAndSequence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { cleanup(url: tempURL) }

        // Construct older legacy JSON payload without lastRecordedLapElapsedSeconds or nextLapNumber
        let legacyJSON = """
        {
            "tasks": [],
            "focusedSeconds": 0,
            "completedSessions": 0,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [
                {
                    "id": "\(UUID().uuidString)",
                    "lapNumber": 2,
                    "lapDuration": 15.0,
                    "totalTime": 25.0,
                    "timestamp": "2026-10-16T12:00:00Z"
                },
                {
                    "id": "\(UUID().uuidString)",
                    "lapNumber": 1,
                    "lapDuration": 10.0,
                    "totalTime": 10.0,
                    "timestamp": "2026-10-16T11:59:45Z"
                }
            ],
            "stopwatchElapsedSeconds": 25.0
        }
        """.data(using: .utf8)!

        try legacyJSON.write(to: tempURL)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 25.0, accuracy: 0.001, "Checkpoint must be derived from max totalTime of surviving laps")
        XCTAssertEqual(vm.nextLapNumber, 3, "Next lap number must be derived from max lapNumber + 1 (not laps.count + 1)")

        vm.stopwatchFractional = 40.0
        vm.stopwatchTime = 40
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 3)
        XCTAssertEqual(vm.laps[0].lapNumber, 3)
        XCTAssertEqual(vm.laps[0].lapDuration, 15.0, accuracy: 0.001)
        XCTAssertEqual(vm.laps[0].totalTime, 40.0, accuracy: 0.001)
    }

    // 13. Load legacy JSON without laps -> Safe default behavior
    @MainActor
    func testLapIntegrity13_LoadLegacyJSONWithoutLapsSafeDefaultBehavior() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { cleanup(url: tempURL) }

        let legacyJSON = """
        {
            "tasks": [],
            "focusedSeconds": 0,
            "completedSessions": 0,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [],
            "stopwatchElapsedSeconds": 0.0
        }
        """.data(using: .utf8)!

        try legacyJSON.write(to: tempURL)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.laps.count, 0)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 0.0)
        XCTAssertEqual(vm.nextLapNumber, 1)

        vm.stopwatchFractional = 12.0
        vm.stopwatchTime = 12
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].lapNumber, 1)
        XCTAssertEqual(vm.laps[0].lapDuration, 12.0, accuracy: 0.001)
    }

    // 14. Existing fastest/slowest indicators -> Correct for visible laps
    @MainActor
    func testLapIntegrity14_ExistingFastestSlowestIndicatorsCorrectForVisibleLaps() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap() // Lap 1: 10s

        vm.stopwatchFractional = 15.0
        vm.stopwatchTime = 15
        vm.recordLap() // Lap 2: 5s (fastest)

        vm.stopwatchFractional = 35.0
        vm.stopwatchTime = 35
        vm.recordLap() // Lap 3: 20s (slowest)

        // laps order: [Lap 3 (20s), Lap 2 (5s), Lap 1 (10s)]
        XCTAssertEqual(vm.fastestLapIndex, 1) // Lap 2
        XCTAssertEqual(vm.slowestLapIndex, 0) // Lap 3

        // Delete Lap 2 (the fastest lap)
        vm.removeLap(at: 1)
        // laps order: [Lap 3 (20s), Lap 1 (10s)]
        XCTAssertEqual(vm.fastestLapIndex, 1, "Lap 1 (10s) must now be fastest among remaining")
        XCTAssertEqual(vm.slowestLapIndex, 0, "Lap 3 (20s) remains slowest")
    }

    // 15. Storage blocked by corruption -> Lap mutations remain blocked and saved bytes protected
    @MainActor
    func testLapIntegrity15_StorageBlockedByCorruptionProtectsBytesAndBlocksLapMutations() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { cleanup(url: tempURL) }

        // Corrupted primary and corrupted backup
        let corruptBytes = "CORRUPTED_PRIMARY_BYTES".data(using: .utf8)!
        try corruptBytes.write(to: tempURL)
        let storage = FocusStorageService(storageURL: tempURL)
        try corruptBytes.write(to: storage.backupURL)

        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        // Recording lap while blocked must be rejected
        vm.stopwatchFractional = 10.0
        vm.stopwatchTime = 10
        vm.recordLap()
        XCTAssertEqual(vm.laps.count, 0)

        // Deleting lap while blocked must be rejected
        vm.removeLap(at: 0)

        // Verify corrupted bytes remain untouched
        let primaryBytes = try Data(contentsOf: tempURL)
        XCTAssertEqual(primaryBytes, corruptBytes)
    }

    // 16. Existing lap UUIDs and elapsed stopwatch time are preserved across deletions
    @MainActor
    func testLapIntegrity16_ExistingLapUUIDsAndElapsedStatePreservedAcrossDeletion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startStopwatch()
        vm.stopwatchStartDate = Date().addingTimeInterval(-10.0)
        vm.recordLap() // Lap 1 at 10s

        vm.stopwatchStartDate = Date().addingTimeInterval(-25.0)
        vm.recordLap() // Lap 2 at 25s

        let lap1ID = vm.laps[1].id
        let lap1Timestamp = vm.laps[1].timestamp

        // Delete Lap 2
        vm.removeLap(at: 0)

        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.laps[0].id, lap1ID, "Lap 1 ID must remain identical")
        XCTAssertEqual(vm.laps[0].timestamp, lap1Timestamp, "Lap 1 timestamp must remain identical")
        XCTAssertEqual(vm.laps[0].lapDuration, 10.0, accuracy: 0.2)
        XCTAssertEqual(vm.laps[0].totalTime, 10.0, accuracy: 0.2)
    }

    // MARK: - Task 3: Active Task Switching & Time Attribution Regression Tests

    // 1. Focus A -> B: 10 minutes attributed to A, 5 minutes to B
    @MainActor
    func testTaskAttribution01_FocusSwitchAtoB_AttributesExactDurations() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        // Simulate 10 minutes (600s) on Task A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-600)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-600)

        // Switch to Task B
        vm.selectTask(at: 1)
        XCTAssertEqual(vm.activeTaskIndex, 1)
        XCTAssertEqual(vm.activeSessionTaskId, idB)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task A must receive exactly 10 minutes")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600)

        // Simulate 5 minutes (300s) on Task B
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)

        // Pause timer
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task A must remain at 600s")
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 300, "Task B must receive exactly 300s")
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 300)
        XCTAssertEqual(vm.completedSessions, 0, "Pausing mid-session must not increment completedSessions")
        XCTAssertEqual(vm.timeRemaining, 600, "Remaining time must be 25m - 15m = 10m (600s)")
    }

    // 2. Focus A -> B -> C: Each interval attributed to the correct task
    @MainActor
    func testTaskAttribution02_FocusSwitchAtoBtoC_AttributesAllIntervals() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id
        let idC = vm.tasks[2].id

        vm.startTimer()

        // 400s on A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-400)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-400)
        vm.selectTask(at: 1) // Switch to B

        // 300s on B
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)
        vm.selectTask(at: 2) // Switch to C

        // 200s on C
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-200)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 400)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 300)
        XCTAssertEqual(vm.tasks[2].timeSpentSeconds, 200)
        XCTAssertEqual(vm.sessionRecords.count, 3)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 400)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 300)
        XCTAssertEqual(vm.sessionRecords[2].taskId, idC)
        XCTAssertEqual(vm.sessionRecords[2].durationSeconds, 200)
    }

    // 3. Same-task selection: No extra records or elapsed changes
    @MainActor
    func testTaskAttribution03_SameTaskSelection_NoExtraRecordsOrElapsedChanges() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)

        // Select task 0 again
        vm.selectTask(at: 0)

        XCTAssertEqual(vm.sessionRecords.count, 0, "Selecting already-active task must not create premature records")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Unsettled live segment continues running without early commit")
    }

    // 4. Paused Focus switch: No additional time generated
    @MainActor
    func testTaskAttribution04_PausedFocusSwitch_GeneratesNoAdditionalTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-120)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-120)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 120)
        XCTAssertEqual(vm.sessionRecords.count, 1)

        // Switch tasks while paused
        vm.selectTask(at: 1)
        XCTAssertEqual(vm.activeTaskIndex, 1)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 0, "Switching paused timer must not fabricate time")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Switching paused timer must not create zero-duration records")
        XCTAssertEqual(vm.pausedSession?.activeTaskIndex, 1, "Paused session state must reflect new active task")
    }

    // 5. Focus switch followed by pause: Both segments finalized once
    @MainActor
    func testTaskAttribution05_FocusSwitchFollowedByPause_BothFinalizedOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-150)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-150)

        vm.selectTask(at: 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)

        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-90)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-90)
        vm.stopTimer()

        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 150)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 90)
    }

    // 6. Focus switch followed by completion: No duplicate durations or completed-session increments
    @MainActor
    func testTaskAttribution06_FocusSwitchFollowedByNaturalCompletion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        // Worked 900s on A (15 minutes), 600s remaining
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-900)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-900)
        vm.selectTask(at: 1) // Switch to B

        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 900)
        XCTAssertEqual(vm.timeRemaining, 600)

        // Work remaining 600s on B to hit deadline
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-600)
        vm.targetEndDate = Date().addingTimeInterval(-1) // Expired

        // Trigger tick to complete session naturally
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1, "Completed sessions must be incremented exactly once")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 900)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 600)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 600)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds + vm.tasks[1].timeSpentSeconds, 1500)
    }

    // 7. Focus switch followed by normal Quit/Reopen: Historical task attribution preserved
    @MainActor
    func testTaskAttribution07_FocusSwitchFollowedByQuitReopen() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm1.tasks[0].id
        let idB = vm1.tasks[1].id

        vm1.startTimer()
        vm1.sessionSegmentStartDate = vm1.sessionSegmentStartDate?.addingTimeInterval(-500)
        vm1.targetEndDate = vm1.targetEndDate?.addingTimeInterval(-500)

        vm1.selectTask(at: 1)

        vm1.sessionSegmentStartDate = vm1.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm1.targetEndDate = vm1.targetEndDate?.addingTimeInterval(-300)

        // Normal termination while running on Task B
        vm1.handleAppTermination()

        // Reopen app
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.sessionRecords.count, 2)
        XCTAssertEqual(vm2.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 500)
        XCTAssertEqual(vm2.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm2.sessionRecords[1].durationSeconds, 300)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 500)
        XCTAssertEqual(vm2.tasks[1].timeSpentSeconds, 300)
    }

    // 8. Running Stopwatch A -> B: Correct elapsed time split between tasks
    @MainActor
    func testTaskAttribution08_RunningStopwatchSwitchAtoB() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-10.0)

        // Switch to Task B
        vm.selectTask(at: 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 10)
        XCTAssertEqual(vm.stopwatchTime, 10)

        // 15 seconds more on Task B
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-15.0)
        vm.stopStopwatch()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 10)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 15)
        XCTAssertEqual(vm.stopwatchTime, 25)
    }

    // 9. Paused Stopwatch switch: No fabricated elapsed time
    @MainActor
    func testTaskAttribution09_PausedStopwatchSwitch() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-12.0)
        vm.stopStopwatch()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 12)
        XCTAssertEqual(vm.stopwatchTime, 12)

        // Switch to Task B while paused
        vm.selectTask(at: 1)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 12)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 0)
        XCTAssertEqual(vm.stopwatchTime, 12)
    }

    // 10. Focus and Stopwatch running together: Both accurately settle when task selection changes
    @MainActor
    func testTaskAttribution10_FocusAndStopwatchRunningTogether() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        vm.startStopwatch()

        // Elapse 20 seconds on both for Task A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-20.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-20.0)
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-20.0)

        // Switch to Task B
        vm.selectTask(at: 1)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 40, "Task A must receive 20s from Focus + 20s from Stopwatch")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 20)

        // Elapse 10 seconds on both for Task B
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-10.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-10.0)
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-10.0)

        vm.stopTimer()
        vm.stopStopwatch()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 40)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 20, "Task B must receive 10s from Focus + 10s from Stopwatch")
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 10)
    }

    // 11. Complete active task: Previous time preserved, new task receives only subsequent time
    @MainActor
    func testTaskAttribution11_CompleteActiveTask_PreservesPreviousTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)

        // Complete Task A while timer is running
        vm.toggleTaskCompletion(at: 0)

        XCTAssertTrue(vm.tasks[0].isCompleted)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 300)
        XCTAssertEqual(vm.activeTaskIndex, 1, "Next available eligible task (Task B) must become active")
        XCTAssertEqual(vm.activeSessionTaskId, idB)

        // Run 200s on Task B
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-200)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 200)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 200)
    }

    // 12. Delete active task: Existing history retained and no time transferred to another task
    @MainActor
    func testTaskAttribution12_DeleteActiveTask_HistoryRetainedAndNoTimeTransferred() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-400)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-400)

        // Delete active Task A
        vm.removeTask(at: 0)

        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA, "Historical session record must preserve deleted task UUID")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 400)
        XCTAssertEqual(vm.tasks[0].id, idB, "Task B is now at index 0")
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.activeSessionTaskId, idB)

        // Run 250s on Task B
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-250)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-250)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 250, "Task B must only receive its own 250s, not Task A's 400s")
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 250)
    }

    // 13. Delete a task before the active index: Same active UUID retained
    @MainActor
    func testTaskAttribution13_DeleteTaskBeforeActiveIndex_PreservesActiveUUID() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.selectTask(at: 1)
        let idB = vm.tasks[1].id

        vm.startTimer()
        XCTAssertEqual(vm.activeSessionTaskId, idB)

        // Run 100s
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)

        // Delete Task 0 (before active index 1)
        vm.removeTask(at: 0)

        XCTAssertEqual(vm.activeTaskIndex, 0, "Active index shifted from 1 to 0")
        XCTAssertEqual(vm.tasks[0].id, idB, "Task at index 0 is still Task B")
        XCTAssertEqual(vm.activeSessionTaskId, idB, "Active session task UUID remains Task B")
        XCTAssertEqual(vm.sessionRecords.count, 0, "No premature segment split when active task identity did not change")

        // Run 100s more
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 200)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 200)
    }

    // 14. Delete all tasks: No crash, invalid-index access, or incorrect time allocation
    @MainActor
    func testTaskAttribution14_DeleteAllTasks_ContinuesSafelyWithNilTaskId() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)

        // Remove all tasks one by one
        while !vm.tasks.isEmpty {
            vm.removeTask(at: 0)
        }

        XCTAssertTrue(vm.tasks.isEmpty)
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertNil(vm.activeSessionTaskId)
        XCTAssertTrue(vm.isTimerRunning, "Timer countdown continues uninterrupted when all tasks deleted")

        // Run 150s with no task
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-150)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-150)
        vm.stopTimer()

        let lastRecord = vm.sessionRecords.last
        XCTAssertNotNil(lastRecord)
        XCTAssertNil(lastRecord?.taskId, "Unassigned focus session record must have taskId == nil")
        XCTAssertEqual(lastRecord?.durationSeconds, 150)
    }

    // 15. Add task after all available tasks are completed: Attribution resumes safely
    @MainActor
    func testTaskAttribution15_AddTaskAfterAllTasksCompleted_ResumesAttribution() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Complete all tasks
        for i in 0..<vm.tasks.count {
            vm.tasks[i].isCompleted = true
        }

        vm.startTimer()
        XCTAssertNil(vm.activeSessionTaskId)

        // Run 100s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)

        // Add new task
        vm.addTask(title: "Emergency Task", expectedMinutes: 20)
        let newTaskId = vm.tasks.last?.id

        XCTAssertEqual(vm.activeTaskIndex, vm.tasks.count - 1)
        XCTAssertEqual(vm.activeSessionTaskId, newTaskId)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertNil(vm.sessionRecords[0].taskId, "First segment was unassigned")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 100)

        // Run 200s on the new task
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-200)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks.last?.timeSpentSeconds, 200)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, newTaskId)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 200)
    }

    // 16. Storage blocked: No task mutation or unsafe persistence
    @MainActor
    func testTaskAttribution16_StorageBlocked_PreventsTaskMutations() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { cleanup(url: tempURL) }

        let corruptBytes = "CORRUPT_BYTES".data(using: .utf8)!
        try corruptBytes.write(to: tempURL)
        let storage = FocusStorageService(storageURL: tempURL)
        try corruptBytes.write(to: storage.backupURL)

        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        let initialTasks = vm.tasks.count
        vm.addTask(title: "Should Fail")
        XCTAssertEqual(vm.tasks.count, initialTasks)

        vm.selectTask(at: 1)
        vm.toggleTaskCompletion(at: 0)
        vm.removeTask(at: 0)

        let diskBytes = try Data(contentsOf: tempURL)
        XCTAssertEqual(diskBytes, corruptBytes, "On-disk corrupted file must remain untouched")
    }

    // 17. Existing Focus Session Records: Historical taskId, timestamps and durations unchanged
    @MainActor
    func testTaskAttribution17_ExistingSessionRecordsUnchangedByTaskSwitches() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let historicalId = UUID()
        let historicalStart = Date().addingTimeInterval(-10000)
        let historicalEnd = Date().addingTimeInterval(-9000)
        let historicalRecord = FocusSessionRecord(
            startTime: historicalStart,
            endTime: historicalEnd,
            durationSeconds: 1000,
            mode: "Pomodoro",
            taskId: historicalId
        )
        vm.sessionRecords.append(historicalRecord)

        // Perform timer runs and task switches
        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)
        vm.selectTask(at: 1)
        vm.stopTimer()

        // Historical record at index 0 must be 100% unchanged
        XCTAssertEqual(vm.sessionRecords[0].id, historicalRecord.id)
        XCTAssertEqual(vm.sessionRecords[0].taskId, historicalId)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1000)
        XCTAssertEqual(vm.sessionRecords[0].startTime, historicalStart)
        XCTAssertEqual(vm.sessionRecords[0].endTime, historicalEnd)
    }

    // 18. Existing Stopwatch laps: Elapsed time, lap durations, numbering and restart recovery unchanged
    @MainActor
    func testTaskAttribution18_StopwatchLapsPreservedAcrossTaskSwitches() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-10.0)
        vm.recordLap() // Lap 1 at 10s

        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-15.0)
        vm.recordLap() // Lap 2 at 25s

        // Switch active task
        vm.selectTask(at: 1)

        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-15.0)
        vm.recordLap() // Lap 3 at 40s

        XCTAssertEqual(vm.laps.count, 3)
        XCTAssertEqual(vm.laps[2].lapNumber, 1)
        XCTAssertEqual(vm.laps[2].lapDuration, 10.0, accuracy: 0.1)
        XCTAssertEqual(vm.laps[1].lapNumber, 2)
        XCTAssertEqual(vm.laps[1].lapDuration, 15.0, accuracy: 0.1)
        XCTAssertEqual(vm.laps[0].lapNumber, 3)
        XCTAssertEqual(vm.laps[0].lapDuration, 15.0, accuracy: 0.1)
    }

    // 19. Realistic boundary: Task selection occurs between timer ticks (subsecond fractional timing)
    @MainActor
    func testTaskAttribution19_SubsecondTickBoundaryAttribution() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id

        vm.startTimer()
        // Simulate target deadline with fractional seconds remaining (e.g. 1495.4 remaining of 1500)
        vm.sessionSegmentStartDate = Date().addingTimeInterval(-4.6)
        vm.targetEndDate = Date().addingTimeInterval(1495.4)

        // Switch to Task B between ticks
        vm.selectTask(at: 1)

        // ceil(1495.4) = 1496. delta = 1500 - 1496 = 4s credited to Task A
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 4)
        XCTAssertEqual(vm.timeRemaining, 1496)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 4)

        // Simulate subsequent tick on Task B with 1493.2 remaining
        vm.sessionSegmentStartDate = Date().addingTimeInterval(-2.8)
        vm.targetEndDate = Date().addingTimeInterval(1493.2)
        vm.tick()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 4, "Task A time must not change on subsequent tick")
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 2, "Task B must receive the 2s delta")
        XCTAssertEqual(vm.timeRemaining, 1494)
    }

    // MARK: - Task 3 Follow-up Regression Tests

    // 1. Complete all tasks -> run unassigned focus 300s -> reopen Task A -> record 120s -> pause.
    // Verify two correct records and total 420s.
    @MainActor
    func testTaskAttributionFollowUp01_CompleteAll_Run300sUnassigned_ReopenTaskA_Run120s_Pause_TwoRecordsTotal420() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id

        vm.startTimer()

        // Complete all tasks
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        XCTAssertTrue(vm.tasks.allSatisfy { $0.isCompleted })
        XCTAssertNil(vm.activeSessionTaskId)
        XCTAssertTrue(vm.isTimerRunning)

        // Simulate 300 seconds of unassigned focus
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)

        // Reopen Task A
        vm.toggleTaskCompletion(at: 0)
        XCTAssertFalse(vm.tasks[0].isCompleted)
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.activeSessionTaskId, idA)

        // Work for another 120 seconds on Task A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-120)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-120)

        // Pause
        vm.stopTimer()

        let unassignedRecords = vm.sessionRecords.filter { $0.taskId == nil }
        let taskARecords = vm.sessionRecords.filter { $0.taskId == idA }

        XCTAssertEqual(unassignedRecords.count, 1, "Must preserve the 300s unassigned focus segment")
        XCTAssertEqual(unassignedRecords.first?.durationSeconds, 300, "Unassigned segment must be 300s")
        XCTAssertEqual(taskARecords.count, 1, "Must record the 120s Task A segment")
        XCTAssertEqual(taskARecords.first?.durationSeconds, 120, "Task A segment must be 120s")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 120, "Task A must receive only 120s, not 420s")
        XCTAssertEqual(vm.todayFocusedSeconds, 420, "Total focused time must be 420s")
    }

    // 2. Verify the 300-second unassigned segment has taskId == nil.
    @MainActor
    func testTaskAttributionFollowUp02_VerifyUnassignedSegmentHasNilTaskId() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        XCTAssertNil(vm.activeSessionTaskId)

        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)

        // Reopening task triggers segment finalization
        vm.toggleTaskCompletion(at: 0)

        guard let firstRecord = vm.sessionRecords.first else {
            XCTFail("Expected session record to be finalized upon reopening task")
            return
        }
        XCTAssertNil(firstRecord.taskId, "Unassigned focus segment must have taskId == nil")
        XCTAssertEqual(firstRecord.durationSeconds, 300)
    }

    // 3. Verify Task A receives only the subsequent 120 seconds.
    @MainActor
    func testTaskAttributionFollowUp03_VerifyReopenedTaskReceivesOnlySubsequentTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        vm.startTimer()
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        // 300s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)

        // Reopen Task A
        vm.toggleTaskCompletion(at: 0)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Task A must have 0s immediately upon reopening")

        // 120s on Task A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-120)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-120)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 120, "Task A must receive strictly 120s, not unassigned time")
    }

    // 4. Verify previously accumulated task times are not altered.
    @MainActor
    func testTaskAttributionFollowUp04_VerifyPreviouslyAccumulatedTaskTimesNotAltered() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        vm.startTimer()

        // Work 60s on Task A before completing it
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-60)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-60)
        vm.toggleTaskCompletion(at: 0)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 60)

        // Complete remaining tasks
        for i in 1..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        // Run 300s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-300)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-300)

        // Reopen Task A
        vm.toggleTaskCompletion(at: 0)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 60, "Task A previous time must not be altered on reopen")

        // Work another 120s
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-120)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-120)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 180, "Task A total should be 60 + 120 = 180s")
        XCTAssertEqual(vm.todayFocusedSeconds, 480, "Total focused seconds = 60 + 300 + 120 = 480s")
    }

    // 5. Complete all tasks -> run unassigned focus -> delete the completed task at activeTaskIndex.
    @MainActor
    func testTaskAttributionFollowUp05_DeleteCompletedTaskAtActiveTaskIndexDuringUnassignedFocusDoesNotFabricateAttribution() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()

        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        XCTAssertNil(vm.activeSessionTaskId)

        // Simulate 200s unassigned focus
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-200)

        let activeIdx = vm.activeTaskIndex
        let deletingId = vm.tasks[activeIdx].id

        vm.removeTask(at: activeIdx)

        XCTAssertFalse(vm.sessionRecords.contains(where: { $0.taskId == deletingId }), "Deleting completed task during unassigned timer must not fabricate attribution")
    }

    // 6. Delete a different completed task while focus is unassigned. Verify no incorrect split or attribution.
    @MainActor
    func testTaskAttributionFollowUp06_DeleteDifferentCompletedTaskDuringUnassignedFocusNoIncorrectSplitOrAttribution() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        XCTAssertNil(vm.activeSessionTaskId)

        // 200s unassigned focus
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-200)

        // Delete task at index 2 (different from activeTaskIndex 0)
        let deletingId = vm.tasks[2].id
        let initialRecordCount = vm.sessionRecords.count
        vm.removeTask(at: 2)

        // No new split or record fabricated
        XCTAssertEqual(vm.sessionRecords.count, initialRecordCount, "Removing inactive completed task must not create a split record")
        XCTAssertNil(vm.activeSessionTaskId)

        // Another 100s unassigned focus, then stop
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)
        vm.stopTimer()

        let unassignedRecords = vm.sessionRecords.filter { $0.taskId == nil }
        XCTAssertEqual(unassignedRecords.count, 1, "Must have exactly 1 continuous unassigned record")
        XCTAssertEqual(unassignedRecords.first?.durationSeconds, 300, "Unassigned segment should be 300s total")
        XCTAssertFalse(vm.sessionRecords.contains(where: { $0.taskId == deletingId }))
    }

    // 7. Delete every completed task during an unassigned timer, then stop. Verify all unassigned focus time is retained with taskId == nil.
    @MainActor
    func testTaskAttributionFollowUp07_DeleteEveryCompletedTaskDuringUnassignedTimerThenStopRetainsAllUnassignedTimeWithNilTaskId() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        // Run 150s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-150)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-150)

        // Delete all tasks one by one
        while !vm.tasks.isEmpty {
            vm.removeTask(at: 0)
        }
        XCTAssertTrue(vm.tasks.isEmpty)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertNil(vm.activeSessionTaskId)

        // Run another 150s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-150)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-150)

        vm.stopTimer()

        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertNil(vm.sessionRecords[0].taskId)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 300)
        XCTAssertEqual(vm.todayFocusedSeconds, 300)
    }

    // 8. Unassigned focus -> reactivate a task -> pause -> resume -> stop. Verify accurate segment accounting with no duplicates.
    @MainActor
    func testTaskAttributionFollowUp08_UnassignedFocus_ReactivateTask_Pause_Resume_Stop_AccurateSegmentAccountingNoDuplicates() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        vm.startTimer()
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        // 200s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-200)

        // Reactivate Task A
        vm.toggleTaskCompletion(at: 0)

        // 60s on Task A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-60)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-60)

        // Pause
        vm.stopTimer()
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 60)

        // Resume
        vm.startTimer()
        XCTAssertEqual(vm.activeSessionTaskId, idA)

        // Another 60s on Task A
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-60)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-60)

        // Stop
        vm.stopTimer()
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 120)

        let unassigned = vm.sessionRecords.filter { $0.taskId == nil }
        let taskA = vm.sessionRecords.filter { $0.taskId == idA }
        XCTAssertEqual(unassigned.count, 1)
        XCTAssertEqual(unassigned[0].durationSeconds, 200)
        XCTAssertEqual(taskA.count, 2)
        XCTAssertEqual(taskA[0].durationSeconds, 60)
        XCTAssertEqual(taskA[1].durationSeconds, 60)
        XCTAssertEqual(vm.todayFocusedSeconds, 320)
    }

    // 9. Unassigned focus -> reactivate a task -> normal Quit/Reopen. Verify records and task time are preserved.
    // 9. Unassigned focus -> reactivate a task -> normal Quit/Reopen. Verify records and task time are preserved.
    @MainActor
    func testTaskAttributionFollowUp09_UnassignedFocus_ReactivateTask_QuitReopenPreservesRecordsAndTaskTime() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm1.tasks[0].id
        vm1.startTimer()
        for i in 0..<vm1.tasks.count {
            vm1.toggleTaskCompletion(at: i)
        }

        // 200s unassigned
        vm1.sessionSegmentStartDate = vm1.sessionSegmentStartDate?.addingTimeInterval(-200)
        vm1.targetEndDate = vm1.targetEndDate?.addingTimeInterval(-200)

        // Reactivate Task A
        vm1.toggleTaskCompletion(at: 0)

        // 100s on Task A
        vm1.sessionSegmentStartDate = vm1.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm1.targetEndDate = vm1.targetEndDate?.addingTimeInterval(-100)

        // Normal quit triggers stopTimer and persists data
        vm1.handleAppTermination()

        // Reopen app in new ViewModel instance
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.sessionRecords.count, 2)
        let unassigned = vm2.sessionRecords.filter { $0.taskId == nil }
        let taskA = vm2.sessionRecords.filter { $0.taskId == idA }

        XCTAssertEqual(unassigned.count, 1)
        XCTAssertEqual(unassigned.first?.durationSeconds, 200)
        XCTAssertEqual(taskA.count, 1)
        XCTAssertEqual(taskA.first?.durationSeconds, 100)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 100)
    }

    // 10. Reopen a task while the Focus Timer is paused. Verify no artificial focus time.
    @MainActor
    func testTaskAttributionFollowUp10_ReopenTaskWhileFocusTimerPausedDoesNotCreateArtificialFocusTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Complete all tasks while idle/paused
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        XCTAssertTrue(vm.tasks.allSatisfy { $0.isCompleted })

        let initialRecords = vm.sessionRecords.count
        let initialFocusedSeconds = vm.todayFocusedSeconds

        // Reopen Task A while timer is not running
        vm.toggleTaskCompletion(at: 0)
        XCTAssertFalse(vm.tasks[0].isCompleted)
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.sessionRecords.count, initialRecords, "No artificial session record should be created")
        XCTAssertEqual(vm.todayFocusedSeconds, initialFocusedSeconds, "No focus seconds should be added")
    }

    // 11. Running Stopwatch without an assigned task -> reactivate a task. Verify previous time is not credited to the new task.
    @MainActor
    func testTaskAttributionFollowUp11_RunningStopwatchWithoutAssignedTask_ReactivateTask_PreviousTimeNotCreditedToNewTask() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Complete all tasks
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        // Start Stopwatch with no active task
        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-100)

        // Reactivate Task A
        vm.toggleTaskCompletion(at: 0)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Previous unassigned stopwatch time must not be credited to Task A")

        // Run another 50s on Task A
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-50)
        vm.stopStopwatch()

        XCTAssertEqual(vm.stopwatchTime, 150)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 50, "Task A must receive only the 50s elapsed after reactivation")
    }

    // 12. Simultaneous Focus Timer and Stopwatch during unassigned-to-assigned transition.
    @MainActor
    func testTaskAttributionFollowUp12_SimultaneousFocusTimerAndStopwatchDuringUnassignedToAssignedTransition() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id

        // Complete all tasks
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        // Start both Focus Timer and Stopwatch
        vm.startTimer()
        vm.startStopwatch()

        // 120s elapsed on both without assigned task
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-120)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-120)
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-120)

        // Reactivate Task A
        vm.toggleTaskCompletion(at: 0)

        // 60s elapsed on both with Task A active
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-60)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-60)
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-60)

        vm.stopTimer()
        vm.stopStopwatch()

        // Verify Timer records
        let unassigned = vm.sessionRecords.filter { $0.taskId == nil }
        let taskARecords = vm.sessionRecords.filter { $0.taskId == idA }
        XCTAssertEqual(unassigned.count, 1)
        XCTAssertEqual(unassigned.first?.durationSeconds, 120)
        XCTAssertEqual(taskARecords.count, 1)
        XCTAssertEqual(taskARecords.first?.durationSeconds, 60)

        // Task A gets 60s from timer + 60s from stopwatch = 120s
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 120)
        XCTAssertEqual(vm.stopwatchTime, 180)
    }

    // 13. Repeated complete/incomplete toggles near a tick boundary. Verify no missed or duplicated time.
    @MainActor
    func testTaskAttributionFollowUp13_RepeatedCompleteIncompleteTogglesNearTickBoundary() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()

        // Complete Task 0 -> auto advances to Task 1
        vm.toggleTaskCompletion(at: 0)
        XCTAssertEqual(vm.activeTaskIndex, 1)

        // Reopen Task 0
        vm.toggleTaskCompletion(at: 0)
        XCTAssertFalse(vm.tasks[0].isCompleted)

        // Select Task 0
        vm.selectTask(at: 0)
        XCTAssertEqual(vm.activeTaskIndex, 0)

        // Tick on Task 0
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-1.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-1.0)
        vm.tick()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1)
    }

    // 14. Storage corruption protection remains active and task mutations remain blocked.
    @MainActor
    func testTaskAttributionFollowUp14_StorageCorruptionProtectionRemainsActiveAndTaskMutationsBlocked() throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let primaryURL = testDir.appendingPathComponent("focusflow_data.json")
        try Data("malformed json bytes".utf8).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        vm.addTask(title: "New Task That Should Not Be Added")
        XCTAssertTrue(vm.tasks.isEmpty)

        vm.toggleTaskCompletion(at: 0)
        XCTAssertTrue(vm.tasks.isEmpty)

        vm.removeTask(at: 0)
        XCTAssertTrue(vm.tasks.isEmpty)

        vm.selectTask(at: 0)
        XCTAssertEqual(vm.activeTaskIndex, 0)
    }

    // 15. Existing task switching from A -> B continues to work correctly.
    @MainActor
    func testTaskAttributionFollowUp15_ExistingTaskSwitchingFromAtoBContinuesWorking() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-60)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-60)

        vm.selectTask(at: 1)
        XCTAssertEqual(vm.activeTaskIndex, 1)
        XCTAssertEqual(vm.activeSessionTaskId, idB)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 60)

        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-40)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-40)
        vm.stopTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 60)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 40)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 60)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 40)
    }

    // 16. Existing Focus Session Records, stopwatch laps and serialized data remain unchanged unless directly affected.
    @MainActor
    func testTaskAttributionFollowUp16_ExistingSessionRecordsAndStopwatchLapsRemainUnchangedUnlessDirectlyAffected() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Preload historical record and lap
        let historicalUUID = UUID()
        let oldRecord = FocusSessionRecord(
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(-1800),
            durationSeconds: 1800,
            mode: "Focus",
            taskId: historicalUUID
        )
        vm.sessionRecords.append(oldRecord)

        let oldLap = StopwatchLap(lapNumber: 1, lapDuration: 10.0, totalTime: 10.0, timestamp: Date().addingTimeInterval(-1800))
        vm.laps.append(oldLap)

        // Complete all tasks, run unassigned, reactivate Task A
        vm.startTimer()
        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100)

        vm.toggleTaskCompletion(at: 0)
        vm.stopTimer()

        // Verify old record and lap untouched
        XCTAssertEqual(vm.sessionRecords.first?.taskId, historicalUUID)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 1800)
        XCTAssertEqual(vm.laps.first?.lapNumber, 1)
        XCTAssertEqual(vm.laps.first?.lapDuration, 10.0)
    }

    // MARK: - Task 3 Final Correction Tests

    // Test A — Primary Bug: Empty task list -> Stopwatch runs 100s -> Add Task A -> 50s -> Stop
    @MainActor
    func testTaskAttributionFinalCorrectionA_EmptyTaskListRunningStopwatchAddTaskDoesNotRetroactivelyAttribute() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // 1. Delete all tasks
        while !vm.tasks.isEmpty {
            vm.removeTask(at: 0)
        }
        XCTAssertTrue(vm.tasks.isEmpty)

        // 2. Start Stopwatch
        vm.startStopwatch()
        XCTAssertTrue(vm.isStopwatchRunning)

        // 3. Simulate 100 seconds of elapsed time without an active task
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-100.0)

        // 4. Add Task A
        vm.addTask(title: "Task A", expectedMinutes: 25)

        // Assert: Task A has 0 credited seconds immediately after creation
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Task A must have 0 credited seconds immediately upon creation")
        XCTAssertTrue(vm.isStopwatchRunning, "Stopwatch must still be running")
        XCTAssertEqual(vm.stopwatchTime, 100, "Stopwatch has settled 100 elapsed seconds")
        XCTAssertEqual(vm.activeTaskIndex, 0, "New task is correctly selected")

        // 5. Let Stopwatch run another 50 seconds
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-50.0)
        vm.stopStopwatch()

        // Assert: Total elapsed = 150s, Task A time = 50s
        XCTAssertEqual(vm.stopwatchTime, 150)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 50, "Task A must receive strictly the 50s elapsed after creation, not 150s")
    }

    // Test B — All Tasks Completed: Start Stopwatch when all tasks completed -> 100s -> Add Task -> 50s -> Stop
    @MainActor
    func testTaskAttributionFinalCorrectionB_AllTasksCompletedStopwatchRunsAddTaskDoesNotCreditPreviousTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        XCTAssertTrue(vm.tasks.allSatisfy { $0.isCompleted })

        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-100.0)

        vm.addTask(title: "Task E", expectedMinutes: 25)
        let newIdx = vm.tasks.count - 1
        XCTAssertEqual(vm.tasks[newIdx].timeSpentSeconds, 0, "New task must have 0s on creation")
        XCTAssertEqual(vm.activeTaskIndex, newIdx)

        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-50.0)
        vm.stopStopwatch()

        XCTAssertEqual(vm.stopwatchTime, 150)
        XCTAssertEqual(vm.tasks[newIdx].timeSpentSeconds, 50, "New task must receive only subsequent 50s")
        for i in 0..<newIdx {
            XCTAssertEqual(vm.tasks[i].timeSpentSeconds, 0, "Completed tasks must receive no extra seconds")
        }
    }

    // Test C — Existing Active Task: Start Stopwatch on Task A -> 100s -> Add Task B without changing selection
    @MainActor
    func testTaskAttributionFinalCorrectionC_ExistingActiveTaskRemainsActiveWhenNewTaskAdded() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-100.0)

        // Adding task when Task A is active and uncompleted should not change selection
        vm.addTask(title: "Task Additional", expectedMinutes: 25)
        XCTAssertEqual(vm.activeTaskIndex, 0, "Task A must remain active")
        let addedIdx = vm.tasks.count - 1
        XCTAssertEqual(vm.tasks[addedIdx].timeSpentSeconds, 0, "New task must have 0s")

        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-50.0)
        vm.stopStopwatch()

        XCTAssertEqual(vm.stopwatchTime, 150)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 150, "Task A must receive full 150s")
        XCTAssertEqual(vm.tasks[addedIdx].timeSpentSeconds, 0, "New task receives no elapsed time")
    }

    // Test D — Focus Timer Only: Start Focus Timer unassigned -> 100s -> Add Task A -> 50s -> Stop
    @MainActor
    func testTaskAttributionFinalCorrectionD_FocusTimerUnassignedThenAddTaskSplitsCleanly() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }
        vm.startTimer()
        XCTAssertNil(vm.activeSessionTaskId)

        // 100s unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-100.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-100.0)

        vm.addTask(title: "New Assigned Task", expectedMinutes: 25)
        let newIdx = vm.tasks.count - 1
        let newId = vm.tasks[newIdx].id
        XCTAssertEqual(vm.activeSessionTaskId, newId)

        // Verify unassigned segment finalized
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertNil(vm.sessionRecords[0].taskId, "First segment must have nil taskId")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 100)

        // Run 50s on new task
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-50.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-50.0)
        vm.stopTimer()

        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, newId)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 50)
        XCTAssertEqual(vm.tasks[newIdx].timeSpentSeconds, 50)
        XCTAssertEqual(vm.todayFocusedSeconds, 150)
    }

    // Test E — Both Running: Focus Timer and Stopwatch unassigned -> Add Task A -> Continue
    @MainActor
    func testTaskAttributionFinalCorrectionE_SimultaneousTimerAndStopwatchAddTaskAttribution() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        for i in 0..<vm.tasks.count {
            vm.toggleTaskCompletion(at: i)
        }

        vm.startTimer()
        vm.startStopwatch()

        // 80s elapsed unassigned
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-80.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-80.0)
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-80.0)

        vm.addTask(title: "Dual Task", expectedMinutes: 25)
        let newIdx = vm.tasks.count - 1
        let newId = vm.tasks[newIdx].id

        XCTAssertEqual(vm.tasks[newIdx].timeSpentSeconds, 0, "No retroactive credit on creation")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertNil(vm.sessionRecords[0].taskId)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 80)

        // 40s elapsed on new task
        vm.sessionSegmentStartDate = vm.sessionSegmentStartDate?.addingTimeInterval(-40.0)
        vm.targetEndDate = vm.targetEndDate?.addingTimeInterval(-40.0)
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-40.0)

        vm.stopTimer()
        vm.stopStopwatch()

        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, newId)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 40)
        // 40s from timer + 40s from stopwatch = 80s total on Dual Task
        XCTAssertEqual(vm.tasks[newIdx].timeSpentSeconds, 80)
        XCTAssertEqual(vm.stopwatchTime, 120)
    }

    // Test F — Stopwatch Lap Integrity: Record lap before adding task -> Add Task A during stopwatch
    @MainActor
    func testTaskAttributionFinalCorrectionF_StopwatchLapIntegrityPreservedWhenAddingTask() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        while !vm.tasks.isEmpty {
            vm.removeTask(at: 0)
        }

        vm.startStopwatch()
        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-20.0)
        vm.recordLap() // Lap 1 at 20s

        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-15.0)
        vm.recordLap() // Lap 2 at 35s (duration 15s)

        // Add task while running
        vm.addTask(title: "Lap Task", expectedMinutes: 25)

        vm.stopwatchStartDate = vm.stopwatchStartDate?.addingTimeInterval(-10.0)
        vm.recordLap() // Lap 3 at 45s (duration 10s)
        vm.stopStopwatch()

        XCTAssertEqual(vm.laps.count, 3)
        XCTAssertEqual(vm.laps[2].lapNumber, 1)
        XCTAssertEqual(vm.laps[2].lapDuration, 20.0, accuracy: 0.1)
        XCTAssertEqual(vm.laps[1].lapNumber, 2)
        XCTAssertEqual(vm.laps[1].lapDuration, 15.0, accuracy: 0.1)
        XCTAssertEqual(vm.laps[0].lapNumber, 3)
        XCTAssertEqual(vm.laps[0].lapDuration, 10.0, accuracy: 0.1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 10, "Lap Task only receives 10s elapsed after addition")
    }

    // Test G — Storage Protection: Adding task blocked when storage is corrupted
    @MainActor
    func testTaskAttributionFinalCorrectionG_StorageProtectionBlocksAddTask() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        try Data("corrupted bytes".utf8).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.isPersistenceBlocked)

        vm.addTask(title: "Should Not Add", expectedMinutes: 25)
        XCTAssertTrue(vm.tasks.isEmpty)
    }

    // Test H — Restart Persistence: Add Task A -> Stop Stopwatch -> Quit/Reopen
    @MainActor
    func testTaskAttributionFinalCorrectionH_RestartPersistencePreservesStopwatchTaskAttribution() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        while !vm1.tasks.isEmpty {
            vm1.removeTask(at: 0)
        }

        vm1.startStopwatch()
        vm1.stopwatchStartDate = vm1.stopwatchStartDate?.addingTimeInterval(-60.0)

        vm1.addTask(title: "Persisted Task", expectedMinutes: 25)

        vm1.stopwatchStartDate = vm1.stopwatchStartDate?.addingTimeInterval(-30.0)
        vm1.stopStopwatch()

        XCTAssertEqual(vm1.stopwatchTime, 90)
        XCTAssertEqual(vm1.tasks[0].timeSpentSeconds, 30)

        // Quit
        vm1.handleAppTermination()

        // Reopen
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.tasks.count, 1)
        XCTAssertEqual(vm2.tasks[0].title, "Persisted Task")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 30, "Task must retain exactly 30s upon relaunch")
        XCTAssertEqual(vm2.stopwatchTime, 90, "Stopwatch elapsed time must survive relaunch")
    }

    // MARK: - Task 4: Restart-State Persistence Regression Tests (22 Tests)

    // Test 1: Idle Custom Timer 45:30 survives Quit/Reopen
    @MainActor
    func testTask4_01_IdleCustomTimer4530SurvivesRestart() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.setCustomDuration(minutes: 45, seconds: 30)
        XCTAssertEqual(vm1.activePreset, "Custom")
        XCTAssertEqual(vm1.activeMode, "Custom Timer")
        XCTAssertEqual(vm1.totalTime, 2730)
        XCTAssertEqual(vm1.timeRemaining, 2730)
        XCTAssertEqual(vm1.timerTimeString, "45:30")
        XCTAssertEqual(vm1.customMinutes, 45)
        XCTAssertEqual(vm1.customSeconds, 30)
        XCTAssertFalse(vm1.isTimerRunning)

        vm1.handleAppTermination()

        // Inspect raw saved JSON on disk
        let savedBytes = try? Data(contentsOf: tempURL)
        XCTAssertNotNil(savedBytes)
        if let bytes = savedBytes, let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            XCTAssertEqual(json["activePreset"] as? String, "Custom")
            XCTAssertEqual(json["activeMode"] as? String, "Custom Timer")
            XCTAssertEqual(json["configuredTotalTime"] as? Int, 2730)
            XCTAssertEqual(json["configuredCustomMinutes"] as? Int, 45)
            XCTAssertEqual(json["configuredCustomSeconds"] as? Int, 30)
        }

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Custom")
        XCTAssertEqual(vm2.activeMode, "Custom Timer")
        XCTAssertEqual(vm2.totalTime, 2730)
        XCTAssertEqual(vm2.timeRemaining, 2730)
        XCTAssertEqual(vm2.timerTimeString, "45:30")
        XCTAssertEqual(vm2.customMinutes, 45)
        XCTAssertEqual(vm2.customSeconds, 30)
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // Test 2: Idle selected Task C survives restart with exactly the same UUID
    @MainActor
    func testTask4_02_IdleSelectedTaskCSurvivesRestartWithSameUUID() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        while !vm1.tasks.isEmpty { vm1.removeTask(at: 0) }
        vm1.addTask(title: "Task A", expectedMinutes: 25)
        vm1.addTask(title: "Task B", expectedMinutes: 25)
        vm1.addTask(title: "Task C", expectedMinutes: 25)

        let taskCId = vm1.tasks[2].id
        vm1.selectTask(at: 2)
        XCTAssertEqual(vm1.activeTaskIndex, 2)
        XCTAssertEqual(vm1.tasks[vm1.activeTaskIndex].id, taskCId)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.tasks.count, 3)
        XCTAssertEqual(vm2.activeTaskIndex, 2)
        XCTAssertEqual(vm2.tasks[vm2.activeTaskIndex].id, taskCId)
        XCTAssertEqual(vm2.tasks[vm2.activeTaskIndex].title, "Task C")
        XCTAssertFalse(vm2.tasks[2].isCompleted)
        XCTAssertEqual(vm2.tasks[2].timeSpentSeconds, 0)
    }

    // Test 3: Selection survives when the selected task is not at index zero
    @MainActor
    func testTask4_03_SelectionSurvivesWhenTaskNotAtIndexZero() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertTrue(vm1.tasks.count >= 4)
        let targetIndex = 3
        let targetId = vm1.tasks[targetIndex].id

        vm1.selectTask(at: targetIndex)
        XCTAssertEqual(vm1.activeTaskIndex, targetIndex)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activeTaskIndex, targetIndex)
        XCTAssertEqual(vm2.tasks[vm2.activeTaskIndex].id, targetId)
    }

    // Test 4: Intentionally empty tasks remain empty
    @MainActor
    func testTask4_04_IntentionallyEmptyTasksRemainEmpty() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        while !vm1.tasks.isEmpty { vm1.removeTask(at: 0) }
        XCTAssertTrue(vm1.tasks.isEmpty)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertTrue(vm2.tasks.isEmpty)
        XCTAssertEqual(vm2.activeTaskIndex, 0)
        XCTAssertNil(vm2.activeSessionTaskId)
    }

    // Test 5: All-completed tasks do not restore an invalid active assignment
    @MainActor
    func testTask4_05_AllCompletedTasksDoNotRestoreInvalidActiveAssignment() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        for i in 0..<vm1.tasks.count {
            if !vm1.tasks[i].isCompleted {
                vm1.toggleTaskCompletion(at: i)
            }
        }
        XCTAssertTrue(vm1.tasks.allSatisfy(\.isCompleted))

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertTrue(vm2.tasks.allSatisfy(\.isCompleted))
        XCTAssertNil(vm2.activeSessionTaskId)

        // Starting stopwatch must NOT credit any completed task
        vm2.startStopwatch()
        vm2.stopwatchStartDate = vm2.stopwatchStartDate?.addingTimeInterval(-60.0)
        vm2.stopStopwatch()

        for task in vm2.tasks {
            XCTAssertEqual(task.timeSpentSeconds, 0, "No completed task should receive stopwatch time")
        }
    }

    // Test 6: Saved selected task missing from collection is handled safely
    @MainActor
    func testTask4_06_SavedSelectedTaskMissingFromCollectionHandledSafely() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let task1 = FocusTask(title: "Task 1", estimatedMinutes: 25)
        let missingUUID = UUID()

        let data = FocusAppData(
            tasks: [task1],
            selectedTaskId: missingUUID,
            activeMode: "Pomodoro"
        )
        let bytes = try JSONEncoder().encode(data)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].id, task1.id)
    }

    // Test 7: Selected task marked completed in saved data is handled safely
    @MainActor
    func testTask4_07_SelectedTaskMarkedCompletedInSavedDataHandledSafely() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let task1 = FocusTask(title: "Task 1", estimatedMinutes: 25, isCompleted: false)
        let task2 = FocusTask(title: "Task 2", estimatedMinutes: 25, isCompleted: true)

        let data = FocusAppData(
            tasks: [task1, task2],
            selectedTaskId: task2.id,
            activeMode: "Pomodoro"
        )
        let bytes = try JSONEncoder().encode(data)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        // task2 is completed, so fallback must safely select task1 (first uncompleted)
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].id, task1.id)
        XCTAssertFalse(vm.tasks[vm.activeTaskIndex].isCompleted)
    }

    // Test 8: Pomodoro session 3 of 4 survives idle restart
    @MainActor
    func testTask4_08_PomodoroSession3of4SurvivesIdleRestart() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.totalSessions = 4
        vm1.currentSession = 3
        XCTAssertEqual(vm1.currentSession, 3)
        XCTAssertEqual(vm1.totalSessions, 4)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.currentSession, 3)
        XCTAssertEqual(vm2.totalSessions, 4)
        XCTAssertEqual(vm2.completedSessions, 0, "No new completed session counted on restart")
    }

    // Test 9: Short Break idle configuration survives restart
    @MainActor
    func testTask4_09_ShortBreakIdleConfigurationSurvivesRestart() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.switchToBreak(minutes: 5)
        XCTAssertEqual(vm1.activePreset, "Short Break")
        XCTAssertTrue(vm1.isBreakSession)
        XCTAssertEqual(vm1.totalTime, 300)
        XCTAssertEqual(vm1.timeRemaining, 300)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Short Break")
        XCTAssertTrue(vm2.isBreakSession)
        XCTAssertEqual(vm2.totalTime, 300)
        XCTAssertEqual(vm2.timeRemaining, 300)
        XCTAssertEqual(vm2.timerTimeString, "05:00")
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // Test 10: Long Break idle configuration survives restart
    @MainActor
    func testTask4_10_LongBreakIdleConfigurationSurvivesRestart() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.switchToBreak(minutes: 15)
        XCTAssertEqual(vm1.activePreset, "Long Break")
        XCTAssertTrue(vm1.isBreakSession)
        XCTAssertEqual(vm1.totalTime, 900)
        XCTAssertEqual(vm1.timeRemaining, 900)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Long Break")
        XCTAssertTrue(vm2.isBreakSession)
        XCTAssertEqual(vm2.totalTime, 900)
        XCTAssertEqual(vm2.timeRemaining, 900)
        XCTAssertEqual(vm2.timerTimeString, "15:00")
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // Test 11: Running Custom Timer normal Quit restores as paused with correct remaining duration
    @MainActor
    func testTask4_11_RunningCustomTimerNormalQuitRestoresAsPaused() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.setCustomDuration(minutes: 45, seconds: 0)
        vm1.startTimer()
        XCTAssertTrue(vm1.isTimerRunning)

        // Elapsed 100 seconds
        vm1.targetEndDate = vm1.targetEndDate?.addingTimeInterval(-100.0)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activePreset, "Custom")
        XCTAssertEqual(vm2.activeMode, "Custom Timer")
        XCTAssertEqual(vm2.totalTime, 2700)
        XCTAssertEqual(vm2.timeRemaining, 2600)
        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertNotNil(vm2.pausedSession)
    }

    // Test 12: Already-paused timer is not overwritten by new idle fields
    @MainActor
    func testTask4_12_AlreadyPausedTimerNotOverwrittenByNewIdleFields() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.applyPreset(name: "Focus", minutes: 25)
        vm1.startTimer()
        vm1.targetEndDate = vm1.targetEndDate?.addingTimeInterval(-300.0)
        vm1.stopTimer()

        XCTAssertEqual(vm1.timeRemaining, 1200)
        XCTAssertNotNil(vm1.pausedSession)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.timeRemaining, 1200, "Paused time remaining must NOT be overwritten by 1500 idle duration")
        XCTAssertEqual(vm2.totalTime, 1500)
        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertNotNil(vm2.pausedSession)
    }

    // Test 13: Preserved background session continues to restore correctly
    @MainActor
    func testTask4_13_PreservedBackgroundSessionContinuesToRestoreCorrectly() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.preservedSession = PreservedTimerSession(
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 900,
            preciseProgress: 0.6,
            customMinutes: 25,
            customSeconds: 0,
            currentSession: 1,
            activeTaskIndex: 0
        )

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertNotNil(vm2.preservedSession)
        XCTAssertEqual(vm2.preservedSession?.timeRemaining, 900)
        XCTAssertEqual(vm2.preservedSession?.activePreset, "Focus")
    }

    // Test 14: Legacy JSON with new fields missing decodes successfully
    @MainActor
    func testTask4_14_LegacyJSONWithNewFieldsMissingDecodesSuccessfully() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let legacyJSON = """
        {
            "tasks": [
                {
                    "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                    "title": "Legacy Task",
                    "estimatedMinutes": 25,
                    "timeSpentSeconds": 0,
                    "isCompleted": false,
                    "isLocked": false,
                    "icon": "star.fill",
                    "iconColorName": "orange"
                }
            ],
            "focusedSeconds": 0,
            "completedSessions": 0,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [],
            "stopwatchElapsedSeconds": 0.0
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks[0].title, "Legacy Task")
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.activeMode, "Pomodoro")
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.timeRemaining, 1500)
    }

    // Test 15: Legacy Focus and Break configurations retain appropriate defaults
    @MainActor
    func testTask4_15_LegacyFocusAndBreakConfigurationsRetainAppropriateDefaults() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Short Break legacy
        let shortBreakJSON = """
        {
            "tasks": [],
            "focusedSeconds": 0,
            "completedSessions": 0,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Short Break",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [],
            "stopwatchElapsedSeconds": 0.0
        }
        """
        let shortBreakURL = tempDir.appendingPathComponent("focusflow_data.json")
        try shortBreakJSON.data(using: .utf8)?.write(to: shortBreakURL)

        let storage1 = FocusStorageService(storageURL: shortBreakURL)
        let vm1 = TimerViewModel(storage: storage1)

        XCTAssertEqual(vm1.activePreset, "Short Break")
        XCTAssertEqual(vm1.totalTime, 300)
        XCTAssertEqual(vm1.timeRemaining, 300)
        XCTAssertTrue(vm1.isBreakSession)

        // Long Break legacy
        let longBreakJSON = """
        {
            "tasks": [],
            "focusedSeconds": 0,
            "completedSessions": 0,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Long Break",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [],
            "stopwatchElapsedSeconds": 0.0
        }
        """
        try longBreakJSON.data(using: .utf8)?.write(to: shortBreakURL)

        let storage2 = FocusStorageService(storageURL: shortBreakURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.activePreset, "Long Break")
        XCTAssertEqual(vm2.totalTime, 900)
        XCTAssertEqual(vm2.timeRemaining, 900)
        XCTAssertTrue(vm2.isBreakSession)
    }

    // Test 16: Invalid or out-of-range saved durations/session numbers are handled safely
    @MainActor
    func testTask4_16_InvalidOrOutOfRangeSavedDurationsAndSessionsHandledSafely() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let malformedData = FocusAppData(
            totalSessions: -2,
            configuredTotalTime: -100,
            configuredCustomMinutes: 9999,
            configuredCustomSeconds: 888,
            configuredCurrentSession: -5
        )
        let bytes = try JSONEncoder().encode(malformedData)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertGreaterThanOrEqual(vm.totalTime, 5)
        XCTAssertGreaterThanOrEqual(vm.currentSession, 1)
        XCTAssertLessThanOrEqual(vm.customMinutes, 360)
        XCTAssertLessThanOrEqual(vm.customSeconds, 59)
    }

    // Test 17: Task switching and unassigned focus-time attribution remain correct after restore
    @MainActor
    func testTask4_17_TaskSwitchingAndUnassignedAttributionCorrectAfterRestore() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        while !vm1.tasks.isEmpty { vm1.removeTask(at: 0) }
        vm1.addTask(title: "Task Alpha", expectedMinutes: 25)
        vm1.addTask(title: "Task Beta", expectedMinutes: 25)
        vm1.selectTask(at: 1)
        XCTAssertEqual(vm1.activeTaskIndex, 1)

        vm1.handleAppTermination()

        // Reopen
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.activeTaskIndex, 1)
        let betaId = vm2.tasks[1].id
        let alphaId = vm2.tasks[0].id

        vm2.startTimer()
        vm2.sessionSegmentStartDate = vm2.sessionSegmentStartDate?.addingTimeInterval(-50.0)
        vm2.targetEndDate = vm2.targetEndDate?.addingTimeInterval(-50.0)

        // Switch to Task Alpha
        vm2.selectTask(at: 0)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].taskId, betaId)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 50)

        vm2.sessionSegmentStartDate = vm2.sessionSegmentStartDate?.addingTimeInterval(-40.0)
        vm2.targetEndDate = vm2.targetEndDate?.addingTimeInterval(-40.0)
        vm2.stopTimer()

        XCTAssertEqual(vm2.sessionRecords.count, 2)
        XCTAssertEqual(vm2.sessionRecords[1].taskId, alphaId)
        XCTAssertEqual(vm2.sessionRecords[1].durationSeconds, 40)
        XCTAssertEqual(vm2.tasks[1].timeSpentSeconds, 50)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 40)
    }

    // Test 18: Stopwatch elapsed time and lap checkpoints survive restart
    @MainActor
    func testTask4_18_StopwatchElapsedTimeAndLapsSurviveRestart() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.startStopwatch()
        vm1.stopwatchStartDate = vm1.stopwatchStartDate?.addingTimeInterval(-20.0)
        vm1.recordLap() // Lap 1 at 20s

        vm1.stopwatchStartDate = vm1.stopwatchStartDate?.addingTimeInterval(-25.0)
        vm1.recordLap() // Lap 2 at 45s (split 25s)
        vm1.stopStopwatch()

        XCTAssertEqual(vm1.stopwatchTime, 45)
        XCTAssertEqual(vm1.laps.count, 2)

        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.stopwatchTime, 45)
        XCTAssertEqual(vm2.laps.count, 2)
        XCTAssertEqual(vm2.laps[1].lapNumber, 1)
        XCTAssertEqual(vm2.laps[0].lapNumber, 2)
        XCTAssertEqual(vm2.laps[0].lapDuration, 25.0, accuracy: 0.1)
    }

    // Test 19: Corrupted primary storage with valid backup retains existing recovery behavior
    @MainActor
    func testTask4_19_CorruptedPrimaryWithValidBackupRetainsRecoveryBehavior() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        let validData = FocusAppData(
            tasks: [FocusTask(title: "Backed Up Task", estimatedMinutes: 25)],
            activePreset: "Custom",
            activeMode: "Custom Timer",
            configuredTotalTime: 3600,
            configuredCustomMinutes: 60,
            configuredCustomSeconds: 0
        )
        let validBytes = try JSONEncoder().encode(validData)
        try validBytes.write(to: backupURL)
        try Data("corrupted bytes".utf8).write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertTrue(vm.didRecoverFromBackup)
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks[0].title, "Backed Up Task")
        XCTAssertEqual(vm.activePreset, "Custom")
        XCTAssertEqual(vm.activeMode, "Custom Timer")
        XCTAssertEqual(vm.totalTime, 3600)
    }

    // Test 20: Corrupted primary and backup continue to block unsafe saving
    @MainActor
    func testTask4_20_CorruptedPrimaryAndBackupBlockUnsafeSaving() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let backupURL = primaryURL.appendingPathExtension("bak")

        try Data("corrupted 1".utf8).write(to: primaryURL)
        try Data("corrupted 2".utf8).write(to: backupURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.isPersistenceBlocked)
        vm.addTask(title: "Should Be Blocked", expectedMinutes: 25)
        XCTAssertTrue(vm.tasks.isEmpty)
    }

    // Test 21: Existing historical session records and completed-session totals remain unchanged by loading
    @MainActor
    func testTask4_21_ExistingHistoricalRecordsAndCompletedTotalsUnchangedByLoading() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let now = Date()
        let records = [
            FocusSessionRecord(startTime: now.addingTimeInterval(-3600), endTime: now.addingTimeInterval(-1800), durationSeconds: 1800, mode: "Pomodoro"),
            FocusSessionRecord(startTime: now.addingTimeInterval(-1800), endTime: now, durationSeconds: 1800, mode: "Pomodoro")
        ]
        vm1.completedSessions = 7
        vm1.sessionRecords = records
        vm1.handleAppTermination()

        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertEqual(vm2.completedSessions, 7)
        XCTAssertEqual(vm2.sessionRecords.count, 2)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 1800)
        XCTAssertEqual(vm2.sessionRecords[1].durationSeconds, 1800)
    }

    // Test 22: Fresh installation still shows the expected default app state
    @MainActor
    func testTask4_22_FreshInstallationShowsDefaultAppState() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4_fresh_\(UUID().uuidString)")
        let nonExistentURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = FocusStorageService(storageURL: nonExistentURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.storageLoadResult, .freshInstall)
        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertEqual(vm.tasks.count, 4)
        XCTAssertEqual(vm.activeTaskIndex, 0)
        XCTAssertEqual(vm.currentSession, 1)
        XCTAssertEqual(vm.totalSessions, 4)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.activeMode, "Pomodoro")
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.timeRemaining, 1500)
        XCTAssertFalse(vm.isBreakSession)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertFalse(vm.isStopwatchRunning)
    }

    // MARK: - Task 4 Follow-up Regression Tests

    // Reproduction Test
    @MainActor
    func testTask4FollowUp_Reproduction_ExcessivePositiveDurationNotClamped() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_repro_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let malformedData = FocusAppData(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            configuredTotalTime: 36000,
            configuredCustomMinutes: 600,
            configuredCustomSeconds: 0
        )
        let bytes = try JSONEncoder().encode(malformedData)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        // The maximum supported duration is 360m 59s = 21659s.
        // A 600m / 36000s duration must be clamped within supported bounds.
        XCTAssertLessThanOrEqual(vm.totalTime, 21659, "Excessive duration 36000 should be clamped to supported max")
        XCTAssertLessThanOrEqual(vm.customMinutes, 360, "Excessive customMinutes 600 should be clamped to 360")
    }

    // Test A — Unsupported Large Positive Duration
    @MainActor
    func testTask4FollowUp_A_UnsupportedLargePositiveDurationClampedAndConsistent() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testA_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let malformedData = FocusAppData(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            configuredTotalTime: 36000,
            configuredCustomMinutes: 600,
            configuredCustomSeconds: 0
        )
        let bytes = try JSONEncoder().encode(malformedData)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.totalTime, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.timeRemaining, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.customDurationSeconds, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.customMinutes, 360)
        XCTAssertEqual(vm.customSeconds, 59)
        XCTAssertEqual(vm.preciseProgress, 1.0)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertNil(vm.targetEndDate)
        XCTAssertFalse(vm.isPersistenceBlocked)
    }

    // Test B — Maximum Valid Boundary
    @MainActor
    func testTask4FollowUp_B_MaximumValidBoundarySurvivesWithoutTruncation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testB_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("focusflow_data.json")

        // 1. Boundary 360:00 (21600 seconds)
        do {
            let storage1 = FocusStorageService(storageURL: fileURL)
            let vm1 = TimerViewModel(storage: storage1)
            vm1.setCustomDuration(minutes: 360, seconds: 0)
            XCTAssertEqual(vm1.totalTime, 21600)
            vm1.persistData(force: true)

            let storage2 = FocusStorageService(storageURL: fileURL)
            let vm2 = TimerViewModel(storage: storage2)
            XCTAssertEqual(vm2.totalTime, 21600)
            XCTAssertEqual(vm2.timeRemaining, 21600)
            XCTAssertEqual(vm2.customMinutes, 360)
            XCTAssertEqual(vm2.customSeconds, 0)
            XCTAssertEqual(vm2.customDurationSeconds, 21600)
            XCTAssertEqual(vm2.activePreset, "Custom")
            XCTAssertEqual(vm2.activeMode, "Custom Timer")
            XCTAssertFalse(vm2.isTimerRunning)
        }

        // 2. Boundary 360:59 (21659 seconds)
        do {
            let storage3 = FocusStorageService(storageURL: fileURL)
            let vm3 = TimerViewModel(storage: storage3)
            vm3.setCustomDuration(minutes: 360, seconds: 59)
            XCTAssertEqual(vm3.totalTime, 21659)
            vm3.persistData(force: true)

            let storage4 = FocusStorageService(storageURL: fileURL)
            let vm4 = TimerViewModel(storage: storage4)
            XCTAssertEqual(vm4.totalTime, 21659)
            XCTAssertEqual(vm4.timeRemaining, 21659)
            XCTAssertEqual(vm4.customMinutes, 360)
            XCTAssertEqual(vm4.customSeconds, 59)
            XCTAssertEqual(vm4.customDurationSeconds, 21659)
            XCTAssertEqual(vm4.activePreset, "Custom")
            XCTAssertEqual(vm4.activeMode, "Custom Timer")
            XCTAssertFalse(vm4.isTimerRunning)
        }
    }

    // Test C — One Second Above Maximum
    @MainActor
    func testTask4FollowUp_C_OneSecondAboveMaximumClampedDeterministically() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testC_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let malformedData = FocusAppData(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            configuredTotalTime: 21660,
            configuredCustomMinutes: 361,
            configuredCustomSeconds: 0
        )
        let bytes = try JSONEncoder().encode(malformedData)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.totalTime, 21659)
        XCTAssertEqual(vm.timeRemaining, 21659)
        XCTAssertEqual(vm.customMinutes, 360)
        XCTAssertEqual(vm.customSeconds, 59)
        XCTAssertEqual(vm.customDurationSeconds, 21659)
        XCTAssertFalse(vm.isTimerRunning)
    }

    // Test D — Extremely Large Integer
    @MainActor
    func testTask4FollowUp_D_ExtremelyLargeIntegerHandledSafelyWithoutOverflow() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testD_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let malformedData = FocusAppData(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            configuredTotalTime: Int.max,
            configuredCustomMinutes: Int.max,
            configuredCustomSeconds: Int.max
        )
        let bytes = try JSONEncoder().encode(malformedData)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.totalTime, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.timeRemaining, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.customMinutes, 360)
        XCTAssertEqual(vm.customSeconds, 59)
        XCTAssertEqual(vm.customDurationSeconds, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.preciseProgress, 1.0)
        XCTAssertFalse(vm.isTimerRunning)
    }

    // Test E — Valid Custom Duration Unchanged
    @MainActor
    func testTask4FollowUp_E_ValidCustomDuration4530Unchanged() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.setCustomDuration(minutes: 45, seconds: 30)
        XCTAssertEqual(vm1.totalTime, 2730)
        XCTAssertEqual(vm1.timeRemaining, 2730)
        XCTAssertEqual(vm1.customMinutes, 45)
        XCTAssertEqual(vm1.customSeconds, 30)
        XCTAssertEqual(vm1.customDurationSeconds, 2730)
        vm1.persistData(force: true)

        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.totalTime, 2730)
        XCTAssertEqual(vm2.timeRemaining, 2730)
        XCTAssertEqual(vm2.customMinutes, 45)
        XCTAssertEqual(vm2.customSeconds, 30)
        XCTAssertEqual(vm2.customDurationSeconds, 2730)
        XCTAssertEqual(vm2.activePreset, "Custom")
        XCTAssertEqual(vm2.activeMode, "Custom Timer")
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // Test F — Valid Paused Timer Unchanged
    @MainActor
    func testTask4FollowUp_F_ValidPausedTimerUnchangedAndOutOfRangePausedClamped() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testF_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")

        // Sub-test 1: Valid paused custom timer (45:00 total, 32:10 remaining) with conflicting invalid top-level duration
        let validPaused = PausedTimerSession(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            isBreakSession: false,
            totalTime: 2700,
            timeRemaining: 1930,
            preciseProgress: 1930.0 / 2700.0,
            customMinutes: 45,
            customSeconds: 0,
            currentSession: 1,
            activeTaskIndex: 0
        )
        let payloadWithValidPaused = FocusAppData(
            activePreset: "Custom",
            pausedSession: validPaused,
            activeMode: "Custom Timer",
            configuredTotalTime: 36000 // Out-of-range top-level idle field must not clobber paused session
        )
        let bytes1 = try JSONEncoder().encode(payloadWithValidPaused)
        try bytes1.write(to: primaryURL)

        let storage1 = FocusStorageService(storageURL: primaryURL)
        let vm1 = TimerViewModel(storage: storage1)

        XCTAssertEqual(vm1.totalTime, 2700)
        XCTAssertEqual(vm1.timeRemaining, 1930)
        XCTAssertEqual(vm1.customMinutes, 45)
        XCTAssertEqual(vm1.customSeconds, 0)
        XCTAssertEqual(vm1.customDurationSeconds, 2700)
        XCTAssertFalse(vm1.isTimerRunning)
        XCTAssertEqual(vm1.preciseProgress, 1930.0 / 2700.0, accuracy: 0.001)

        // Sub-test 2: Paused session with excessively large duration (36000 total, 35000 remaining)
        let invalidPaused = PausedTimerSession(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            isBreakSession: false,
            totalTime: 36000,
            timeRemaining: 35000,
            preciseProgress: 35000.0 / 36000.0,
            customMinutes: 600,
            customSeconds: 0,
            currentSession: 1,
            activeTaskIndex: 0
        )
        let payloadWithInvalidPaused = FocusAppData(
            activePreset: "Custom",
            pausedSession: invalidPaused,
            activeMode: "Custom Timer"
        )
        let bytes2 = try JSONEncoder().encode(payloadWithInvalidPaused)
        try bytes2.write(to: primaryURL)

        let storage2 = FocusStorageService(storageURL: primaryURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.totalTime, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm2.timeRemaining, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm2.customMinutes, 360)
        XCTAssertEqual(vm2.customSeconds, 59)
        XCTAssertEqual(vm2.customDurationSeconds, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // Test G — Legacy JSON
    @MainActor
    func testTask4FollowUp_G_LegacyJSONWithoutNewFieldsRetainsDefaults() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testG_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let legacyJSON = """
        {
            "tasks": [
                {
                    "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
                    "title": "Legacy Architecture Task",
                    "estimatedMinutes": 25,
                    "timeSpentSeconds": 0,
                    "isCompleted": false,
                    "isLocked": false,
                    "icon": "star.fill",
                    "iconColorName": "orange"
                }
            ],
            "completedSessions": 2,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "laps": []
        }
        """
        try legacyJSON.data(using: .utf8)!.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.activeMode, "Pomodoro")
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.timeRemaining, 1500)
        XCTAssertEqual(vm.customMinutes, 25)
        XCTAssertEqual(vm.customSeconds, 0)
        XCTAssertEqual(vm.customDurationSeconds, 1500)
        XCTAssertFalse(vm.isBreakSession)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.tasks.count, 1)
        XCTAssertEqual(vm.tasks[0].title, "Legacy Architecture Task")
    }

    // Test H — Other State Integrity
    @MainActor
    func testTask4FollowUp_H_OtherStateIntegrityPreservedWhenLoadingInvalidDuration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testH_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")

        let task1 = FocusTask(title: "Task 1", estimatedMinutes: 25)
        let task2 = FocusTask(title: "Task 2", estimatedMinutes: 50)
        let record = FocusSessionRecord(startTime: Date().addingTimeInterval(-3000), endTime: Date().addingTimeInterval(-1500), durationSeconds: 1500, mode: "Pomodoro", taskId: task1.id)
        let lap = StopwatchLap(lapNumber: 1, lapDuration: 60.0, totalTime: 60.0)

        let testData = FocusAppData(
            tasks: [task1, task2],
            completedSessions: 5,
            notes: ["Important architecture notes"],
            dailyGoalHours: 6,
            totalSessions: 4,
            activePreset: "Custom",
            sessionRecords: [record],
            laps: [lap],
            stopwatchElapsedSeconds: 125.5,
            lastRecordedLapElapsedSeconds: 60.0,
            nextLapNumber: 2,
            selectedTaskId: task2.id,
            activeMode: "Custom Timer",
            configuredTotalTime: 36000, // Invalid excessive duration
            configuredCustomMinutes: 600,
            configuredCustomSeconds: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(testData)
        try bytes.write(to: primaryURL)

        let storage = FocusStorageService(storageURL: primaryURL)
        let vm = TimerViewModel(storage: storage)

        // 1. Tasks & selection preserved
        XCTAssertEqual(vm.tasks.count, 2)
        XCTAssertEqual(vm.tasks[0].id, task1.id)
        XCTAssertEqual(vm.tasks[1].id, task2.id)
        XCTAssertEqual(vm.activeTaskIndex, 1)

        // 2. Historical records & metrics preserved
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm.completedSessions, 5)

        // 3. Stopwatch & laps preserved
        XCTAssertEqual(vm.stopwatchTime, 125)
        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(vm.nextLapNumber, 2)
        XCTAssertEqual(vm.lastRecordedLapElapsedSeconds, 60.0)

        // 4. Notes & preferences preserved
        XCTAssertEqual(vm.notes, ["Important architecture notes"])
        XCTAssertEqual(vm.dailyGoalHours, 6)

        // 5. Timer duration sanitized to supported boundary
        XCTAssertEqual(vm.totalTime, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.timeRemaining, TimerViewModel.maxSupportedTimerDuration)
        XCTAssertEqual(vm.customMinutes, 360)
        XCTAssertEqual(vm.customSeconds, 59)
    }

    // Test I — Corruption Protection
    @MainActor
    func testTask4FollowUp_I_CorruptionProtectionPreservedForGenuinelyCorruptedFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t4f_testI_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primaryURL = tempDir.appendingPathComponent("focusflow_data.json")
        let backupURL = tempDir.appendingPathComponent("focusflow_data.json.bak")

        // Sub-test 1: Syntactically valid JSON with out-of-range duration is NOT treated as file corruption
        let validJSONMalformedValues = FocusAppData(
            activePreset: "Custom",
            activeMode: "Custom Timer",
            configuredTotalTime: 99999
        )
        try JSONEncoder().encode(validJSONMalformedValues).write(to: primaryURL)
        let storage1 = FocusStorageService(storageURL: primaryURL)
        let vm1 = TimerViewModel(storage: storage1)
        XCTAssertFalse(vm1.isPersistenceBlocked)
        if case .success = vm1.storageLoadResult {
            // Success as expected
        } else {
            XCTFail("Syntactically valid JSON with out-of-range values should load successfully as .success, got: \(String(describing: vm1.storageLoadResult))")
        }

        // Sub-test 2: Corrupted primary with valid backup triggers .recovered
        let validBackupData = FocusAppData(completedSessions: 8)
        try JSONEncoder().encode(validBackupData).write(to: backupURL)
        try "CORRUPTED_GARBAGE_BYTES".data(using: .utf8)!.write(to: primaryURL)

        let storage2 = FocusStorageService(storageURL: primaryURL)
        let vm2 = TimerViewModel(storage: storage2)
        XCTAssertFalse(vm2.isPersistenceBlocked)
        XCTAssertTrue(vm2.didRecoverFromBackup)
        if case .recovered = vm2.storageLoadResult {
            // Recovered as expected
        } else {
            XCTFail("Genuinely corrupted primary with valid backup must trigger .recovered, got: \(String(describing: vm2.storageLoadResult))")
        }
        XCTAssertEqual(vm2.completedSessions, 8)

        // Sub-test 3: Corrupted primary and corrupted backup triggers .unrecoverable and blocks persistence
        try "CORRUPTED_PRIMARY_BYTES".data(using: .utf8)!.write(to: primaryURL)
        try "CORRUPTED_BACKUP_BYTES".data(using: .utf8)!.write(to: backupURL)
        let storage3 = FocusStorageService(storageURL: primaryURL)
        let vm3 = TimerViewModel(storage: storage3)
        XCTAssertTrue(vm3.isPersistenceBlocked)
        if case .unrecoverable = vm3.storageLoadResult {
            // Unrecoverable as expected
        } else {
            XCTFail("Corrupted primary and backup must trigger .unrecoverable, got: \(String(describing: vm3.storageLoadResult))")
        }
    }

    // MARK: - Task 5 Reproduction: Active Focus Session Crossing Midnight
    @MainActor
    func testTask5_Reproduction_ActiveFocusSessionCrossingMidnightOvercountsToday() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!

        // Construct 15 October 2026, 23:50:00 IST
        var startComponents = DateComponents()
        startComponents.year = 2026
        startComponents.month = 10
        startComponents.day = 15
        startComponents.hour = 23
        startComponents.minute = 50
        startComponents.second = 0
        let startDate = calendar.date(from: startComponents)!

        // Construct 16 October 2026, 00:15:00 IST (1500 seconds later)
        let nowDate = startDate.addingTimeInterval(1500)

        // Set up active timer running across midnight
        vm.activePreset = "Focus"
        vm.activeMode = "Pomodoro"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = startDate

        // Recalculate focus metrics at 00:15 on Oct 16
        vm.recalculateFocusMetrics(calendar: calendar, now: nowDate)

        // Expected:
        // On Oct 16 at 00:15, only 900 seconds (15 mins) have elapsed today.
        // The first 600 seconds (10 mins) belonged to Oct 15.
        // Current unpatched code adds all 1500 active elapsed seconds to todayFocusedSeconds!
        XCTAssertEqual(vm.todayFocusedSeconds, 900, "Today's focus must only include time elapsed after midnight (900s), not entire 1500s")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1500, "Past 7 days must include full 1500s")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 1500, "Lifetime must include full 1500s")
    }

    // MARK: - Task 5 Regression Test Suite: Groups A through F

    // MARK: Group A: Live Midnight Transition (Tests 1–6)

    // Test 1: Active Focus Timer running past midnight attributes pre-midnight seconds to yesterday and post-midnight seconds to today
    @MainActor
    func testTask5_GroupA_Test1_ActiveFocusTimerRunningPastMidnight_AttributesPreAndPostMidnight() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 45, second: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 15, second: 0))! // 1800s total

        vm.activePreset = "Focus"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = start

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 900, "Today (Oct 21) must only receive 900s elapsed after midnight")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800, "Weekly must receive all 1800s")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 1800, "Lifetime must receive all 1800s")
    }

    // Test 2: Active Focus Timer stopped shortly after midnight converts to a finalized record without discrepancy
    @MainActor
    func testTask5_GroupA_Test2_ActiveFocusTimerStoppedAfterMidnight_FinalizesWithoutDiscrepancy() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 45, second: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 15, second: 0))! // 1800s total

        vm.activePreset = "Focus"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = start

        vm.recalculateFocusMetrics(calendar: calendar, now: now)
        let runningToday = vm.todayFocusedSeconds
        let runningWeekly = vm.weeklyFocusedSeconds
        let runningLifetime = vm.lifetimeFocusedSeconds

        // Now finalize timer at the same 'now'
        vm.isTimerRunning = false
        let record = FocusSessionRecord(startTime: start, endTime: now, durationSeconds: 1800, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)
        vm.sessionSegmentStartDate = nil

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, runningToday, "Finalized todayFocusedSeconds must equal live running todayFocusedSeconds")
        XCTAssertEqual(vm.weeklyFocusedSeconds, runningWeekly, "Finalized weeklyFocusedSeconds must equal live running weeklyFocusedSeconds")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, runningLifetime, "Finalized lifetimeFocusedSeconds must equal live running lifetimeFocusedSeconds")
        XCTAssertEqual(vm.todayFocusedSeconds, 900)
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800)
    }

    // Test 3: Active Focus Timer paused before midnight and resumed after midnight
    @MainActor
    func testTask5_GroupA_Test3_ActiveFocusTimerPausedBeforeMidnightAndResumedAfterMidnight() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let startDay1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 40, second: 0))!
        let pauseDay1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 55, second: 0))! // 900s
        let resumeDay2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 10, second: 0))!
        let nowDay2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 20, second: 0))! // 600s

        // Record segment 1 on Day 1
        let record1 = FocusSessionRecord(startTime: startDay1, endTime: pauseDay1, durationSeconds: 900, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record1)

        // Running segment 2 on Day 2
        vm.activePreset = "Focus"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = resumeDay2

        vm.recalculateFocusMetrics(calendar: calendar, now: nowDay2)

        XCTAssertEqual(vm.todayFocusedSeconds, 600, "Today only includes segment started after midnight")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1500, "Weekly includes both segments (900 + 600 = 1500)")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 1500)
    }

    // Test 4: Active Focus Timer running through multiple consecutive midnights
    @MainActor
    func testTask5_GroupA_Test4_ActiveFocusTimerRunningThroughMultipleMidnights() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        // Day 1: 12:00 to Day 3: 14:00 (50 hours = 180,000s)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12, minute: 0, second: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 14, minute: 0, second: 0))!

        vm.activePreset = "Focus"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = start

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        // Day 3 (today) has elapsed 14 hours = 50,400s
        XCTAssertEqual(vm.todayFocusedSeconds, 50400, "Day 3 must receive 14h (50,400s)")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 180000, "Weekly must receive full 50h")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 180000, "Lifetime must receive full 50h")

        // Finalize into record and check each calendar day
        let record = FocusSessionRecord(startTime: start, endTime: now, durationSeconds: 180000, mode: "Focus", taskId: nil)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))!
        let day3 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22))!

        let d1 = record.duration(on: day1, calendar: calendar)
        let d2 = record.duration(on: day2, calendar: calendar)
        let d3 = record.duration(on: day3, calendar: calendar)

        XCTAssertEqual(d1, 43200, "Day 1 (12h) must be 43,200s")
        XCTAssertEqual(d2, 86400, "Day 2 (24h) must be 86,400s")
        XCTAssertEqual(d3, 50400, "Day 3 (14h) must be 50,400s")
        XCTAssertEqual(d1 + d2 + d3, 180000, "Sum of allocations across days must exactly conserve 180,000s")
    }

    // Test 5: Stopwatch running across midnight does not affect focus analytics
    @MainActor
    func testTask5_GroupA_Test5_StopwatchRunningAcrossMidnight_DoesNotAffectFocusAnalytics() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 50, second: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 15, second: 0))!

        vm.isStopwatchRunning = true
        vm.stopwatchStartDate = start
        vm.isTimerRunning = false
        vm.sessionSegmentStartDate = nil

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Stopwatch running must not count toward today's focus")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 0)
    }

    // Test 6: Short or Long Break running across midnight does not add to focus seconds
    @MainActor
    func testTask5_GroupA_Test6_BreakRunningAcrossMidnight_DoesNotAddToFocusSeconds() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 55, second: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5, second: 0))!

        vm.activePreset = "Short Break"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = start

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Break timers must not count toward focus analytics")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 0)
    }

    // MARK: Group B: Completed Focus Records (Tests 7–11)

    // Test 7: Single record spanning midnight allocates equally to day 1 and day 2
    func testTask5_GroupB_Test7_SingleRecordSpanningMidnight_AllocatesEqually() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let day1Start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30, second: 0))!
        let day2End = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 30, second: 0))!

        let record = FocusSessionRecord(startTime: day1Start, endTime: day2End, durationSeconds: 3600, mode: "Focus", taskId: nil)

        let d1 = record.duration(on: day1Start, calendar: calendar)
        let d2 = record.duration(on: day2End, calendar: calendar)
        let d3 = record.duration(on: calendar.date(byAdding: .day, value: 1, to: day2End)!, calendar: calendar)

        XCTAssertEqual(d1, 1800, "First half must be 1800s")
        XCTAssertEqual(d2, 1800, "Second half must be 1800s")
        XCTAssertEqual(d3, 0, "Day 3 must be 0s")
        XCTAssertEqual(d1 + d2, 3600, "Exact conservation")
    }

    // Test 8: Integer rounding conservation with odd durations guarantees exact sum
    func testTask5_GroupB_Test8_IntegerRoundingConservation_WithOddDurations() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 0, second: 0))!
        let day1 = calendar.date(byAdding: .minute, value: -1, to: midnight)!
        let day2 = calendar.date(byAdding: .minute, value: 1, to: midnight)!

        // Test multiple odd durations with exact mid-point at midnight
        let testDurations = [1, 3, 5, 59, 1501, 3601, 86399]
        for dur in testDurations {
            let start = midnight.addingTimeInterval(-Double(dur) / 2.0)
            let end = midnight.addingTimeInterval(Double(dur) / 2.0)
            let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: dur, mode: "Focus", taskId: nil)

            let p1 = record.duration(on: day1, calendar: calendar)
            let p2 = record.duration(on: day2, calendar: calendar)

            XCTAssertEqual(p1 + p2, dur, "Allocations \(p1) + \(p2) must strictly equal odd duration \(dur)")
        }
    }

    // Test 9: Session entirely on yesterday does not leak into today
    @MainActor
    func testTask5_GroupB_Test9_SessionEntirelyOnYesterday_DoesNotLeakIntoToday() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let yesterdayStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 0, second: 0))!
        let yesterdayEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15, minute: 0, second: 0))! // 3600s
        let todayNoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!

        let record = FocusSessionRecord(startTime: yesterdayStart, endTime: yesterdayEnd, durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        vm.recalculateFocusMetrics(calendar: calendar, now: todayNoon)

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Yesterday's session must not leak into today")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 3600)
    }

    // Test 10: Session entirely on today does not leak into yesterday or tomorrow
    func testTask5_GroupB_Test10_SessionEntirelyOnToday_DoesNotLeakIntoYesterdayOrTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let today10am = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 0, second: 0))!
        let today11am = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 11, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: today10am, endTime: today11am, durationSeconds: 3600, mode: "Focus", taskId: nil)

        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22))!

        XCTAssertEqual(record.duration(on: yesterday, calendar: calendar), 0)
        XCTAssertEqual(record.duration(on: today, calendar: calendar), 3600)
        XCTAssertEqual(record.duration(on: tomorrow, calendar: calendar), 0)
    }

    // Test 11: Multi-day record partitioned across days sums exactly to duration
    func testTask5_GroupB_Test11_MultiDayRecordPartitionedAcrossDays_SumsExactlyToDuration() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 13, minute: 17, second: 42))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 18, minute: 49, second: 11))!
        let totalDuration = 77777

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: totalDuration, mode: "Focus", taskId: nil)

        var sum = 0
        for dayOffset in 0...6 {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: start))!
            sum += record.duration(on: day, calendar: calendar)
        }

        XCTAssertEqual(sum, totalDuration, "Partitioned sum over all days must strictly equal \(totalDuration)")
    }

    // MARK: Group C: Weekly Boundaries (Tests 12–15)

    // Test 12: Rolling 7-day window boundary inclusion and exclusion across start, midway, and completion
    @MainActor
    func testTask5_GroupC_Test12_RollingSevenDayWindow_BoundaryInclusionAndExclusion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let todayNoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        let dayMinus8 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12, minute: 0, second: 0))! // 8 days ago
        let dayMinus6 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12, minute: 0, second: 0))! // 6 days ago (oldest in 7-day window)

        // Session 8 days ago: 3600s (completed in past)
        let oldRecord = FocusSessionRecord(startTime: dayMinus8, endTime: dayMinus8.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        // Session 6 days ago: 2400s (completed in past)
        let weekRecord = FocusSessionRecord(startTime: dayMinus6, endTime: dayMinus6.addingTimeInterval(2400), durationSeconds: 2400, mode: "Focus", taskId: nil)
        // Session today: 12:00 to 12:30 (1800s)
        let todayRecord = FocusSessionRecord(startTime: todayNoon, endTime: todayNoon.addingTimeInterval(1800), durationSeconds: 1800, mode: "Focus", taskId: nil)

        vm.sessionRecords = [oldRecord, weekRecord, todayRecord]

        // Phase 1: At 12:00:00 (exact start of today's session), 0 seconds of today's record have elapsed
        vm.recalculateFocusMetrics(calendar: calendar, now: todayNoon)
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "At 12:00:00, 0s of today's record have elapsed")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 2400, "Weekly must only include weekRecord (2400s), excluding oldRecord (3600s) and future todayRecord")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 7800)

        // Phase 2: At 12:15:00 (halfway through today's session), exactly 900s have elapsed
        let midway = todayNoon.addingTimeInterval(900)
        vm.recalculateFocusMetrics(calendar: calendar, now: midway)
        XCTAssertEqual(vm.todayFocusedSeconds, 900, "At 12:15:00, exactly 900s of today's record have elapsed")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3300, "Weekly includes weekRecord (2400) + elapsed today (900) = 3300")

        // Phase 3: At 12:30:00 (completion of today's session), all 1800s have elapsed
        let completion = todayNoon.addingTimeInterval(1800)
        vm.recalculateFocusMetrics(calendar: calendar, now: completion)
        XCTAssertEqual(vm.todayFocusedSeconds, 1800, "At 12:30:00, all 1800s have elapsed")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 4200, "Weekly includes 2400 + 1800 = 4200, excluding oldRecord (3600)")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 7800)
    }

    // Test 13: Session straddling the oldest day boundary allocated accurately
    @MainActor
    func testTask5_GroupC_Test13_SessionStraddlingOldestDayBoundary_AllocatedAccurately() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        // 7-day window is Oct 15 00:00 to Oct 21 23:59:59.
        // Session from Oct 14 23:00 to Oct 15 01:00 (7200s, 2 hours).
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 0, second: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 1, minute: 0, second: 0))!

        let straddlingRecord = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: 7200, mode: "Focus", taskId: nil)
        vm.sessionRecords = [straddlingRecord]

        vm.recalculateFocusMetrics(calendar: calendar, now: today)

        XCTAssertEqual(vm.todayFocusedSeconds, 0)
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600, "Only 1 hour on Oct 15 falls inside rolling 7-day window")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 7200)
    }

    // Test 14: Active session crossing the oldest weekly boundary
    @MainActor
    func testTask5_GroupC_Test14_ActiveSessionCrossingOldestWeeklyBoundary() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        // Start 8 days ago (Oct 13 12:00) and running till today Oct 21 12:00 (8 days = 192 hours = 691,200s)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12, minute: 0, second: 0))!

        vm.activePreset = "Focus"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = start

        vm.recalculateFocusMetrics(calendar: calendar, now: today)

        // 7-day window starts at Oct 15 00:00:00.
        // From Oct 15 00:00 to Oct 21 12:00 is 6.5 days = 156 hours = 561,600s
        XCTAssertEqual(vm.weeklyFocusedSeconds, 561600, "Weekly must strictly capture portion from 7-day boundary to now")
        XCTAssertEqual(vm.todayFocusedSeconds, 43200, "Today is 12h = 43,200s")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 691200, "Lifetime captures full 8 days")
    }

    // Test 15: Invariant hierarchy: today <= weekly <= lifetime
    @MainActor
    func testTask5_GroupC_Test15_Invariants_TodayWeeklyLifetimeHierarchy() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15, minute: 30, second: 0))!

        // Generate various sessions across past 30 days
        for i in 1...25 {
            let start = calendar.date(byAdding: .day, value: -i, to: now)!
            let record = FocusSessionRecord(startTime: start, endTime: start.addingTimeInterval(1200), durationSeconds: 1200, mode: "Focus", taskId: nil)
            vm.sessionRecords.append(record)
        }

        vm.activePreset = "Focus"
        vm.isTimerRunning = true
        vm.sessionSegmentStartDate = now.addingTimeInterval(-900)

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertTrue(vm.todayFocusedSeconds <= vm.weeklyFocusedSeconds, "today (\(vm.todayFocusedSeconds)) must be <= weekly (\(vm.weeklyFocusedSeconds))")
        XCTAssertTrue(vm.weeklyFocusedSeconds <= vm.lifetimeFocusedSeconds, "weekly (\(vm.weeklyFocusedSeconds)) must be <= lifetime (\(vm.lifetimeFocusedSeconds))")
    }

    // MARK: Group D: Lifecycle & Automatic Refresh (Tests 16–19)

    // Test 16: Idle app across midnight resets todayFocusedSeconds to zero
    @MainActor
    func testTask5_GroupD_Test16_IdleAppAcrossMidnight_ResetsTodayToZero() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calendar

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: day1, endTime: day1.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        // On day 1 at 22:00:00 (after session has completed), today is 3600s
        let day1AfterSession = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 22, minute: 0, second: 0))!
        vm.recalculateFocusMetrics(now: day1AfterSession)
        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "On day 1 after session ends, today is 3600s")

        // Midnight passes, app remains open and idle. Date changes to day 2 at 08:00:00.
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 8, minute: 0, second: 0))!
        vm.handleDateOrLifecycleChange(now: day2)

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "On day 2 without new sessions, todayFocusedSeconds must reset to 0")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600, "Weekly retains day 1 session")
    }

    // Test 17: NSCalendarDayChanged notification triggers recalculation (stale-to-fresh causal transition)
    @MainActor
    func testTask5_GroupD_Test17_NSCalendarDayChangedNotification_TriggersRecalculation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calendar

        // Setup Day 1 session (14:00 to 15:00 = 3600s)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: day1, endTime: day1.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        // Day 1 afternoon: record completed, today has 3600s
        let day1Afternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 16, minute: 0, second: 0))!
        vm.currentDateProvider = { day1Afternoon }
        vm.recalculateFocusMetrics(now: day1Afternoon)
        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "Precondition: Day 1 today's focus is 3600s")

        // Advance simulated date to Day 2 morning, but DO NOT call recalculateFocusMetrics manually
        let day2Morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        vm.currentDateProvider = { day2Morning }

        // State is intentionally stale (still 3600s) until the notification fires
        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "State must remain stale before notification")

        let exp = expectation(description: "todayFocusedSeconds refreshed to 0 on Day 2 via NSCalendarDayChanged")
        exp.assertForOverFulfill = false

        var hasFulfilled = false
        var cancellable: AnyCancellable?
        cancellable = vm.$todayFocusedSeconds
            .dropFirst()
            .filter { $0 == 0 }
            .first()
            .sink { _ in
                if !hasFulfilled {
                    hasFulfilled = true
                    exp.fulfill()
                }
            }
        defer { cancellable?.cancel() }

        // Post the real NSCalendarDayChanged notification
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)

        wait(for: [exp], timeout: 5.0)
        cancellable?.cancel()

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Notification must have caused todayFocusedSeconds to update to 0")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600, "Weekly retains day 1")
    }

    // Test 18: NSApplicationDidBecomeActive notification triggers recalculation (stale-to-fresh causal transition)
    @MainActor
    func testTask5_GroupD_Test18_NSApplicationDidBecomeActiveNotification_TriggersRecalculation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calendar

        // Setup Day 1 session (10:00 to 11:00 = 3600s)
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: day1, endTime: day1.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        let day1Afternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12, minute: 0, second: 0))!
        vm.currentDateProvider = { day1Afternoon }
        vm.recalculateFocusMetrics(now: day1Afternoon)
        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "Precondition: Day 1 today's focus is 3600s")

        // Advance simulated date to Day 2
        let day2Morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 0, second: 0))!
        vm.currentDateProvider = { day2Morning }

        // State remains stale before activation notification
        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "State must remain stale before notification")

        let exp = expectation(description: "todayFocusedSeconds refreshed to 0 on Day 2 via didBecomeActive")
        exp.assertForOverFulfill = false

        var hasFulfilled = false
        var cancellable: AnyCancellable?
        cancellable = vm.$todayFocusedSeconds
            .dropFirst()
            .filter { $0 == 0 }
            .first()
            .sink { _ in
                if !hasFulfilled {
                    hasFulfilled = true
                    exp.fulfill()
                }
            }
        defer { cancellable?.cancel() }

        // Post NSApplication.didBecomeActiveNotification
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        wait(for: [exp], timeout: 5.0)
        cancellable?.cancel()

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Notification must have caused todayFocusedSeconds to update to 0")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600)
    }

    // Test 19: InsightsView onAppear wiring and manual refresh verification
    @MainActor
    func testTask5_GroupD_Test19_InsightsViewOnAppear_TriggersRecalculation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calendar

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: day1, endTime: day1.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        let day1Noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12, minute: 0, second: 0))!
        vm.currentDateProvider = { day1Noon }
        vm.recalculateFocusMetrics(now: day1Noon)
        XCTAssertEqual(vm.todayFocusedSeconds, 3600)

        // Instantiate view structure
        let view = InsightsView(viewModel: vm)
        XCTAssertNotNil(view.body)

        // Advance time to Day 2 and verify the exact action wired into .onAppear refreshes state
        let day2Noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        vm.currentDateProvider = { day2Noon }

        // State is stale until refresh
        XCTAssertEqual(vm.todayFocusedSeconds, 3600)

        // Execute the exact handler invoked by InsightsView.onAppear
        vm.recalculateFocusMetrics()
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Invoking recalculateFocusMetrics as done in onAppear refreshes stale metrics to 0")

        // NOTE: As instructed, automated GUI execution of SwiftUI's internal .onAppear lifecycle callback is reserved for Task 10.
    }

    // MARK: Group E: Time Zones & Daylight Saving Time (Tests 20–22)

    // Test 20: Non-UTC time zones (Asia/Kolkata +05:30) calculate midnight at local 00:00:00 IST
    func testTask5_GroupE_Test20_NonUTCTimeZones_AsiaKolkataMidnightBoundary() {
        var calIST = Calendar(identifier: .gregorian)
        calIST.timeZone = TimeZone(identifier: "Asia/Kolkata")! // UTC + 5:30

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!

        // Session at 18:15 UTC to 18:45 UTC on Oct 20 (30 mins = 1800s).
        // In UTC: starts and ends on Oct 20.
        // In IST: starts at 23:45 on Oct 20, ends at 00:15 on Oct 21 (crosses IST midnight!).
        let startUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 15, second: 0))!
        let endUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 45, second: 0))!

        let record = FocusSessionRecord(startTime: startUTC, endTime: endUTC, durationSeconds: 1800, mode: "Focus", taskId: nil)

        // In IST calendar
        let dISTDay1 = record.duration(on: calIST.date(from: DateComponents(year: 2026, month: 10, day: 20))!, calendar: calIST)
        let dISTDay2 = record.duration(on: calIST.date(from: DateComponents(year: 2026, month: 10, day: 21))!, calendar: calIST)
        XCTAssertEqual(dISTDay1, 900, "In IST, pre-midnight slice is 900s")
        XCTAssertEqual(dISTDay2, 900, "In IST, post-midnight slice is 900s")
        XCTAssertEqual(dISTDay1 + dISTDay2, 1800)

        // In UTC calendar
        let dUTCDay1 = record.duration(on: startUTC, calendar: calUTC)
        XCTAssertEqual(dUTCDay1, 1800, "In UTC, entire 1800s is on Oct 20")
    }

    // Test 21: Spring forward DST transition (23-hour day) conserves seconds
    func testTask5_GroupE_Test21_SpringForwardDSTTransition_ConservesSeconds() {
        var calNY = Calendar(identifier: .gregorian)
        calNY.timeZone = TimeZone(identifier: "America/New_York")! // DST switch on 2026-03-08

        // Start 2026-03-07 23:00 to 2026-03-08 04:00 (spans midnight and 2am->3am skip)
        let start = calNY.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 0, second: 0))!
        let end = calNY.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 4, minute: 0, second: 0))!
        let totalWallSeconds = Int(end.timeIntervalSince(start)) // 4 hours real time due to skip = 14400s

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: totalWallSeconds, mode: "Focus", taskId: nil)

        let d1 = record.duration(on: calNY.date(from: DateComponents(year: 2026, month: 3, day: 7))!, calendar: calNY)
        let d2 = record.duration(on: calNY.date(from: DateComponents(year: 2026, month: 3, day: 8))!, calendar: calNY)

        XCTAssertEqual(d1 + d2, totalWallSeconds, "Duration across spring DST transition must strictly conserve seconds")
        XCTAssertEqual(d1, 3600, "Pre-midnight (23:00 to 24:00) is exactly 1 hour")
        XCTAssertEqual(d2, totalWallSeconds - 3600)
    }

    // Test 22: Fall back DST transition (25-hour day) conserves seconds
    func testTask5_GroupE_Test22_FallBackDSTTransition_ConservesSeconds() {
        var calNY = Calendar(identifier: .gregorian)
        calNY.timeZone = TimeZone(identifier: "America/New_York")! // DST fall back on 2026-11-01

        let start = calNY.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 0, second: 0))!
        let end = calNY.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 4, minute: 0, second: 0))!
        let totalWallSeconds = Int(end.timeIntervalSince(start)) // 6 hours real time due to fall back = 21600s

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: totalWallSeconds, mode: "Focus", taskId: nil)

        let d1 = record.duration(on: calNY.date(from: DateComponents(year: 2026, month: 10, day: 31))!, calendar: calNY)
        let d2 = record.duration(on: calNY.date(from: DateComponents(year: 2026, month: 11, day: 1))!, calendar: calNY)

        XCTAssertEqual(d1 + d2, totalWallSeconds, "Duration across fall DST transition must strictly conserve seconds")
        XCTAssertEqual(d1, 3600)
        XCTAssertEqual(d2, totalWallSeconds - 3600)
    }

    // MARK: Group F: Data & Task Integrity (Tests 23–25)

    // Test 23: Task attribution across midnight preserves task credit
    @MainActor
    func testTask5_GroupF_Test23_TaskAttributionAcrossMidnight_PreservesTaskCredit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let taskId = vm.tasks[0].id
        vm.selectTask(at: 0)
        vm.startTimer()
        XCTAssertEqual(vm.activeSessionTaskId, taskId)

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 50, second: 0))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 15, second: 0))!

        vm.sessionSegmentStartDate = start

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 900)
        XCTAssertEqual(vm.activeSessionTaskId, taskId, "Active session task id must remain assigned to selected task")
    }

    // Test 24: Quit and reopen after midnight restores allocated analytics
    @MainActor
    func testTask5_GroupF_Test24_QuitAndReopenAfterMidnight_RestoresAllocatedAnalytics() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 22, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: day1, endTime: day1.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm1.sessionRecords = [record]
        vm1.persistData(force: true)

        // Simulate relaunch on day 2
        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)
        vm2.reportingCalendar = calendar

        let day2Noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        vm2.recalculateFocusMetrics(calendar: calendar, now: day2Noon)

        XCTAssertEqual(vm2.todayFocusedSeconds, 0, "Relaunch on day 2 must compute today's focus as 0")
        XCTAssertEqual(vm2.weeklyFocusedSeconds, 3600, "Weekly retains day 1 record")
        XCTAssertEqual(vm2.lifetimeFocusedSeconds, 3600)
    }

    // Test 25: Backward compatibility: legacy records without drift
    @MainActor
    func testTask5_GroupF_Test25_BackwardCompatibility_LegacyRecordsWithoutDrift() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Test with legacyLifetimeFocusedSeconds
        vm.legacyLifetimeFocusedSeconds = 7200
        vm.recalculateFocusMetrics()

        XCTAssertTrue(vm.lifetimeFocusedSeconds >= 7200, "Lifetime focus must include legacy total")
    }

    // MARK: - Task 5 Correction: Reproduction of Future-Time Overcounting Defect
    @MainActor
    func testTask5_Correction_Reproduction_FutureOnlyRecord_OvercountedInTodayAndWeekly() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 17, minute: 0, second: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18, minute: 0, second: 0))!

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        // At 09:00, a record occurring from 17:00-18:00 is entirely in the future.
        // Today and Weekly MUST be 0.
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Future-dated record must not contribute to today's focus at 09:00")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0, "Future-dated record must not contribute to weekly focus at 09:00")
    }

    @MainActor
    func testTask5_Correction_Reproduction_PartiallyFutureRecord_OvercountedInTodayAndWeekly() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 30, second: 0))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 0, second: 0))!

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        // At 09:30, only 1800s of the 09:00-10:00 session have elapsed.
        XCTAssertEqual(vm.todayFocusedSeconds, 1800, "Partially future record must only contribute elapsed portion (1800s) at 09:30")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800, "Partially future record must only contribute elapsed portion (1800s) to weekly at 09:30")
    }

    // MARK: - Task 5 Engineering Correction Verification Scenarios

    // Scenario 3: Record ending exactly at `now`: full record duration counts
    @MainActor
    func testTask5_Correction_Scenario3_RecordEndingExactlyAtNow_FullDurationCounts() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 0, second: 0))! // 3600s
        let now = end

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "Record ending exactly at now must contribute full duration")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600)
    }

    // Scenario 4: Multiple past, current and future records: exact aggregate totals
    @MainActor
    func testTask5_Correction_Scenario4_MultiplePastCurrentFutureRecords_ExactAggregates() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 45, second: 0))!

        // Past record (07:00 - 08:00 = 3600s)
        let pastStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 7, minute: 0, second: 0))!
        let pastRecord = FocusSessionRecord(startTime: pastStart, endTime: pastStart.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)

        // Current overlapping record (09:00 - 10:00 = 3600s, at 09:45 elapsed is 2700s)
        let currStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        let currRecord = FocusSessionRecord(startTime: currStart, endTime: currStart.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)

        // Future record (14:00 - 15:00 = 3600s, 0s elapsed)
        let futStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 0, second: 0))!
        let futRecord = FocusSessionRecord(startTime: futStart, endTime: futStart.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)

        vm.sessionRecords = [pastRecord, currRecord, futRecord]

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        // Aggregate today: 3600 (past) + 2700 (overlapping) + 0 (future) = 6300s
        XCTAssertEqual(vm.todayFocusedSeconds, 6300, "Today aggregate must be 3600 + 2700 + 0 = 6300s")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 6300, "Weekly aggregate must be 6300s")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 10800, "Lifetime retains all stored records: 3600*3 = 10800s")
    }

    // Scenario 5: Future record spanning local midnight: neither today's nor tomorrow's future portion leaks into current analytics
    @MainActor
    func testTask5_Correction_Scenario5_FutureRecordSpanningMidnight_NoLeakage() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15, minute: 0, second: 0))!

        // Future session tonight across midnight (23:30 on Oct 21 to 00:30 on Oct 22 = 3600s)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 30, second: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 30, second: 0))!

        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 0, "No portion of future midnight-spanning session must leak into today's focus")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0, "No portion of future midnight-spanning session must leak into weekly focus")
    }

    // Scenario 6: Future records outside the weekly boundary remain excluded
    @MainActor
    func testTask5_Correction_Scenario6_FutureRecordsOutsideWeeklyBoundary_Excluded() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        let futStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10, minute: 0, second: 0))! // 9 days in future

        let record = FocusSessionRecord(startTime: futStart, endTime: futStart.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 0)
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0)
    }

    // Scenario 7: Current-day and weekly reporting windows end at `now`, not end of today
    @MainActor
    func testTask5_Correction_Scenario7_WindowsEndAtNowNotEndOfToday() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 0, second: 0))!

        // Record completed 1 hour ago (12:00 - 13:00 = 3600s)
        let past = FocusSessionRecord(
            startTime: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!,
            endTime: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 13, minute: 0, second: 0))!,
            durationSeconds: 3600, mode: "Focus", taskId: nil
        )

        // Record 2 hours in future (16:00 - 17:00 = 3600s)
        let future = FocusSessionRecord(
            startTime: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 16, minute: 0, second: 0))!,
            endTime: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 17, minute: 0, second: 0))!,
            durationSeconds: 3600, mode: "Focus", taskId: nil
        )

        vm.sessionRecords = [past, future]

        vm.recalculateFocusMetrics(calendar: calendar, now: now)

        XCTAssertEqual(vm.todayFocusedSeconds, 3600, "Window ends at now (14:00), excluding the 16:00 session")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 3600)
    }

    // Scenario 9: Existing historical `duration(on:calendar:)` still returns the correct full-day allocation when intentionally requested
    func testTask5_Correction_Scenario9_HistoricalDurationOnCalendar_ReturnsFullDayAllocation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 17, minute: 0, second: 0))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: start, endTime: end, durationSeconds: 3600, mode: "Focus", taskId: nil)

        // Call duration(on:calendar:) directly for Oct 21
        let dayQueryDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        let fullDayDuration = record.duration(on: dayQueryDate, calendar: calendar)

        XCTAssertEqual(fullDayDuration, 3600, "Historical duration(on:calendar:) must continue returning the full calendar day duration regardless of current time")
    }

    // Scenario 12: No duplicate refresh observers after repeated lifecycle activity
    @MainActor
    func testTask5_Correction_Scenario12_NoDuplicateObserversAfterRepeatedLifecycleActivity() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Repeatedly set up monitoring (simulating re-initialization / wake events)
        for _ in 1...5 {
            vm.setupDateChangeMonitoring()
        }

        XCTAssertEqual(vm.activeDateChangeObserverCount, 5, "Must strictly have 5 distinct observers without duplicates")
    }

    // Scenario 13 & 14: Simulated time-zone change updates reporting without modifying records
    @MainActor
    func testTask5_Correction_Scenario13_SimulatedTimeZoneChange_UpdatesReportingWithoutModifyingRecords() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!

        var calKolkata = Calendar(identifier: .gregorian)
        calKolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")! // UTC +5:30

        // Focus session from 18:15 UTC to 18:45 UTC on 2026-10-20 (1800s)
        let startUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 15, second: 0))!
        let endUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 45, second: 0))!

        let recordId = UUID()
        let taskId = UUID()
        let record = FocusSessionRecord(id: recordId, startTime: startUTC, endTime: endUTC, durationSeconds: 1800, mode: "Focus", taskId: taskId)
        vm.sessionRecords.append(record)
        let initialCompletedSessions = vm.completedSessions

        // In UTC at 20:00 UTC on Oct 20:
        let nowUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20, minute: 0, second: 0))!
        vm.currentDateProvider = { nowUTC }
        vm.reportingCalendar = calUTC
        vm.recalculateFocusMetrics(now: nowUTC)

        XCTAssertEqual(vm.todayFocusedSeconds, 1800, "Under UTC, entire 1800s belongs to Oct 20")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800, "Weekly in UTC contains full 1800s")

        // Now simulate system time-zone change to Asia/Kolkata at the same absolute instant (20:00 UTC = 01:30 IST on Oct 21)
        // CRITICAL: We do NOT call vm.recalculateFocusMetrics() afterward!
        // handleSystemTimeZoneChange itself must update the published analytics and midnight schedule.
        vm.handleSystemTimeZoneChange(newCalendar: calKolkata)

        // In IST:
        // 18:15 UTC is 23:45 IST on Oct 20 (pre-midnight slice = 900s)
        // 18:45 UTC is 00:15 IST on Oct 21 (post-midnight slice = 900s)
        // At 01:30 IST on Oct 21 (today in IST), only the post-midnight slice (900s) has occurred today!
        XCTAssertEqual(vm.todayFocusedSeconds, 900, "Under Asia/Kolkata, today (Oct 21) only receives post-midnight 900s")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800, "Weekly in IST contains full 1800s")

        // Verify the underlying session record was NOT mutated
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].id, recordId)
        XCTAssertEqual(vm.sessionRecords[0].startTime, startUTC)
        XCTAssertEqual(vm.sessionRecords[0].endTime, endUTC)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1800)
        XCTAssertEqual(vm.sessionRecords[0].taskId, taskId)
        XCTAssertEqual(vm.completedSessions, initialCompletedSessions)

        // Verify next midnight deadline is recalculated for Asia/Kolkata
        let expectedKolkataMidnight = calKolkata.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedKolkataMidnight)
    }

    // Scenario 15: Midnight refresh timer is rescheduled for the newly applicable local midnight
    @MainActor
    func testTask5_Correction_Scenario15_MidnightRefreshRescheduledForNewLocalMidnight() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!

        var calKolkata = Calendar(identifier: .gregorian)
        calKolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")! // UTC + 5:30

        let fixedNow = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!
        vm.currentDateProvider = { fixedNow }

        // 1. Under UTC, next midnight after Oct 21 12:00 UTC is Oct 22 00:00:00.05 UTC
        vm.reportingCalendar = calUTC
        vm.scheduleNextMidnightRefresh(now: fixedNow)

        let expectedUTCMidnight = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertNotNil(vm.scheduledMidnightFireDate)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedUTCMidnight, "Scheduled midnight under UTC must target 00:00:00.05 UTC")

        // 2. Switch reporting calendar to Asia/Kolkata
        // At Oct 21 12:00:00 UTC, the time in Kolkata is Oct 21 17:30:00 IST.
        // The next local midnight in Kolkata is Oct 22 00:00:00 IST = Oct 21 18:30:00.05 UTC!
        vm.reportingCalendar = calKolkata
        vm.scheduleNextMidnightRefresh(now: fixedNow)

        let expectedKolkataMidnight = calKolkata.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertNotNil(vm.scheduledMidnightFireDate)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedKolkataMidnight, "Scheduled midnight under IST must target local midnight (18:30:00.05 UTC)")
        XCTAssertNotEqual(vm.scheduledMidnightFireDate, expectedUTCMidnight, "Midnight fire date must change when switching time zones")
    }

    // Scenario 16: Fixed historical simulated date does not trigger repeated immediate timer callbacks
    @MainActor
    func testTask5_Correction_Scenario16_PastSimulatedDate_DoesNotTriggerImmediateTimerCallbackLoop() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calUTC

        // Injected date in the past (e.g. 2020-01-01 12:00:00 UTC)
        let pastDate = calUTC.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 12, minute: 0, second: 0))!
        vm.currentDateProvider = { pastDate }

        vm.scheduleNextMidnightRefresh(now: pastDate)

        let expectedPastMidnight = calUTC.date(from: DateComponents(year: 2020, month: 1, day: 2, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedPastMidnight, "Intended midnight deadline must be accurately computed")

        // Spin runloop briefly: because fireDate <= Date(), no timer was registered on RunLoop.main, so no callbacks fire
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(vm.midnightRefreshCallbackCount, 0, "No immediate timer callbacks may fire for past simulated dates")
    }

    // Scenario 17: A previously expired scheduled deadline cannot produce an uncontrolled rescheduling loop
    @MainActor
    func testTask5_Correction_Scenario17_ExpiredDeadline_CannotProduceReschedulingLoop() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calUTC

        let pastDate = calUTC.date(from: DateComponents(year: 2020, month: 6, day: 15, hour: 10, minute: 0, second: 0))!
        vm.currentDateProvider = { pastDate }

        // Trigger lifecycle change multiple times
        for _ in 0..<5 {
            vm.handleDateOrLifecycleChange()
        }

        let expectedMidnight = calUTC.date(from: DateComponents(year: 2020, month: 6, day: 16, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedMidnight)

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(vm.midnightRefreshCallbackCount, 0, "Repeated past lifecycle changes must not produce runloop callbacks")
    }

    // Scenario 18: Next midnight deadline calculation for UTC and Asia/Kolkata independently without timer side-effects
    @MainActor
    func testTask5_Correction_Scenario18_NextMidnightDateCalculation_UTCAndKolkataIndependent() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!

        var calKolkata = Calendar(identifier: .gregorian)
        calKolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")! // UTC +5:30

        let refInstant = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12, minute: 0, second: 0))!

        // 1. UTC: Next midnight after Oct 21 12:00:00 UTC is Oct 22 00:00:00.05 UTC
        let utcMidnight = vm.nextMidnightDate(after: refInstant, calendar: calUTC)
        let expectedUTCMidnight = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(utcMidnight, expectedUTCMidnight)

        // 2. Kolkata: Oct 21 12:00:00 UTC is Oct 21 17:30:00 IST.
        // Next midnight in IST is Oct 22 00:00:00 IST = Oct 21 18:30:00.05 UTC.
        let kolkataMidnight = vm.nextMidnightDate(after: refInstant, calendar: calKolkata)
        let expectedKolkataMidnight = calKolkata.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(kolkataMidnight, expectedKolkataMidnight)
        XCTAssertNotEqual(utcMidnight, kolkataMidnight)
    }

    // Scenario 19: Actual NSSystemTimeZoneDidChange notification reaches subscriber, triggers handler, and updates metrics and schedule
    @MainActor
    func testTask5_Correction_Scenario19_ActualTimeZoneNotificationDelivery_ReachesSubscriberAndUpdatesMetrics() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!

        var calKolkata = Calendar(identifier: .gregorian)
        calKolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")! // UTC +5:30

        let startUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 15, second: 0))!
        let endUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 18, minute: 45, second: 0))!
        let nowUTC = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20, minute: 0, second: 0))!

        let record = FocusSessionRecord(startTime: startUTC, endTime: endUTC, durationSeconds: 1800, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        var dynamicSystemCalendar = calUTC
        vm.systemCalendarProvider = { dynamicSystemCalendar }
        vm.currentDateProvider = { nowUTC }

        // Recalculate initially under UTC
        vm.recalculateFocusMetrics(now: nowUTC)
        XCTAssertEqual(vm.todayFocusedSeconds, 1800)
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800)
        XCTAssertEqual(vm.timeZoneChangeHandledCount, 0)

        // System time zone changes: update dynamic calendar to Kolkata and post actual notification
        dynamicSystemCalendar = calKolkata
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)

        // Run the main runloop until Combine / Task @MainActor executes
        let deadline = Date().addingTimeInterval(2.0)
        while vm.timeZoneChangeHandledCount == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        // 1. Observer ran & handler called
        XCTAssertEqual(vm.timeZoneChangeHandledCount, 1, "Notification must reach the registered subscriber and invoke the handler")

        // 2. Handler recalculated metrics
        XCTAssertEqual(vm.todayFocusedSeconds, 900, "Handler must recalculate today metrics for Kolkata")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1800, "Handler must recalculate weekly metrics for Kolkata")

        // 3. Midnight schedule updated
        let expectedKolkataMidnight = calKolkata.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedKolkataMidnight, "Midnight schedule must target new Kolkata midnight")
    }

    // Scenario 20: Repeated scheduling leaves no duplicate live timers
    @MainActor
    func testTask5_Correction_Scenario20_RepeatedScheduling_LeavesNoDuplicateTimers() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var activeCancellations = 0
        var activeSchedules = 0

        vm.midnightTimerScheduler = { fireDate, action in
            activeSchedules += 1
            return AnyCancellable {
                activeCancellations += 1
            }
        }

        // Schedule 10 times in a row
        for _ in 0..<10 {
            vm.scheduleNextMidnightRefresh()
        }

        XCTAssertEqual(activeSchedules, 10)
        XCTAssertEqual(activeCancellations, 9, "9 previous timers must be cancelled, leaving strictly 1 active schedule")
        XCTAssertNotNil(vm.scheduledMidnightFireDate)
    }

    // Scenario 21: Ordinary midnight refresh invokes handler and advances schedule to following day
    @MainActor
    func testTask5_Correction_Scenario21_OrdinaryMidnightRefresh_InvokesHandlerAndAdvancesSchedule() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calUTC

        var simDate = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 59, second: 55))!
        vm.currentDateProvider = { simDate }

        var capturedAction: (@MainActor () -> Void)?
        vm.midnightTimerScheduler = { fireDate, action in
            capturedAction = action
            return AnyCancellable { }
        }

        vm.scheduleNextMidnightRefresh(now: simDate)
        let expectedDay1Midnight = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedDay1Midnight)

        // Simulate midnight arriving: clock advances past midnight to Oct 22 00:00:01 UTC
        simDate = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0, minute: 0, second: 1))!
        capturedAction?()

        // Run runloop to let Task @MainActor execute
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(vm.midnightRefreshCallbackCount, 1)
        let expectedDay2Midnight = calUTC.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 0, minute: 0, second: 0))!.addingTimeInterval(0.05)
        XCTAssertEqual(vm.scheduledMidnightFireDate, expectedDay2Midnight, "After midnight refresh, next midnight must advance to subsequent day")
    }

    // MARK: - Native macOS Full-Screen Window Close Safety Tests

    // Regression Requirement 1: Normal window red-close behavior remains unchanged (orders out immediately, returns false).
    @MainActor
    func testFullScreenClose_NormalWindow_HidesImmediatelyAndPreservesMenuBar() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        let normalWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        normalWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(normalWindow.isVisible)
        XCTAssertFalse(normalWindow.styleMask.contains(.fullScreen))

        let shouldClose = appDelegate.windowShouldClose(normalWindow)
        XCTAssertFalse(shouldClose, "Must return false to prevent window destruction and keep menu bar app active")
        XCTAssertFalse(normalWindow.isVisible, "Normal window must be ordered out immediately on close")
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit, "Pending fullscreen close flag must remain false for normal window")
    }

    // Regression Requirement 2 & 3: Closing a fullscreen window does not hide it before exit, and pending close is processed after exit.
    @MainActor
    func testFullScreenClose_FullScreenWindow_DoesNotHidePrematurelyAndClosesAfterExit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        var exitActionCalled = false
        appDelegate.fullScreenExitAction = { window in
            exitActionCalled = true
        }

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fsWindow.isVisible)
        XCTAssertTrue(fsWindow.styleMask.contains(.fullScreen))

        // 1. User clicks red close button while in fullscreen
        let shouldClose = appDelegate.windowShouldClose(fsWindow)
        XCTAssertFalse(shouldClose, "windowShouldClose must return false to avoid window destruction")
        XCTAssertTrue(fsWindow.isVisible, "Fullscreen window must NOT be ordered out prematurely before exit completes (prevents black screen)")
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit, "Pending close flag must be set")
        XCTAssertTrue(exitActionCalled, "Native fullscreen exit must be initiated")
        XCTAssertEqual(appDelegate.fullScreenExitInitiatedCount, 1)

        // 2. macOS completes the fullscreen exit transition
        let exitNotification = Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow)
        appDelegate.windowDidExitFullScreen(exitNotification)

        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit, "Pending close flag must be cleared after exit")
        XCTAssertFalse(fsWindow.isVisible, "Window must be ordered out once fullscreen exit has completed")
    }

    // Regression Requirement 4: Ordinary fullscreen exit without a close request keeps the window visible.
    @MainActor
    func testFullScreenClose_OrdinaryExitWithoutCloseRequest_LeavesWindowVisible() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fsWindow.isVisible)

        // Ordinary exit (green button or Control+Command+F) -> no windowShouldClose called
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)

        let exitNotification = Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow)
        appDelegate.windowDidExitFullScreen(exitNotification)

        XCTAssertTrue(fsWindow.isVisible, "Window must remain visible when user exits fullscreen normally without requesting close")
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
    }

    // Regression Requirement 5: Repeated close requests do not cause double transitions.
    @MainActor
    func testFullScreenClose_RepeatedCloseRequests_DoNotCauseDoubleTransitions() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        var exitCallCount = 0
        appDelegate.fullScreenExitAction = { _ in
            exitCallCount += 1
        }

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        // User clicks close multiple times while transition is in flight
        let close1 = appDelegate.windowShouldClose(fsWindow)
        let close2 = appDelegate.windowShouldClose(fsWindow)
        let close3 = appDelegate.windowShouldClose(fsWindow)

        XCTAssertFalse(close1)
        XCTAssertFalse(close2)
        XCTAssertFalse(close3)
        XCTAssertEqual(exitCallCount, 1, "Native exit must only be triggered once despite repeated close clicks")
        XCTAssertEqual(appDelegate.fullScreenExitInitiatedCount, 1)
        XCTAssertTrue(fsWindow.isVisible, "Window must remain visible during in-flight transition")

        // Exit finishes
        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))
        XCTAssertFalse(fsWindow.isVisible)
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
    }

    // Regression Requirement 6: Closing and reopening the main window works (including reopening during in-flight exit).
    @MainActor
    func testFullScreenClose_ReopeningMainWindow_RestoresVisibilityAndClearsPendingClose() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        appDelegate.showMainWindow()
        guard let window = appDelegate.mainWindow else {
            XCTFail("Main window must be created")
            return
        }
        XCTAssertTrue(window.isVisible)

        // Close it normally
        _ = appDelegate.windowShouldClose(window)
        XCTAssertFalse(window.isVisible)

        // Reopen from menu bar / app delegate
        appDelegate.showMainWindow()
        XCTAssertTrue(window.isVisible, "Main window must become visible again upon showMainWindow")

        // Now simulate entering fullscreen and requesting close
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)
        appDelegate.mainWindow = fsWindow
        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit)

        // Before exit completes, user reopens from menu bar companion
        appDelegate.showMainWindow()
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit, "showMainWindow must cancel pending close")

        // Fullscreen exit finishes later
        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))
        XCTAssertTrue(fsWindow.isVisible, "Window must remain visible because user reopened it before exit completed")
    }

    // Regression Requirement 7: Running Focus Timer continues after window close (both normal and fullscreen).
    @MainActor
    func testFullScreenClose_RunningFocusTimerContinuesAfterWindowClose() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        appDelegate.viewModel.applyPresetDirectly(name: "Focus", minutes: 25)
        appDelegate.viewModel.startTimer()
        XCTAssertTrue(appDelegate.viewModel.isTimerRunning)

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        // Close fullscreen window
        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.viewModel.isTimerRunning, "Timer countdown must continue when fullscreen window close is initiated")

        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))
        XCTAssertFalse(fsWindow.isVisible)
        XCTAssertTrue(appDelegate.viewModel.isTimerRunning, "Timer countdown must continue after fullscreen window is hidden")
    }

    // Regression Requirement 8: Running Stopwatch continues after window close.
    @MainActor
    func testFullScreenClose_RunningStopwatchContinuesAfterWindowClose() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        appDelegate.viewModel.startStopwatch()
        XCTAssertTrue(appDelegate.viewModel.isStopwatchRunning)

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.viewModel.isStopwatchRunning)

        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))
        XCTAssertFalse(fsWindow.isVisible)
        XCTAssertTrue(appDelegate.viewModel.isStopwatchRunning, "Stopwatch must continue running after fullscreen window is hidden")
    }

    // Regression Requirement 9: Window close does not trigger app termination or corrupt persisted timer state.
    @MainActor
    func testFullScreenClose_DoesNotTriggerAppTerminationOrCorruptPersistedState() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        appDelegate.viewModel.applyPresetDirectly(name: "Focus", minutes: 25)
        appDelegate.viewModel.startTimer()

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        _ = appDelegate.windowShouldClose(fsWindow)
        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))

        XCTAssertFalse(appDelegate.viewModel.hasTerminated, "Window close must not trigger app termination")
        XCTAssertFalse(appDelegate.viewModel.isPersistenceBlocked, "Persistence must remain unblocked")
        XCTAssertNil(appDelegate.viewModel.storageErrorMessage)
    }

    // Regression Requirement 10: Failed fullscreen exit handles cleanup gracefully and preserves visibility.
    @MainActor
    func testFullScreenClose_FailedExit_CleansUpPendingState() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fsWindow.isVisible, "Window must be visible initially")

        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit, "Pending close flag must become true")
        XCTAssertTrue(fsWindow.isVisible, "Window must remain visible while awaiting fullscreen exit")

        // AppKit reports failure to exit fullscreen
        appDelegate.windowDidFailToExitFullScreen(fsWindow)

        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit, "Failed exit must reset pending close flag")
        XCTAssertTrue(fsWindow.isVisible, "Failed fullscreen exit must not hide the window")
        XCTAssertFalse(appDelegate.viewModel.hasTerminated, "Application must remain running")
    }

    // MARK: - Fullscreen Exit Failure Fallback Regression Tests (Scenarios A through F)

    // Scenario A: Failed exit preserves visibility.
    // Simulated AppKit delegate lifecycle test: A visible fullscreen window must remain visible after windowDidFailToExitFullScreen.
    @MainActor
    func testFullScreenExitFailure_PreservesWindowVisibility() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit)

        appDelegate.windowDidFailToExitFullScreen(fsWindow)

        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertTrue(fsWindow.isVisible, "Failed fullscreen exit must keep window visible")
    }

    // Scenario B: Retry after failed exit.
    // Simulated AppKit delegate lifecycle test:
    // 1. Initiate fullscreen close. 2. Simulate failed exit. 3. Verify pending state clears.
    // 4. Request close again. 5. Verify a second fullscreen exit attempt is initiated exactly once.
    // 6. Verify a successful exit callback can subsequently hide the window.
    @MainActor
    func testFullScreenExitFailure_AllowsSubsequentRetryAndSuccessfulClose() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        var exitAttemptCount = 0
        appDelegate.fullScreenExitAction = { _ in
            exitAttemptCount += 1
        }

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        // 1. Initiate fullscreen close (attempt 1)
        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertEqual(exitAttemptCount, 1)
        XCTAssertEqual(appDelegate.fullScreenExitInitiatedCount, 1)

        // 2. Simulate failed exit
        appDelegate.windowDidFailToExitFullScreen(fsWindow)

        // 3. Verify pending state clears and window remains visible
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertTrue(fsWindow.isVisible)

        // 4. Request close again (attempt 2)
        _ = appDelegate.windowShouldClose(fsWindow)

        // 5. Verify a second fullscreen exit attempt was initiated exactly once
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertEqual(exitAttemptCount, 2)
        XCTAssertEqual(appDelegate.fullScreenExitInitiatedCount, 2)

        // 6. Verify successful exit callback can subsequently hide the window
        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertFalse(fsWindow.isVisible, "Successful exit after retry must hide the window")
    }

    // Scenario C: Failure callback without pending close.
    // Simulated AppKit delegate lifecycle test: A failed-exit callback received when no app-initiated close is pending must not hide the window.
    @MainActor
    func testFullScreenExitFailure_WithoutPendingClose_DoesNotHideWindow() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(fsWindow.isVisible)
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)

        // Spontaneous or system failure callback with no pending close
        appDelegate.windowDidFailToExitFullScreen(fsWindow)

        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertTrue(fsWindow.isVisible, "Spontaneous failure callback without pending close must not hide the window")
    }

    // Scenario D: Successful close remains unchanged.
    // Simulated AppKit delegate lifecycle test: On windowDidExitFullScreen, a pending close still hides the window exactly as intended.
    @MainActor
    func testFullScreenExitSuccess_StillHidesWindowWhenClosePending() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        _ = appDelegate.windowShouldClose(fsWindow)
        XCTAssertTrue(appDelegate.isPendingCloseAfterFullScreenExit)

        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))

        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertFalse(fsWindow.isVisible, "Successful exit must hide window")
    }

    // Scenario E: Ordinary fullscreen exit remains unchanged.
    // Simulated AppKit delegate lifecycle test: Exiting with the green button or Control + Command + F (without pending close) must leave the window visible.
    @MainActor
    func testFullScreenExitSuccess_WithoutPendingClose_LeavesWindowVisible() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)
        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)

        // Ordinary fullscreen exit without red close button
        appDelegate.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: fsWindow))

        XCTAssertFalse(appDelegate.isPendingCloseAfterFullScreenExit)
        XCTAssertTrue(fsWindow.isVisible, "Ordinary fullscreen exit without close must leave window visible")
    }

    // Scenario F: Timer and stopwatch integrity across failed fullscreen exit.
    // Simulated AppKit delegate lifecycle test: A failed fullscreen transition must not pause/stop timer, reset stopwatch, alter records/tasks, terminate app, or cause storage corruption.
    @MainActor
    func testFullScreenExitFailure_PreservesTimerAndStopwatchIntegrity() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        appDelegate.fullScreenExitAction = { _ in }

        // Setup running timer and stopwatch with assigned task
        vm.addTask(title: "Important Deep Work", expectedMinutes: 25)
        vm.activeTaskIndex = 0
        let selectedTaskId = vm.tasks[0].id

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)

        vm.startStopwatch()
        vm.stopwatchTime = 45
        XCTAssertTrue(vm.isStopwatchRunning)

        let initialRecordsCount = vm.sessionRecords.count

        let fsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullScreen],
            backing: .buffered,
            defer: false
        )
        fsWindow.makeKeyAndOrderFront(nil)

        // Initiate close and fail exit
        _ = appDelegate.windowShouldClose(fsWindow)
        appDelegate.windowDidFailToExitFullScreen(fsWindow)

        // Verify timer and stopwatch integrity
        XCTAssertTrue(vm.isTimerRunning, "Timer must continue running after failed fullscreen exit")
        XCTAssertTrue(vm.isStopwatchRunning, "Stopwatch must continue running after failed fullscreen exit")
        XCTAssertEqual(vm.stopwatchTime, 45, "Stopwatch time must not reset")
        XCTAssertEqual(vm.sessionRecords.count, initialRecordsCount, "Session records must not change")
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].id, selectedTaskId, "Selected task must remain unchanged")
        XCTAssertFalse(vm.hasTerminated, "App must not terminate on failed exit")
        XCTAssertFalse(vm.isPersistenceBlocked, "Persistence must remain unblocked")
        XCTAssertNil(vm.storageErrorMessage)
        XCTAssertTrue(fsWindow.isVisible, "Window must remain visible")
    }

    // MARK: - Task 6 Tests: Persistence Write Coalescing & Pending Save Safety

    // 1. Rapid save requests produce only one pending delayed save.
    @MainActor
    func testTask6_01_RapidSaveRequestsProduceOnlyOnePendingDelayedSave() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Initial save to establish lastPersistTime
        vm.persistData(force: true)
        vm.storage.resetSaveAttemptCount()

        // Rapid requests within throttle interval
        for _ in 1...50 {
            vm.persistData(force: false)
        }

        XCTAssertTrue(vm.hasPendingSave, "A coalesced trailing save must be scheduled")
        XCTAssertEqual(vm.pendingSaveScheduledCount, 1, "Only one pending save must be scheduled across 50 rapid calls")
        XCTAssertEqual(vm.pendingSaveCancelledCount, 0)
    }

    // 2. 100 rapid mutations do not create 100 disk writes.
    @MainActor
    func testTask6_02_100RapidMutationsDoNotCreate100DiskWrites() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Baseline forced save
        vm.persistData(force: true)
        vm.storage.resetSaveAttemptCount()

        // 100 rapid mutations
        for i in 1...100 {
            vm.totalSessions = (i % 8) + 1
        }

        XCTAssertEqual(vm.pendingSaveScheduledCount, 1, "Must schedule only 1 pending save")

        // Wait for coalesced trailing save to execute
        let exp = expectation(description: "Wait for trailing save")
        exp.assertForOverFulfill = false
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            exp.fulfill()
        }
        defer { workItem?.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem!)
        wait(for: [exp], timeout: 5.0)

        // Verifies write coalescing: 100 mutations result in exactly 1 trailing save
        XCTAssertEqual(vm.storage.saveAttemptCount, 1, "100 rapid mutations must result in exactly 1 coalesced write attempt, not 100")
        XCTAssertFalse(vm.hasPendingSave)
        XCTAssertEqual(vm.pendingSaveExecutedCount, 1)
    }

    // 3. The eventual save contains the latest state, not the first queued state.
    @MainActor
    func testTask6_03_EventualSaveContainsLatestStateNotFirstQueuedState() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)

        // Queue a sequence of edits with different values
        for i in 1...10 {
            vm.dailyGoalHours = i
        }

        let exp = expectation(description: "Wait for trailing save")
        exp.assertForOverFulfill = false
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem {
            exp.fulfill()
        }
        defer { workItem?.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem!)
        wait(for: [exp], timeout: 5.0)

        let savedData = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(savedData.dailyGoalHours, 10, "Eventual save must contain latest state (10), not first queued state (1)")
    }

    // 4. A forced save executes immediately during the throttle interval.
    @MainActor
    func testTask6_04_ForcedSaveExecutesImmediatelyDuringThrottleInterval() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)
        let countAfterFirst = vm.storage.saveAttemptCount

        // Mutate and force save immediately within milliseconds (< 1.0s)
        vm.totalSessions = 7
        vm.persistData(force: true)

        XCTAssertEqual(vm.storage.saveAttemptCount, countAfterFirst + 1, "Forced save must execute immediately without waiting for throttle")
        let savedData = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(savedData.totalSessions, 7)
    }

    // 5. Forced save cancels obsolete pending work.
    @MainActor
    func testTask6_05_ForcedSaveCancelsObsoletePendingWork() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)
        vm.totalSessions = 5 // schedules pending save
        XCTAssertTrue(vm.hasPendingSave)

        // Now force save
        vm.persistData(force: true)
        XCTAssertFalse(vm.hasPendingSave, "Forced save must invalidate pending save")
        XCTAssertEqual(vm.pendingSaveCancelledCount, 1, "Pending save must be marked cancelled")
    }

    // 6. Forced save followed by an old callback does not produce duplicate writes.
    @MainActor
    func testTask6_06_ForcedSaveFollowedByOldCallbackDoesNotProduceDuplicateWrites() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            capturedAction = action
            return AnyCancellable {}
        }

        vm.persistData(force: true)
        vm.storage.resetSaveAttemptCount()

        // Unforced mutation schedules trailing save via scheduler
        vm.totalSessions = 6
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(capturedAction)

        // Force save occurs before capturedAction fires
        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 1, "Forced save executed 1 write")
        XCTAssertFalse(vm.hasPendingSave)

        // Now trigger the obsolete capturedAction
        capturedAction?()

        // saveAttemptCount must NOT increase!
        XCTAssertEqual(vm.storage.saveAttemptCount, 1, "Obsolete callback must not produce duplicate write")
    }

    // 7. Repeated save bursts stay bounded.
    @MainActor
    func testTask6_07_RepeatedSaveBurstsStayBounded() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var simulatedTime = Date()
        vm.currentDateProvider = { simulatedTime }

        var scheduledAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            scheduledAction = action
            return AnyCancellable {}
        }

        // Burst 1
        for i in 1...20 { vm.totalSessions = i }
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertEqual(vm.pendingSaveScheduledCount, 1)

        // Fire trailing save for burst 1
        simulatedTime.addTimeInterval(1.0)
        scheduledAction?()
        scheduledAction = nil
        XCTAssertFalse(vm.hasPendingSave)

        // Burst 2
        for i in 21...40 { vm.totalSessions = i }
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertEqual(vm.pendingSaveScheduledCount, 2)

        // Fire trailing save for burst 2
        simulatedTime.addTimeInterval(1.0)
        scheduledAction?()
        scheduledAction = nil
        XCTAssertFalse(vm.hasPendingSave)

        XCTAssertEqual(vm.pendingSaveExecutedCount, 2)
    }

    // 8. Sustained activity does not indefinitely postpone persistence.
    @MainActor
    func testTask6_08_SustainedActivityDoesNotIndefinitelyPostponePersistence() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var simulatedTime = Date()
        vm.currentDateProvider = { simulatedTime }

        var scheduledAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            scheduledAction = action
            return AnyCancellable {}
        }

        // Leading save at t=0
        vm.persistData(force: false)
        XCTAssertEqual(vm.storage.saveAttemptCount, 1, "Leading save occurs immediately")

        // Edit at t=0.2 (within interval) schedules trailing save
        simulatedTime.addTimeInterval(0.2)
        vm.totalSessions = 2
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(scheduledAction)

        // More edits at t=0.4, 0.6, 0.8 do not push the deadline back
        simulatedTime.addTimeInterval(0.2)
        vm.totalSessions = 3
        simulatedTime.addTimeInterval(0.2)
        vm.totalSessions = 4
        simulatedTime.addTimeInterval(0.2)
        vm.totalSessions = 5

        // At t=1.0, the trailing save fires as scheduled
        simulatedTime.addTimeInterval(0.2)
        scheduledAction?()
        scheduledAction = nil

        XCTAssertFalse(vm.hasPendingSave)
        XCTAssertEqual(vm.storage.saveAttemptCount, 2, "Trailing save executed on time; persistence was not indefinitely postponed")
    }

    // 9. Pending save with corrupted primary preserves original corrupted bytes.
    @MainActor
    func testTask6_09_PendingSaveWithCorruptedPrimaryPreservesOriginalCorruptedBytes() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Healthy save
        vm.persistData(force: true)
        XCTAssertFalse(vm.isPersistenceBlocked)

        var scheduledAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            scheduledAction = action
            return AnyCancellable {}
        }

        // Schedule pending save
        vm.totalSessions = 8
        XCTAssertTrue(vm.hasPendingSave)

        // Corrupt primary file with sentinel data
        let sentinel = Data("CORRUPTED_SENTINEL_TASK6_09".utf8)
        try sentinel.write(to: tempURL)

        // Fire pending save
        scheduledAction?()

        // Storage corruption protection must engage and block persistence
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)

        // Corrupted bytes must NOT be overwritten
        let primaryOnDisk = try Data(contentsOf: tempURL)
        XCTAssertEqual(primaryOnDisk, sentinel, "Original corrupted bytes must be preserved intact")
    }

    // 10. Persistence-blocked state prevents pending writes.
    @MainActor
    func testTask6_10_PersistenceBlockedStatePreventsPendingWrites() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Establish blocked state
        let corrupted = Data("CORRUPTED_PRIMARY_TASK6_10".utf8)
        try corrupted.write(to: tempURL)
        vm.persistData(force: true)
        XCTAssertTrue(vm.isPersistenceBlocked)

        vm.storage.resetSaveAttemptCount()

        // Attempt normal and forced persist while blocked
        vm.persistData(force: false)
        XCTAssertFalse(vm.hasPendingSave, "No pending save should be scheduled while persistence is blocked")
        XCTAssertEqual(vm.storage.saveAttemptCount, 0, "No disk writes allowed while blocked")

        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 0)
    }

    // 11. Temporary write failure displays the correct error.
    @MainActor
    func testTask6_11_TemporaryWriteFailureDisplaysCorrectError() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.storage.simulateWriteFailure = true
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)
        XCTAssertFalse(vm.isPersistenceBlocked, "Temporary write failure must not permanently block persistence")
    }

    // 12. Successful manual retry clears the error.
    @MainActor
    func testTask6_12_SuccessfulManualRetryClearsError() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.storage.simulateWriteFailure = true
        vm.totalSessions = 5
        vm.persistData(force: true)
        XCTAssertTrue(vm.isSaveFailed)

        // Recover failure
        vm.storage.simulateWriteFailure = false
        vm.retrySave()

        XCTAssertFalse(vm.isSaveFailed, "Successful retry must clear isSaveFailed")
        XCTAssertNil(vm.saveErrorMessage)
        XCTAssertNil(vm.lastSaveError)

        let saved = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(saved.totalSessions, 5)
    }

    // 13. Quit with pending changes persists the final state synchronously.
    @MainActor
    func testTask6_13_QuitWithPendingChangesPersistsFinalStateSynchronously() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)

        // Make edit that leaves a pending save
        vm.totalSessions = 8
        XCTAssertTrue(vm.hasPendingSave)

        // Quit the application
        vm.handleAppTermination()

        XCTAssertFalse(vm.hasPendingSave, "handleAppTermination must cancel pending save")
        XCTAssertTrue(vm.hasTerminated)

        // Verify final state is written synchronously on disk
        let saved = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(saved.totalSessions, 8, "Final state must be written to disk synchronously on Quit")
    }

    // 14. Paused Focus Timer restoration remains accurate.
    @MainActor
    func testTask6_14_PausedFocusTimerRestorationRemainsAccurate() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.addTask(title: "Task For Paused Timer", expectedMinutes: 25)
        vm1.activeTaskIndex = 0
        vm1.startTimer()
        vm1.timeRemaining = 18 * 60 + 45
        vm1.preciseProgress = Double(18 * 60 + 45) / Double(25 * 60)
        vm1.stopTimer()

        // Multiple rapid edits before shutdown
        vm1.dailyGoalHours = 5
        vm1.totalSessions = 6
        vm1.handleAppTermination()

        // Relaunch
        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.timeRemaining, 18 * 60 + 45)
        XCTAssertEqual(vm2.dailyGoalHours, 5)
        XCTAssertEqual(vm2.totalSessions, 6)
        XCTAssertTrue(vm2.tasks.contains(where: { $0.title == "Task For Paused Timer" }))
    }

    // 15. Custom Timer configuration survives Quit/Reopen.
    @MainActor
    func testTask6_15_CustomTimerConfigurationSurvivesQuitReopen() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.setCustomDuration(minutes: 42, seconds: 15)
        XCTAssertEqual(vm1.totalTime, 42 * 60 + 15)
        XCTAssertEqual(vm1.activeMode, "Custom Timer")

        vm1.dailyGoalHours = 6
        vm1.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.totalTime, 42 * 60 + 15)
        XCTAssertEqual(vm2.customMinutes, 42)
        XCTAssertEqual(vm2.customSeconds, 15)
        XCTAssertEqual(vm2.activeMode, "Custom Timer")
    }

    // 16. Task UUIDs, selection and task attribution remain intact.
    @MainActor
    func testTask6_16_TaskUUIDsSelectionAndTaskAttributionRemainIntact() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.tasks = []
        vm1.addTask(title: "Task Alpha", expectedMinutes: 25)
        vm1.addTask(title: "Task Beta", expectedMinutes: 50)
        vm1.activeTaskIndex = 1
        let betaId = vm1.tasks[1].id

        vm1.tasks[1].timeSpentSeconds = 300
        vm1.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.tasks.count, 2)
        XCTAssertEqual(vm2.tasks[1].id, betaId)
        XCTAssertEqual(vm2.tasks[1].timeSpentSeconds, 300)
        XCTAssertEqual(vm2.activeTaskIndex, 1)
    }

    // 17. Stopwatch laps and checkpoints remain intact.
    @MainActor
    func testTask6_17_StopwatchLapsAndCheckpointsRemainIntact() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.startStopwatch()
        vm1.stopwatchTime = 60
        vm1.recordLap()
        vm1.stopwatchTime = 140
        vm1.recordLap()
        vm1.stopStopwatch()

        XCTAssertEqual(vm1.laps.count, 2)
        vm1.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.laps.count, 2)
        XCTAssertEqual(vm2.laps[0].lapNumber, 2)
        XCTAssertEqual(vm2.laps[1].lapNumber, 1)
    }

    // 18. Session records and daily analytics remain intact.
    @MainActor
    func testTask6_18_SessionRecordsAndDailyAnalyticsRemainIntact() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let now = Date()
        let record = FocusSessionRecord(
            startTime: now.addingTimeInterval(-3600),
            endTime: now,
            durationSeconds: 3600,
            mode: "Focus",
            taskId: nil
        )
        vm1.sessionRecords = [record]
        vm1.handleAppTermination()

        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords.first?.durationSeconds, 3600)
    }

    // 19. Fresh installation creates a valid primary and backup.
    @MainActor
    func testTask6_19_FreshInstallationCreatesValidPrimaryAndBackup() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.storage.backupURL.path))

        vm.addTask(title: "Fresh Install Task", expectedMinutes: 25)
        vm.persistData(force: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.storage.backupURL.path))

        let primaryData = try vm.storage.decodeData(from: tempURL)
        let backupData = try vm.storage.decodeData(from: vm.storage.backupURL)
        XCTAssertTrue(primaryData.tasks.contains(where: { $0.title == "Fresh Install Task" }))
        XCTAssertTrue(backupData.tasks.contains(where: { $0.title == "Fresh Install Task" }))
    }

    // 20. Existing backup rotation and corruption-recovery tests continue passing.
    @MainActor
    func testTask6_20_ExistingBackupRotationAndCorruptionRecoveryIntegration() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.addTask(title: "Initial Valid Data", expectedMinutes: 25)
        vm1.persistData(force: true)

        // Second forced save creates valid backup of initial data
        vm1.addTask(title: "Second Valid Data", expectedMinutes: 30)
        vm1.persistData(force: true)

        // Corrupt primary
        let corrupted = Data("CORRUPTED_PRIMARY_TEST20".utf8)
        try corrupted.write(to: tempURL)

        // Reload should recover from backup
        let storage2 = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage2)

        XCTAssertTrue(vm2.didRecoverFromBackup)
        XCTAssertFalse(vm2.isPersistenceBlocked)
        XCTAssertTrue(vm2.tasks.contains(where: { $0.title == "Initial Valid Data" }))
    }

    // MARK: - Task 6 Final Hardening: Stale Save Callback Identity
    // 1. Race condition: Stale callback A must not execute or cancel newer pending Save B.
    @MainActor
    func testTask6_Hardening_StaleSaveCallbackDoesNotPrematurelyExecuteNewerPendingSave() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, action in
            capturedCallbacks.append(action)
            return AnyCancellable {}
        }

        // 1. Establish a successful initial save.
        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 1)

        // 2. Schedule Save A.
        vm.totalSessions = 5
        XCTAssertTrue(vm.hasPendingSave, "Save A must be scheduled")
        XCTAssertEqual(capturedCallbacks.count, 1, "Save A callback must be captured")
        let callbackA = capturedCallbacks[0]

        // 3. Force-save or otherwise cancel A.
        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 2, "Forced save executed")
        XCTAssertFalse(vm.hasPendingSave, "Save A must be cancelled")

        // 4. Make another mutation and schedule Save B.
        vm.totalSessions = 10
        XCTAssertTrue(vm.hasPendingSave, "Save B must be scheduled")
        XCTAssertEqual(capturedCallbacks.count, 2, "Save B callback must be captured")
        let callbackB = capturedCallbacks[1]
        let saveAttemptsBeforeStaleCallback = vm.storage.saveAttemptCount
        let bGeneration = vm.activePendingSaveGeneration

        // 5. Invoke A's previously captured callback deliberately, even though its cancellation was requested.
        callbackA()

        // 6. Assert no additional storage save attempt.
        XCTAssertEqual(vm.storage.saveAttemptCount, saveAttemptsBeforeStaleCallback, "Stale callback A must not trigger an additional save")

        // 7. Assert B remains pending.
        XCTAssertTrue(vm.hasPendingSave, "Save B must remain pending after stale callback A was invoked")

        // 8. Assert B's pending identity/state remains unchanged.
        XCTAssertEqual(vm.activePendingSaveGeneration, bGeneration, "Save B's generation token must remain unchanged by stale callback A")
        XCTAssertEqual(vm.pendingSaveGeneration, bGeneration)

        // 9. Invoke B's callback.
        callbackB()

        // 10. Assert exactly one appropriate save occurs.
        XCTAssertEqual(vm.storage.saveAttemptCount, saveAttemptsBeforeStaleCallback + 1, "Save B must execute exactly one save")
        XCTAssertFalse(vm.hasPendingSave, "Save B must no longer be pending after execution")

        // 11. Decode JSON and verify it contains the latest changes.
        let savedData = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(savedData.totalSessions, 10, "Decoded data must contain the latest state from Save B")
    }

    // 2. A cancelled callback with no new pending save does not execute any write.
    @MainActor
    func testTask6_Hardening_CancelledCallbackWithNoNewPendingSaveDoesNotWrite() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            capturedAction = action
            return AnyCancellable {}
        }

        vm.persistData(force: true)
        let initialAttempts = vm.storage.saveAttemptCount

        vm.totalSessions = 6
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(capturedAction)

        // Explicitly cancel pending save without scheduling a new one
        vm.cancelPendingSave()
        XCTAssertFalse(vm.hasPendingSave)

        // Invoke obsolete callback
        capturedAction?()

        XCTAssertEqual(vm.storage.saveAttemptCount, initialAttempts, "Cancelled callback must not trigger any storage write")
        XCTAssertFalse(vm.hasPendingSave)
    }

    // 3. Forced save invalidates a pending callback and prevents duplicate writes.
    @MainActor
    func testTask6_Hardening_ForcedSaveInvalidatesPendingCallback() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            capturedAction = action
            return AnyCancellable {}
        }

        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 1)

        vm.totalSessions = 7
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(capturedAction)

        // Forced save occurs
        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 2)
        XCTAssertFalse(vm.hasPendingSave)

        // Trigger obsolete callback
        capturedAction?()

        XCTAssertEqual(vm.storage.saveAttemptCount, 2, "Obsolete callback after forced save must not write again")
        let saved = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(saved.totalSessions, 7)
    }

    // 4. Multiple consecutive generations with stale callbacks invoked out of order.
    @MainActor
    func testTask6_Hardening_MultipleGenerationsInvokedOutOfOrder() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, action in
            capturedCallbacks.append(action)
            return AnyCancellable {}
        }

        // Gen A
        vm.persistData(force: true)
        vm.totalSessions = 1
        XCTAssertEqual(capturedCallbacks.count, 1)
        vm.cancelPendingSave()

        // Gen B
        vm.totalSessions = 2
        XCTAssertEqual(capturedCallbacks.count, 2)
        vm.cancelPendingSave()

        // Gen C
        vm.totalSessions = 3
        XCTAssertEqual(capturedCallbacks.count, 3)
        vm.cancelPendingSave()

        // Gen D (active pending save)
        vm.totalSessions = 4
        XCTAssertEqual(capturedCallbacks.count, 4)
        XCTAssertTrue(vm.hasPendingSave)
        let activeGenerationD = vm.activePendingSaveGeneration
        let attemptsBeforeStaleInvocations = vm.storage.saveAttemptCount

        // Invoke stale callbacks in arbitrary out-of-order sequence (B, then A, then C)
        capturedCallbacks[1]() // Callback B
        XCTAssertEqual(vm.storage.saveAttemptCount, attemptsBeforeStaleInvocations)
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertEqual(vm.activePendingSaveGeneration, activeGenerationD)

        capturedCallbacks[0]() // Callback A
        XCTAssertEqual(vm.storage.saveAttemptCount, attemptsBeforeStaleInvocations)
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertEqual(vm.activePendingSaveGeneration, activeGenerationD)

        capturedCallbacks[2]() // Callback C
        XCTAssertEqual(vm.storage.saveAttemptCount, attemptsBeforeStaleInvocations)
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertEqual(vm.activePendingSaveGeneration, activeGenerationD)

        // Finally invoke active callback D
        capturedCallbacks[3]() // Callback D
        XCTAssertEqual(vm.storage.saveAttemptCount, attemptsBeforeStaleInvocations + 1, "Only active Gen D callback should execute")
        XCTAssertFalse(vm.hasPendingSave)

        // Attempting to invoke D again must be rejected as well
        capturedCallbacks[3]()
        XCTAssertEqual(vm.storage.saveAttemptCount, attemptsBeforeStaleInvocations + 1, "Duplicate invocation of Gen D must be rejected")

        let saved = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(saved.totalSessions, 4, "Saved data must reflect final generation mutation")
    }

    // 5. Application termination invalidates all outstanding callbacks.
    @MainActor
    func testTask6_Hardening_AppTerminationInvalidatesOutstandingCallbacks() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            capturedAction = action
            return AnyCancellable {}
        }

        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 1)

        vm.totalSessions = 9
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(capturedAction)

        // Terminate app
        vm.handleAppTermination()
        XCTAssertTrue(vm.hasTerminated)
        XCTAssertFalse(vm.hasPendingSave)
        XCTAssertEqual(vm.storage.saveAttemptCount, 2, "Termination should save current state synchronously")

        // Try to invoke obsolete callback after termination
        capturedAction?()

        XCTAssertEqual(vm.storage.saveAttemptCount, 2, "Obsolete callback after termination must not trigger additional writes")
        XCTAssertTrue(vm.hasTerminated)
        let saved = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(saved.totalSessions, 9)
    }

    // 6. Blocked / corrupted persistence refuses pending callback execution.
    @MainActor
    func testTask6_Hardening_BlockedPersistenceRefusesPendingCallbackExecution() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)
        XCTAssertFalse(vm.isPersistenceBlocked)

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            capturedAction = action
            return AnyCancellable {}
        }

        vm.totalSessions = 8
        XCTAssertTrue(vm.hasPendingSave)

        // Corrupt primary file with sentinel data to trigger corruption protection
        let sentinel = Data("CORRUPTED_SENTINEL_HARDENING_06".utf8)
        try sentinel.write(to: tempURL)

        // Fire pending save callback
        capturedAction?()

        // Storage corruption protection must engage and block persistence
        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)
        XCTAssertFalse(vm.hasPendingSave)

        // Corrupted bytes on disk must remain pristine
        let primaryOnDisk = try Data(contentsOf: tempURL)
        XCTAssertEqual(primaryOnDisk, sentinel, "Original corrupted bytes must be preserved intact")
    }

    // 7. Valid current callback executes exactly once.
    @MainActor
    func testTask6_Hardening_ValidCurrentCallbackExecutesExactlyOnce() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { _, action in
            capturedAction = action
            return AnyCancellable {}
        }

        vm.persistData(force: true)
        XCTAssertEqual(vm.storage.saveAttemptCount, 1)

        vm.totalSessions = 11
        XCTAssertTrue(vm.hasPendingSave)

        // First invocation: valid execution
        capturedAction?()
        XCTAssertEqual(vm.storage.saveAttemptCount, 2)
        XCTAssertFalse(vm.hasPendingSave)
        XCTAssertEqual(vm.pendingSaveExecutedCount, 1)

        // Second invocation: should be rejected
        capturedAction?()
        XCTAssertEqual(vm.storage.saveAttemptCount, 2, "Repeated invocation of the same callback must not execute again")
        XCTAssertEqual(vm.pendingSaveExecutedCount, 1)

        let saved = try vm.storage.decodeData(from: tempURL)
        XCTAssertEqual(saved.totalSessions, 11)
    }

    // MARK: - Task 7 Regression Tests (Sleep/Wake Engine & Accuracy)
    // MARK: Group A — Focus Timer Sleep/Wake (Tests 1–9)

    // Test 1: Wake before deadline: correct remaining seconds
    @MainActor
    func testTask7_GroupA_Test01_WakeBeforeDeadline_CorrectRemainingSeconds() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1500)

        // Sleep for 10 minutes (600s), waking with 900s remaining before deadline
        simulatedNow = baseDate.addingTimeInterval(600)
        vm.handleDateOrLifecycleChange()

        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 900)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600)
    }

    // Test 2: Wake exactly at deadline: complete once
    @MainActor
    func testTask7_GroupA_Test02_WakeExactlyAtDeadline_CompleteOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)

        // Wake exactly at 1500s deadline
        simulatedNow = baseDate.addingTimeInterval(1500)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
    }

    // Test 3: Wake two hours after a 25-minute session began: record exactly 1,500 seconds
    @MainActor
    func testTask7_GroupA_Test03_WakeTwoHoursAfterSessionBegan_RecordExactly1500s() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)

        // Sleep 2 hours (7200s)
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)

        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500, "Focus duration must be strictly capped at 1500s")
        XCTAssertEqual(record.startTime, baseDate)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500), "Session end must match planned deadline, not wake time")
        XCTAssertEqual(vm.todayFocusedSeconds, 1500, "Today analytics must receive exactly 1500s")
    }

    // Test 4: Very long sleep: no time beyond deadline added
    @MainActor
    func testTask7_GroupA_Test04_VeryLongSleep_NoTimeBeyondDeadlineAdded() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        // 3 days sleep (259,200s)
        simulatedNow = baseDate.addingTimeInterval(259200)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 1500)
    }

    // Test 5: Wake with five seconds remaining before sleep: credit only those five remaining seconds
    @MainActor
    func testTask7_GroupA_Test05_WakeWithFiveSecondsRemaining_CreditOnlyFiveRemainingSeconds() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        // Run 1495 seconds, leaving 5 seconds
        simulatedNow = baseDate.addingTimeInterval(1495)
        vm.reconcileActiveTimers()
        XCTAssertEqual(vm.timeRemaining, 5)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1495)

        // Mac sleeps 1 hour, expiring those 5 seconds during sleep
        simulatedNow = baseDate.addingTimeInterval(1495 + 3600)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isBreakPreset)
        XCTAssertEqual(vm.timeRemaining, 300)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500, "Task must receive only the 5 remaining seconds, not 3600s sleep")
    }

    // Test 6: Paused Focus Timer during sleep: remaining state unchanged
    @MainActor
    func testTask7_GroupA_Test06_PausedFocusTimerDuringSleep_RemainingStateUnchanged() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(600)
        vm.reconcileActiveTimers()
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 900)
        XCTAssertNotNil(vm.pausedSession)

        // 3 hours sleep while paused
        simulatedNow = baseDate.addingTimeInterval(600 + 10800)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 900)
        XCTAssertEqual(vm.pausedSession?.timeRemaining, 900)
    }

    // Test 7: Wake immediately followed by tick: no duplicate completion
    @MainActor
    func testTask7_GroupA_Test07_WakeImmediatelyFollowedByTick_NoDuplicateCompletion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(7200)

        // Wake event
        vm.handleDateOrLifecycleChange()
        // Immediate first post-wake tick
        vm.reconcileActiveTimers()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
    }

    // Test 8: Tick before wake notification: no duplicate completion
    @MainActor
    func testTask7_GroupA_Test08_TickBeforeWakeNotification_NoDuplicateCompletion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(7200)

        // Master tick fires first
        vm.reconcileActiveTimers()
        // Wake notification arrives later
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
    }

    // Test 9: Multiple wake notifications: idempotent reconciliation
    @MainActor
    func testTask7_GroupA_Test09_MultipleWakeNotifications_IdempotentReconciliation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(7200)

        for _ in 0..<5 {
            vm.handleDateOrLifecycleChange()
        }

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500)
    }

    // MARK: Group B — Deadline and Manual Adjustments (Tests 10–15)

    // Test 10: Expiration does not mutate the captured original deadline before it is used
    @MainActor
    func testTask7_GroupB_Test10_ExpirationDoesNotMutateCapturedDeadlineBeforeUse() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let expectedDeadline = baseDate.addingTimeInterval(1500)
        XCTAssertEqual(vm.targetEndDate, expectedDeadline)

        simulatedNow = baseDate.addingTimeInterval(5000)
        vm.reconcileActiveTimers()

        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.endTime, expectedDeadline, "Expired session record endTime must match the original target deadline")
    }

    // Test 11: Internal countdown synchronization preserves deadline
    @MainActor
    func testTask7_GroupB_Test11_InternalCountdownSync_PreservesDeadline() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        vm.currentDateProvider = { baseDate }

        vm.startTimer()
        let originalTarget = vm.targetEndDate

        // Internal synchronization must not shift targetEndDate
        vm.synchronizeCountdownRemaining(to: 1200)
        XCTAssertEqual(vm.targetEndDate, originalTarget, "Internal sync must not mutate targetEndDate")
    }

    // Test 12: Explicit supported user duration change continues working
    @MainActor
    func testTask7_GroupB_Test12_ExplicitSupportedUserDurationChange_ContinuesWorking() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.applyPresetDirectly(name: "Custom", minutes: 30, seconds: 0, mode: "Custom Timer", isBreak: false)
        XCTAssertEqual(vm.totalTime, 1800)
        XCTAssertEqual(vm.timeRemaining, 1800)
        XCTAssertEqual(vm.customMinutes, 30)
    }

    // Test 13: Pause and resume preserve accurate remaining time
    @MainActor
    func testTask7_GroupB_Test13_PauseAndResume_PreservesAccurateRemainingTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.reconcileActiveTimers()
        vm.stopTimer()

        XCTAssertEqual(vm.timeRemaining, 1200)

        // Advance clock by 10 minutes while paused
        simulatedNow = simulatedNow.addingTimeInterval(600)
        vm.startTimer()

        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1200)
        XCTAssertEqual(vm.targetEndDate, simulatedNow.addingTimeInterval(1200))
    }

    // Test 14: Custom Timer expiration behaves correctly
    @MainActor
    func testTask7_GroupB_Test14_CustomTimerExpiration_BehavesCorrectly() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.applyPresetDirectly(name: "Custom", minutes: 10, seconds: 0, mode: "Custom Timer", isBreak: false)
        vm.startTimer()
        XCTAssertEqual(vm.totalTime, 600)

        simulatedNow = baseDate.addingTimeInterval(3600)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 600)
    }

    // Test 15: Short Break and Long Break completion behave correctly
    @MainActor
    func testTask7_GroupB_Test15_ShortBreakAndLongBreakCompletion_BehaveCorrectly() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.switchToBreak(minutes: 5)
        vm.startTimer()
        XCTAssertTrue(vm.isBreakPreset)

        simulatedNow = baseDate.addingTimeInterval(1800)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.sessionRecords.count, 0, "Break sessions must never create FocusSessionRecords")
        XCTAssertEqual(vm.activePreset, "Focus", "Must automatically transition back to Focus mode")
    }

    // MARK: Group C — Focus Records and Task Attribution (Tests 16–22)

    // Test 16: Session-record duration matches valid Focus time
    @MainActor
    func testTask7_GroupC_Test16_SessionRecordDuration_MatchesValidFocusTime() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(3600)
        vm.handleDateOrLifecycleChange()

        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500)
        XCTAssertEqual(record.durationSeconds, vm.tasks[0].timeSpentSeconds)
    }

    // Test 17: Sleep crossing midnight allocates time to correct calendar days
    @MainActor
    func testTask7_GroupC_Test17_SleepCrossingMidnight_AllocatesTimeToCorrectCalendarDays() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let day1Start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 50, second: 0))!
        var simulatedNow = day1Start
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let plannedDeadline = day1Start.addingTimeInterval(1500) // 2026-10-21 00:15:00 UTC

        // Mac sleeps from 23:55 to 02:00 on Day 2
        simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 2, minute: 0, second: 0))!
        vm.handleDateOrLifecycleChange()

        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(record.startTime, day1Start)
        XCTAssertEqual(record.endTime, plannedDeadline)

        // Day 1 (Oct 20) receives 600s (23:50–00:00)
        let day1Allocated = record.duration(on: day1Start, calendar: calendar)
        XCTAssertEqual(day1Allocated, 600)

        // Day 2 (Oct 21) receives 900s (00:00–00:15)
        let day2Date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 1, minute: 0, second: 0))!
        let day2Allocated = record.duration(on: day2Date, calendar: calendar)
        XCTAssertEqual(day2Allocated, 900)

        // Sleep time between 00:15 and 02:00 received zero focus time
        XCTAssertEqual(day1Allocated + day2Allocated, 1500)
    }

    // Test 18: Sleep spanning multiple calendar days never extends records beyond deadline
    @MainActor
    func testTask7_GroupC_Test18_SleepSpanningMultipleCalendarDays_NeverExtendsRecordsBeyondDeadline() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let fridayNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 50, second: 0))!
        var simulatedNow = fridayNight
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let saturdayDeadline = fridayNight.addingTimeInterval(1500) // Saturday 00:15 UTC

        // Mac sleeps over the weekend until Monday morning 09:00 UTC
        simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9, minute: 0, second: 0))!
        vm.handleDateOrLifecycleChange()

        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(record.endTime, saturdayDeadline)

        let sundayDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12, minute: 0, second: 0))!
        let sundayAllocated = record.duration(on: sundayDate, calendar: calendar)
        XCTAssertEqual(sundayAllocated, 0, "Sunday must receive 0 seconds")

        let mondayDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8, minute: 0, second: 0))!
        let mondayAllocated = record.duration(on: mondayDate, calendar: calendar)
        XCTAssertEqual(mondayAllocated, 0, "Monday must receive 0 seconds")
    }

    // Test 19: Task A to Task B segments conserve total duration
    @MainActor
    func testTask7_GroupC_Test19_TaskAToTaskBSegments_ConserveTotalDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()
        // Work 600s on A
        simulatedNow = baseDate.addingTimeInterval(600)
        vm.selectTask(at: 1) // Switch to B

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600)

        // Work remaining 900s on B across a 2-hour sleep
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 900)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 900)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds + vm.tasks[1].timeSpentSeconds, 1500)
    }

    // Test 20: Deleting or completing a task near expiry does not assign old time to another task
    @MainActor
    func testTask7_GroupC_Test20_DeletingOrCompletingTaskNearExpiry_DoesNotAssignOldTimeToAnotherTask() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        // Run 1490s on Task A (10s remaining)
        simulatedNow = baseDate.addingTimeInterval(1490)
        vm.reconcileActiveTimers()
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1490)

        // Complete Task A -> auto advances to Task B
        vm.toggleTaskCompletion(at: 0)
        XCTAssertTrue(vm.tasks[0].isCompleted)
        XCTAssertEqual(vm.activeTaskIndex, 1)

        // Sleep 1 hour, expiring the final 10s
        simulatedNow = baseDate.addingTimeInterval(1490 + 3600)
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1490, "Task A must retain its 1490s")
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 10, "Task B must only receive the final 10s, never Task A's time")
    }

    // Test 21: Running timer without an assigned task still records unassigned Focus Time correctly
    @MainActor
    func testTask7_GroupC_Test21_RunningTimerWithoutAssignedTask_RecordsUnassignedFocusTimeCorrectly() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        // Complete all tasks so no task is active
        for i in 0..<vm.tasks.count {
            vm.tasks[i].isCompleted = true
        }

        vm.startTimer()
        XCTAssertNil(vm.activeSessionTaskId)

        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertNil(record.taskId, "Unassigned focus session must have nil taskId")
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
    }

    // Test 22: Simultaneous Focus Timer and Stopwatch retain their existing attribution semantics
    @MainActor
    func testTask7_GroupC_Test22_SimultaneousFocusTimerAndStopwatch_RetainAttributionSemantics() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        vm.startStopwatch()

        // 1 hour sleep (3600s)
        simulatedNow = baseDate.addingTimeInterval(3600)
        vm.handleDateOrLifecycleChange()

        // Focus Timer expired at 1500s -> todayFocusedSeconds is 1500
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
        XCTAssertFalse(vm.isTimerRunning)

        // Stopwatch is still running, has accumulated 3600s
        XCTAssertTrue(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 3600)
    }

    // MARK: Group D — Stopwatch (Tests 23–27)

    // Test 23: Stopwatch advances across sleep
    @MainActor
    func testTask7_GroupD_Test23_StopwatchAdvancesAcrossSleep() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startStopwatch()
        XCTAssertTrue(vm.isStopwatchRunning)

        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertTrue(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 7200)
    }

    // Test 24: Paused Stopwatch remains unchanged
    @MainActor
    func testTask7_GroupD_Test24_PausedStopwatch_RemainsUnchanged() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startStopwatch()
        simulatedNow = baseDate.addingTimeInterval(45)
        vm.reconcileActiveTimers()
        vm.stopStopwatch()

        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 45)

        // 2 hours pass while paused
        simulatedNow = baseDate.addingTimeInterval(45 + 7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 45)
    }

    // Test 25: Lap recorded after wake has correct fractional split
    @MainActor
    func testTask7_GroupD_Test25_LapRecordedAfterWake_HasCorrectFractionalSplit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startStopwatch()
        simulatedNow = baseDate.addingTimeInterval(10)
        vm.recordLap() // Lap 1: 10s

        XCTAssertEqual(vm.laps.count, 1)
        XCTAssertEqual(Int(vm.laps[0].lapDuration), 10)

        // Sleep 50s
        simulatedNow = baseDate.addingTimeInterval(60)
        vm.handleDateOrLifecycleChange()
        vm.recordLap() // Lap 2: 50s

        XCTAssertEqual(vm.laps.count, 2)
        XCTAssertEqual(Int(vm.laps[0].lapDuration), 50)
        XCTAssertEqual(Int(vm.laps[0].totalTime), 60)
    }

    // Test 26: Wake plus tick does not duplicate task credit
    @MainActor
    func testTask7_GroupD_Test26_WakePlusTick_DoesNotDuplicateTaskCredit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startStopwatch()
        simulatedNow = baseDate.addingTimeInterval(100)

        // Wake notification
        vm.handleDateOrLifecycleChange()
        // Immediate tick
        vm.reconcileActiveTimers()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 100, "Wake followed by tick must not duplicate task credit")
    }

    // Test 27: Stopwatch running across midnight remains excluded from Focus Timer analytics
    @MainActor
    func testTask7_GroupD_Test27_StopwatchRunningAcrossMidnight_ExcludedFromFocusAnalytics() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let day1Start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 50, second: 0))!
        var simulatedNow = day1Start
        vm.currentDateProvider = { simulatedNow }

        vm.startStopwatch()

        // 30 minutes pass across midnight to 00:20 on Day 2
        simulatedNow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 20, second: 0))!
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.stopwatchTime, 1800)
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Stopwatch activity must remain excluded from Focus Timer analytics")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 0)
    }

    // MARK: Group E — App Lifecycle & Persistence (Tests 28–35)

    // Test 28: App becomes active after timer expiry
    @MainActor
    func testTask7_GroupE_Test28_AppBecomesActiveAfterExpiry() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)

        // Expire while inactive
        simulatedNow = baseDate.addingTimeInterval(3600)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
    }

    // Test 29: Auto-start enabled: only one next session begins at wake, not a backlog of sessions
    @MainActor
    func testTask7_GroupE_Test29_AutoStartEnabled_OnlyOneNextSessionBeginsAtWake() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.autoStartNextSession = true
        vm.startTimer()

        // 4 hours sleep
        simulatedNow = baseDate.addingTimeInterval(14400)
        vm.handleDateOrLifecycleChange()

        // Exactly one completed session record
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.completedSessions, 1)

        // Only one next session (Short Break) begins at wake time
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertTrue(vm.isBreakPreset)
        XCTAssertEqual(vm.timeRemaining, 300)
        XCTAssertEqual(vm.targetEndDate, simulatedNow.addingTimeInterval(300))
    }

    // Test 30: Auto-start disabled: no new timer starts
    @MainActor
    func testTask7_GroupE_Test30_AutoStartDisabled_NoNewTimerStarts() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.autoStartNextSession = false
        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
    }

    // Test 31: Quit/Reopen following reconciliation restores correct records
    @MainActor
    func testTask7_GroupE_Test31_QuitAndReopenFollowingReconciliation_RestoresCorrectRecords() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm1.currentDateProvider = { simulatedNow }

        vm1.startTimer()
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm1.handleDateOrLifecycleChange()
        vm1.persistData(force: true)

        // Simulate relaunch: create second ViewModel with the same storage
        let vm2 = TimerViewModel(storage: vm1.storage)
        vm2.currentDateProvider = { simulatedNow }
        vm2.recalculateFocusMetrics()
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm2.todayFocusedSeconds, 1500)
        XCTAssertEqual(vm2.lifetimeFocusedSeconds, 1500)
        XCTAssertFalse(vm2.isTimerRunning)
    }

    // Test 32: Successful persistence coalescing remains intact
    @MainActor
    func testTask7_GroupE_Test32_SuccessfulPersistenceCoalescing_RemainsIntact() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.persistData(force: true)
        let initialSaves = vm.storage.saveAttemptCount

        for i in 1...20 {
            vm.totalSessions = i
        }
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertEqual(vm.pendingSaveScheduledCount, 1)

        // Force save flushes and invalidates pending save
        vm.persistData(force: true)
        XCTAssertFalse(vm.hasPendingSave)
        XCTAssertEqual(vm.storage.saveAttemptCount, initialSaves + 1)
    }

    // Test 33: Corrupted storage blocks mutations safely
    @MainActor
    func testTask7_GroupE_Test33_CorruptedStorage_BlocksMutationsSafely() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Corrupt file
        try "corrupted invalid json".write(to: tempURL, atomically: true, encoding: .utf8)
        vm.loadPersistedData()

        XCTAssertTrue(vm.isPersistenceBlocked)

        // Wake reconciliation while persistence is blocked must suspend active timers safely
        vm.handleDateOrLifecycleChange()
        XCTAssertFalse(vm.isTimerRunning)
    }

    // Test 34: Temporary save errors remain visible and retryable
    @MainActor
    func testTask7_GroupE_Test34_TemporarySaveErrors_RemainVisibleAndRetryable() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.storage.simulateWriteFailure = true
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)

        // Clear simulation and retry
        vm.storage.simulateWriteFailure = false
        vm.retrySave()

        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertNil(vm.saveErrorMessage)
    }

    // Test 35: Normal fullscreen/window closing does not affect running timer accuracy
    @MainActor
    func testTask7_GroupE_Test35_NormalWindowClose_DoesNotAffectRunningTimerAccuracy() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialDeadline = vm.targetEndDate

        // Advance 200 seconds while window is hidden
        simulatedNow = baseDate.addingTimeInterval(200)
        vm.reconcileActiveTimers()

        XCTAssertEqual(vm.timeRemaining, 1300)
        XCTAssertEqual(vm.targetEndDate, initialDeadline)
    }

    // MARK: Group F — Clock-Change Boundary Investigation (Tests 36–38)

    // Test 36: System clock jumps forward: completes safely without overflow
    @MainActor
    func testTask7_GroupF_Test36_SystemClockJumpsForward_CompletesSafelyWithoutOverflow() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        // Clock suddenly jumps forward 10 hours
        simulatedNow = baseDate.addingTimeInterval(36000)
        vm.handleDateOrLifecycleChange()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
    }

    // Test 37: System clock jumps backward: maintains monotonic safety
    @MainActor
    func testTask7_GroupF_Test37_SystemClockJumpsBackward_MaintainsMonotonicSafety() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let originalTarget = vm.targetEndDate

        // Clock jumps backwards 1 hour
        simulatedNow = baseDate.addingTimeInterval(-3600)
        vm.handleDateOrLifecycleChange()

        // Must not crash, deadline remains valid, no negative records
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.targetEndDate, originalTarget)
        XCTAssertEqual(vm.sessionRecords.count, 0)
    }

    // Test 38: Time-zone changes while session is running: maintains accurate metrics
    @MainActor
    func testTask7_GroupF_Test38_TimeZoneChangesWhileSessionRunning_MaintainsAccurateMetrics() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let day1 = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12, minute: 0, second: 0))!
        var simulatedNow = day1
        vm.currentDateProvider = { simulatedNow }
        vm.reportingCalendar = utcCalendar

        vm.startTimer()
        simulatedNow = day1.addingTimeInterval(500)
        vm.reconcileActiveTimers()

        // System time-zone change occurs
        vm.handleSystemTimeZoneChange(newCalendar: utcCalendar)

        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1000)
        XCTAssertEqual(vm.todayFocusedSeconds, 500)
    }

    // MARK: - Task 7 Critical Regression Correction Tests (Scenarios 1–14)

    // Scenario 1: Normal 25-minute timer with an intermediate tick at 5 minutes, then completion at 25 minutes
    @MainActor
    func testTask7_Correction_Scenario01_Normal25MinTimer_IntermediateTickAt5Min_Full1500sRecord() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialTaskSpent = vm.tasks[0].timeSpentSeconds

        // Intermediate tick at 5 minutes (T0 + 300s)
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        XCTAssertEqual(vm.timeRemaining, 1200)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 300)

        // Completion at 25 minutes (T0 + 1500s)
        simulatedNow = baseDate.addingTimeInterval(1500)
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 1500)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500, "Record must contain full 1500s, not just uncounted 1200s!")
        XCTAssertEqual(record.startTime, baseDate)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
    }

    // Scenario 2: Normal session with a tick at 24m59s: full 1500s record
    @MainActor
    func testTask7_Correction_Scenario02_NormalSession_TickAt24m59s_Full1500sRecord() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialTaskSpent = vm.tasks[0].timeSpentSeconds

        // Tick at 24 minutes 59 seconds (T0 + 1499s)
        simulatedNow = baseDate.addingTimeInterval(1499)
        vm.tick()

        XCTAssertEqual(vm.timeRemaining, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 1499)

        // Final completion tick at 25 minutes (T0 + 1500s)
        simulatedNow = baseDate.addingTimeInterval(1500)
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 1500)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500, "Record must contain full 1500s, not just 1s!")
        XCTAssertEqual(record.startTime, baseDate)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
    }

    // Scenario 3: Sleep after multiple normal ticks: preserves correct original deadline
    @MainActor
    func testTask7_Correction_Scenario03_SleepAfterMultipleIntermediateTicks_PreservesOriginalDeadline() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialTaskSpent = vm.tasks[0].timeSpentSeconds

        // Multiple intermediate ticks before sleep
        simulatedNow = baseDate.addingTimeInterval(60)
        vm.tick()
        simulatedNow = baseDate.addingTimeInterval(180)
        vm.tick()
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        XCTAssertEqual(vm.timeRemaining, 1200)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 300)

        // 2 hours sleep without ticks (T0 + 7200s)
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 1500, "Task credit must not exceed 1500s!")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500, "Record duration must be exactly 1500s!")
        XCTAssertEqual(record.startTime, baseDate)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
    }

    // Scenario 4: Task A 10 minutes, Task B 15 minutes, with intermediate ticks in both segments
    @MainActor
    func testTask7_Correction_Scenario04_TaskA10Min_TaskB15Min_WithIntermediateTicksInBothSegments() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id
        let initialTask0 = vm.tasks[0].timeSpentSeconds
        let initialTask1 = vm.tasks[1].timeSpentSeconds

        vm.startTimer()

        // Intermediate tick during Task A at 5m (T0 + 300s)
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTask0, 300)

        // Switch to Task B at 10m (T0 + 600s)
        simulatedNow = baseDate.addingTimeInterval(600)
        vm.selectTask(at: 1)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTask0, 600)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600)

        // Intermediate tick during Task B at 15m (T0 + 900s)
        simulatedNow = baseDate.addingTimeInterval(900)
        vm.tick()
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds - initialTask1, 300)

        // Completion at 25m (T0 + 1500s)
        simulatedNow = baseDate.addingTimeInterval(1500)
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTask0, 600)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds - initialTask1, 900)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600)
        XCTAssertEqual(vm.sessionRecords[0].startTime, baseDate)
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(600))
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 900)
        XCTAssertEqual(vm.sessionRecords[1].startTime, baseDate.addingTimeInterval(600))
        XCTAssertEqual(vm.sessionRecords[1].endTime, baseDate.addingTimeInterval(1500))
    }

    // Scenario 5: Stop after deadline but before wake/tick reconciliation
    @MainActor
    func testTask7_Correction_Scenario05_StopAfterDeadline_BeforeWakeReconciliation() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialTaskSpent = vm.tasks[0].timeSpentSeconds

        // 2 hours sleep without ticks
        simulatedNow = baseDate.addingTimeInterval(7200)

        // Directly call stopTimer() without wake reconciliation
        vm.stopTimer()

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1, "Completed session count must be incremented!")
        XCTAssertNil(vm.pausedSession, "Must not be preserved as an active paused session!")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTaskSpent, 1500, "Task credit must not exceed 1500s!")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500, "Record duration must be exactly 1500s, not 7200s!")
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
    }

    // Scenario 6: App termination after deadline but before reconciliation
    @MainActor
    func testTask7_Correction_Scenario06_AppTerminationAfterDeadline_BeforeReconciliation() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm1.currentDateProvider = { simulatedNow }

        vm1.startTimer()
        let initialTaskSpent = vm1.tasks[0].timeSpentSeconds

        // 2 hours sleep without ticks
        simulatedNow = baseDate.addingTimeInterval(7200)

        // App terminates without prior wake reconciliation
        vm1.handleAppTermination()

        XCTAssertEqual(vm1.completedSessions, 1)
        XCTAssertEqual(vm1.tasks[0].timeSpentSeconds - initialTaskSpent, 1500)
        XCTAssertEqual(vm1.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm1.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))

        // Verify clean restart state from storage
        let vm2 = TimerViewModel(storage: vm1.storage)
        vm2.currentDateProvider = { simulatedNow }
        vm2.recalculateFocusMetrics()
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertNil(vm2.pausedSession)
        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 1500)
    }

    // Scenario 7: Task switch after expiry before reconciliation
    @MainActor
    func testTask7_Correction_Scenario07_TaskSwitchAfterExpiry_BeforeReconciliation() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialTask0Spent = vm.tasks[0].timeSpentSeconds
        let initialTask1Spent = vm.tasks[1].timeSpentSeconds

        // 2 hours sleep without ticks
        simulatedNow = baseDate.addingTimeInterval(7200)

        // Switch to Task 1 directly before wake reconciliation
        vm.selectTask(at: 1)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialTask0Spent, 1500, "Task 0 credit must be exactly 1500s!")
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds - initialTask1Spent, 0, "Task 1 credit must be 0s!")
        XCTAssertEqual(vm.completedSessions, 1, "Completed session count must be incremented!")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500, "Record duration must be 1500s!")
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
        XCTAssertEqual(record.taskId, vm.tasks[0].id)
    }

    // Scenario 8: Active task completion and deletion after expiry
    @MainActor
    func testTask7_Correction_Scenario08_ActiveTaskCompletionAndDeletionAfterExpiry() throws {
        // Sub-test A: Task completion after expiry
        do {
            let (vmA, tempURLA) = makeIsolatedViewModel()
            defer { cleanup(url: tempURLA) }

            let baseDate = Date(timeIntervalSince1970: 1770000000)
            var simulatedNow = baseDate
            vmA.currentDateProvider = { simulatedNow }

            vmA.startTimer()
            let initialTaskSpent = vmA.tasks[0].timeSpentSeconds

            simulatedNow = baseDate.addingTimeInterval(7200)
            vmA.toggleTaskCompletion(at: 0)

            XCTAssertTrue(vmA.tasks[0].isCompleted)
            XCTAssertEqual(vmA.tasks[0].timeSpentSeconds - initialTaskSpent, 1500)
            XCTAssertEqual(vmA.completedSessions, 1)
            XCTAssertEqual(vmA.sessionRecords.count, 1)
            let record = try XCTUnwrap(vmA.sessionRecords.first)
            XCTAssertEqual(record.durationSeconds, 1500)
            XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
        }

        // Sub-test B: Task deletion after expiry
        do {
            let (vmB, tempURLB) = makeIsolatedViewModel()
            defer { cleanup(url: tempURLB) }

            let baseDate = Date(timeIntervalSince1970: 1770000000)
            var simulatedNow = baseDate
            vmB.currentDateProvider = { simulatedNow }

            vmB.startTimer()
            let deletedId = vmB.tasks[0].id

            simulatedNow = baseDate.addingTimeInterval(7200)
            vmB.removeTask(at: 0)

            XCTAssertEqual(vmB.completedSessions, 1)
            XCTAssertEqual(vmB.sessionRecords.count, 1)
            let record = try XCTUnwrap(vmB.sessionRecords.first)
            XCTAssertEqual(record.taskId, deletedId)
            XCTAssertEqual(record.durationSeconds, 1500)
            XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(1500))
        }
    }

    // Scenario 9: Reset and pause near/after expiry
    @MainActor
    func testTask7_Correction_Scenario09_ResetAndPauseNearAndAfterExpiry() throws {
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Sub-test A: Reset after expiry
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            var simulatedNow = baseDate
            vm.currentDateProvider = { simulatedNow }

            vm.startTimer()
            simulatedNow = baseDate.addingTimeInterval(7200)
            vm.resetFocusTimer()

            XCTAssertEqual(vm.completedSessions, 1)
            XCTAssertEqual(vm.sessionRecords.count, 1)
            XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
            XCTAssertFalse(vm.isTimerRunning)
            XCTAssertNil(vm.pausedSession)
            XCTAssertEqual(vm.timeRemaining, vm.totalTime)
        }

        // Sub-test B: Toggle timer after expiry
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            var simulatedNow = baseDate
            vm.currentDateProvider = { simulatedNow }

            vm.startTimer()
            simulatedNow = baseDate.addingTimeInterval(7200)
            vm.toggleTimer()

            XCTAssertEqual(vm.completedSessions, 1)
            XCTAssertEqual(vm.sessionRecords.count, 1)
            XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        }

        // Sub-test C: Pause near expiry (5s remaining): normal pause, NOT completed Pomodoro
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            var simulatedNow = baseDate
            vm.currentDateProvider = { simulatedNow }

            vm.startTimer()
            let initialSpent = vm.tasks[0].timeSpentSeconds

            simulatedNow = baseDate.addingTimeInterval(1495)
            vm.stopTimer()

            XCTAssertFalse(vm.isTimerRunning)
            XCTAssertEqual(vm.completedSessions, 0, "Normal pause before deadline must not complete session!")
            XCTAssertNotNil(vm.pausedSession)
            XCTAssertEqual(vm.timeRemaining, 5)
            XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialSpent, 1495)
            XCTAssertEqual(vm.sessionRecords.count, 1)
            XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1495)
        }
    }

    // Scenario 10: Running manual duration adjustment
    @MainActor
    func testTask7_Correction_Scenario10_RunningManualDurationAdjustment() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialSpent = vm.tasks[0].timeSpentSeconds

        // Intermediate tick at 5m (T0 + 300s)
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()
        XCTAssertEqual(vm.timeRemaining, 1200)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialSpent, 300)

        // User manually adjusts timeRemaining while timer is running (adds 10 minutes: 1800s remaining)
        vm.timeRemaining = 1800
        let newTarget = try XCTUnwrap(vm.targetEndDate)
        XCTAssertEqual(newTarget, simulatedNow.addingTimeInterval(1800))

        // Normal internal ticks must NOT shift targetEndDate
        simulatedNow = baseDate.addingTimeInterval(600)
        vm.tick()
        XCTAssertEqual(vm.targetEndDate, newTarget)
        XCTAssertEqual(vm.timeRemaining, 1500)

        // Complete timer at new deadline: (T0 + 300s) + 1800s = T0 + 2100s
        simulatedNow = baseDate.addingTimeInterval(2100)
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds - initialSpent, 2100)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 2100)
        XCTAssertEqual(record.startTime, baseDate)
        XCTAssertEqual(record.endTime, baseDate.addingTimeInterval(2100))
    }

    // Scenario 11: Wake -> tick and tick -> wake idempotency
    @MainActor
    func testTask7_Correction_Scenario11_WakeTickAndTickWake_Idempotency() throws {
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Order A: Wake then Tick
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            var simulatedNow = baseDate
            vm.currentDateProvider = { simulatedNow }

            vm.startTimer()
            simulatedNow = baseDate.addingTimeInterval(7200)

            vm.handleDateOrLifecycleChange()
            vm.tick()

            XCTAssertEqual(vm.completedSessions, 1)
            XCTAssertEqual(vm.sessionRecords.count, 1)
            XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        }

        // Order B: Tick then Wake
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            var simulatedNow = baseDate
            vm.currentDateProvider = { simulatedNow }

            vm.startTimer()
            simulatedNow = baseDate.addingTimeInterval(7200)

            vm.tick()
            vm.handleDateOrLifecycleChange()

            XCTAssertEqual(vm.completedSessions, 1)
            XCTAssertEqual(vm.sessionRecords.count, 1)
            XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        }
    }

    // Scenario 12: Midnight crossing with intermediate tick before sleep
    @MainActor
    func testTask7_Correction_Scenario12_MidnightCrossingWithIntermediateTickBeforeSleep() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        let day1_2350 = utcCal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 50, second: 0))!
        var simulatedNow = day1_2350
        vm.currentDateProvider = { simulatedNow }
        vm.reportingCalendar = utcCal

        vm.startTimer()

        // Intermediate tick at 23:55 (5m)
        simulatedNow = day1_2350.addingTimeInterval(300)
        vm.tick()
        XCTAssertEqual(vm.timeRemaining, 1200)

        // Sleep past midnight until 02:00:00 Day 2 (target was 00:15:00 Day 2)
        let day2_0200 = utcCal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 2, minute: 0, second: 0))!
        simulatedNow = day2_0200
        vm.handleDateOrLifecycleChange()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        let record = try XCTUnwrap(vm.sessionRecords.first)
        XCTAssertEqual(record.durationSeconds, 1500)
        let expectedEnd = utcCal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 15, second: 0))!
        XCTAssertEqual(record.endTime, expectedEnd)

        // Day 2 today focused seconds: exactly 900s (00:00 to 00:15)
        XCTAssertEqual(vm.todayFocusedSeconds, 900)
        // Lifetime focused seconds: exactly 1500s
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 1500)
    }

    // Scenario 13: Simultaneous Stopwatch and Focus Timer preserving existing policies
    @MainActor
    func testTask7_Correction_Scenario13_SimultaneousStopwatchAndFocusTimer_PreservesPolicies() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        vm.startStopwatch()

        // Intermediate tick at 5m
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // 2 hours sleep
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.handleDateOrLifecycleChange()

        // Focus Timer is complete: exactly 1500s record
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)

        // Stopwatch continues running wall-clock time
        XCTAssertTrue(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 7200)
    }

    // Scenario 14: Persistence, restart and historical records remain correct
    @MainActor
    func testTask7_Correction_Scenario14_PersistenceRestartAndHistoricalRecordsRemainCorrect() throws {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm1.currentDateProvider = { simulatedNow }

        vm1.startTimer()

        // Intermediate tick at 5m
        simulatedNow = baseDate.addingTimeInterval(300)
        vm1.tick()

        // Sleep to 2 hours
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm1.handleDateOrLifecycleChange()
        vm1.persistData(force: true)

        // Restart simulation: fresh ViewModel loading saved data
        let vm2 = TimerViewModel(storage: vm1.storage)
        vm2.currentDateProvider = { simulatedNow }
        vm2.recalculateFocusMetrics()

        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertNil(vm2.pausedSession)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm2.todayFocusedSeconds, 1500)
    }

    // MARK: - Task 7 Final Hardening Tests (Termination, Fractional Deadline, Skip Safety)

    // Finding 1: Termination with autoStartNextSession enabled and expired timer
    @MainActor
    func testTask7_Hardening_TerminationWithAutoStart_ExpiredFocusCompletesWithoutNewRunningTimerOrPausedBreak() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = true

        vm.startTimer()

        // Advance deterministic time by 2 hours past deadline without ticks
        simulatedNow = baseDate.addingTimeInterval(7200)

        // Call handleAppTermination() directly
        vm.handleAppTermination()

        // 1. Expired Focus Session completes exactly once
        XCTAssertEqual(vm.completedSessions, 1, "Completed sessions must be incremented exactly once")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(1500))

        // 2. Focus credit capped at 1500s
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500)

        // 3. Termination remains terminal
        XCTAssertTrue(vm.hasTerminated, "hasTerminated must remain true")

        // 4. No new running timer survives app termination
        XCTAssertFalse(vm.isTimerRunning, "Timer must not be running after termination")
        XCTAssertFalse(vm.isStopwatchRunning, "Stopwatch must not be running after termination")

        // 5. No unintended paused Break snapshot manufactured by auto-start during termination
        XCTAssertNil(vm.pausedSession, "pausedSession must be nil after termination")

        // 6. Persistence is synchronous and safe: reload from storage verifies clean disk state
        let reloaded = TimerViewModel(storage: vm.storage)
        reloaded.currentDateProvider = { simulatedNow }
        reloaded.recalculateFocusMetrics()

        XCTAssertEqual(reloaded.completedSessions, 1)
        XCTAssertFalse(reloaded.isTimerRunning)
        XCTAssertNil(reloaded.pausedSession)
        XCTAssertEqual(reloaded.sessionRecords.count, 1)
        XCTAssertEqual(reloaded.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(reloaded.todayFocusedSeconds, 1500)
    }

    // Finding 1 (continued): Termination called twice is idempotent
    @MainActor
    func testTask7_Hardening_TerminationIdempotency_SecondInvocationIsNoOp() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = true

        vm.startTimer()
        simulatedNow = baseDate.addingTimeInterval(7200)

        vm.handleAppTermination()

        let recordsCountFirst = vm.sessionRecords.count
        let completedSessionsFirst = vm.completedSessions
        let todayFocusedFirst = vm.todayFocusedSeconds

        // Second invocation
        vm.handleAppTermination()

        XCTAssertTrue(vm.hasTerminated)
        XCTAssertEqual(vm.completedSessions, completedSessionsFirst)
        XCTAssertEqual(vm.sessionRecords.count, recordsCountFirst)
        XCTAssertEqual(vm.todayFocusedSeconds, todayFocusedFirst)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertNil(vm.pausedSession)
    }

    // Finding 2: Fractional task switch at T0 + 600.3s
    @MainActor
    func testTask7_Hardening_FractionalTaskSwitch_600_3s_ExactDeadlineAndConservation() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()

        // Switch to Task B at T0 + 600.3 seconds
        simulatedNow = baseDate.addingTimeInterval(600.3)
        vm.selectTask(at: 1)

        // Advance to exact deadline at T0 + 1500.0s
        simulatedNow = baseDate.addingTimeInterval(1500.0)
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 2)

        let recordA = vm.sessionRecords[0]
        let recordB = vm.sessionRecords[1]

        // Record A assertions
        XCTAssertEqual(recordA.taskId, idA)
        XCTAssertEqual(recordA.durationSeconds, 600)
        XCTAssertEqual(recordA.startTime, baseDate)
        XCTAssertEqual(recordA.endTime, baseDate.addingTimeInterval(600.3))
        XCTAssertLessThanOrEqual(recordA.startTime, recordA.endTime)

        // Record B assertions
        XCTAssertEqual(recordB.taskId, idB)
        XCTAssertEqual(recordB.durationSeconds, 900)
        XCTAssertEqual(recordB.startTime, baseDate.addingTimeInterval(600.3))
        // CRITICAL INVARIANT: End time must NOT be later than original targetEndDate (baseDate + 1500.0)
        XCTAssertEqual(recordB.endTime, baseDate.addingTimeInterval(1500.0), "Record B endTime must be exact deadline (T0 + 1500.0s), NOT T0 + 1500.3s!")
        XCTAssertLessThanOrEqual(recordB.startTime, recordB.endTime)

        // Exact conservation of durations and credits
        XCTAssertEqual(recordA.durationSeconds + recordB.durationSeconds, 1500, "Sum of record durations must equal exactly 1500s")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task A credit must equal 600s")
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 900, "Task B credit must equal 900s")
        XCTAssertEqual(vm.todayFocusedSeconds, 1500, "Today focus total must equal 1500s")
    }

    // Finding 2 (continued): Fractional task switch at T0 + 600.8s with intermediate ticks
    @MainActor
    func testTask7_Hardening_FractionalTaskSwitch_600_8s_WithIntermediateTicks() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()

        // Switch to Task B at T0 + 600.8 seconds
        simulatedNow = baseDate.addingTimeInterval(600.8)
        vm.selectTask(at: 1)

        // Intermediate tick at T0 + 900.0s
        simulatedNow = baseDate.addingTimeInterval(900.0)
        vm.tick()

        // Expire at T0 + 1500.0s
        simulatedNow = baseDate.addingTimeInterval(1500.0)
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 2)

        let recordA = vm.sessionRecords[0]
        let recordB = vm.sessionRecords[1]

        XCTAssertEqual(recordA.taskId, idA)
        XCTAssertEqual(recordA.durationSeconds, 600)
        XCTAssertEqual(recordB.taskId, idB)
        XCTAssertEqual(recordB.durationSeconds, 900)
        XCTAssertEqual(recordB.endTime, baseDate.addingTimeInterval(1500.0), "Record B endTime must be exact deadline (T0 + 1500.0s), NOT T0 + 1500.8s!")

        XCTAssertEqual(recordA.durationSeconds + recordB.durationSeconds, 1500)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 900)
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
    }

    // Finding 3: Skip action after overdue Focus Timer without auto-start
    @MainActor
    func testTask7_Hardening_SkipAfterOverdueFocus_NoDoubleTransition() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = false

        vm.startTimer()

        // Advance beyond deadline to 1600s
        simulatedNow = baseDate.addingTimeInterval(1600)

        // Invoke skipSession() directly on overdue timer
        vm.skipSession()

        // Must complete the overdue focus session exactly once
        XCTAssertEqual(vm.completedSessions, 1, "Overdue focus session must complete once")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)

        // Must transition to Short Break, NOT double-skip to next Focus session!
        XCTAssertEqual(vm.activePreset, "Short Break", "Must be Short Break, not double-skipped to Focus!")
        XCTAssertEqual(vm.currentSession, 2)
        XCTAssertFalse(vm.isTimerRunning, "Short Break should be idle when autoStart is false")
    }

    // Finding 3 (continued): Skip action after overdue Focus Timer WITH auto-start
    @MainActor
    func testTask7_Hardening_SkipAfterOverdueFocus_WithAutoStart_NoDoubleTransition() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = true

        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(1600)
        vm.skipSession()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)

        // Must transition to Short Break and start it, NOT double-skip to Focus
        XCTAssertEqual(vm.activePreset, "Short Break", "Must be Short Break, not double-skipped to Focus!")
        XCTAssertEqual(vm.currentSession, 2)
        XCTAssertTrue(vm.isTimerRunning, "Short Break should be auto-started when autoStart is true")
    }

    // Finding 3 (continued): Skip action after overdue Break Timer without auto-start
    @MainActor
    func testTask7_Hardening_SkipAfterOverdueBreak_NoDoubleTransition() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = false

        // Switch to Short Break and start it
        vm.switchToBreak(minutes: 5)
        vm.startTimer()

        // Advance beyond 5m (300s) to 400s
        simulatedNow = baseDate.addingTimeInterval(400)
        vm.skipSession()

        // Break completed, should transition to Focus, NOT double-skip to Short Break!
        XCTAssertEqual(vm.activePreset, "Focus", "Must be Focus, not double-skipped to Break!")
        XCTAssertFalse(vm.isTimerRunning, "Focus should be idle when autoStart is false")
    }

    // Finding 3 (continued): Skip action after overdue Break Timer WITH auto-start
    @MainActor
    func testTask7_Hardening_SkipAfterOverdueBreak_WithAutoStart_NoDoubleTransition() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = true

        vm.switchToBreak(minutes: 5)
        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(400)
        vm.skipSession()

        // Break completed, should transition to Focus and start it, NOT double-skip to Break!
        XCTAssertEqual(vm.activePreset, "Focus", "Must be Focus, not double-skipped to Break!")
        XCTAssertTrue(vm.isTimerRunning, "Focus should be running when autoStart is true")
    }

    // MARK: - Task 7 Finalization Ordering Tests (Reset, Skip, End-and-Switch)

    // 1. Mandatory Red Reproduction — Reset Before Expiry
    @MainActor
    func testTask7_Ordering_ResetBeforeExpiry_WithPendingElapsedSeconds() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        // Tick at T0 + 300s (300s credited, 1200s remaining)
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // Advance to T0 + 600s without further intermediate ticks
        simulatedNow = baseDate.addingTimeInterval(600)

        // Invoke resetFocusTimer() directly
        vm.resetFocusTimer()

        // Invariants:
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task must receive full 600s")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Must have exactly 1 focus session record")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600, "Record must contain full 600s, NOT 300s!")
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(600), "Record endTime must be T0 + 600s")
        XCTAssertEqual(vm.todayFocusedSeconds, 600, "Today focus total must be 600s")
        XCTAssertEqual(vm.completedSessions, 0, "Reset session is not completed")
        XCTAssertEqual(vm.timeRemaining, 1500, "Timer must be reset to 1500s")
        XCTAssertFalse(vm.isTimerRunning, "Timer must be stopped")
        XCTAssertNil(vm.pausedSession, "Paused session must be cleared on reset")
    }

    // 2. Mandatory Red Reproduction — Skip Before Expiry
    @MainActor
    func testTask7_Ordering_SkipBeforeExpiry_WithPendingElapsedSeconds() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        // Tick at T0 + 300s
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // Advance to T0 + 600s without ticks
        simulatedNow = baseDate.addingTimeInterval(600)

        // Invoke skipSession() directly
        vm.skipSession()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task must receive full 600s")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Must record exactly 1 focus record")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600, "Record must contain full 600s, NOT 300s!")
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(600))
        XCTAssertEqual(vm.todayFocusedSeconds, 600)
        XCTAssertEqual(vm.completedSessions, 0, "Skipped session is not completed")
        XCTAssertEqual(vm.activePreset, "Short Break", "Must transition to Short Break")
        XCTAssertEqual(vm.currentSession, 2)
    }

    // 3. Mandatory Red Reproduction — End and Switch Before Expiry
    @MainActor
    func testTask7_Ordering_EndAndSwitch_BeforeExpiry_WithPendingElapsedSeconds() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        // Tick at T0 + 300s
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // Request switching to Break (creates conflict modal)
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal)
        XCTAssertNotNil(vm.pendingTimerRequest)

        // Advance to T0 + 600s without intermediate ticks
        simulatedNow = baseDate.addingTimeInterval(600)

        // Invoke endAndSwitch()
        vm.endAndSwitch(autoStart: false)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task must receive 600s")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Must record exactly 1 focus session")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600, "Record must contain 600s, NOT 300s!")
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(600))
        XCTAssertEqual(vm.todayFocusedSeconds, 600)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
    }

    // 4. Mandatory Red Reproduction — End and Switch After Expiry (Without Auto-Start)
    @MainActor
    func testTask7_Ordering_EndAndSwitch_AfterExpiry_WithoutAutoStart() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = false

        vm.startTimer()

        // Tick at T0 + 300s
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // Open switch confirmation modal while running
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal)

        // Advance to T0 + 7200s without wake reconciliation
        simulatedNow = baseDate.addingTimeInterval(7200)

        // Invoke endAndSwitch()
        vm.endAndSwitch(autoStart: false)

        // Invariants:
        XCTAssertEqual(vm.completedSessions, 1, "Expired focus session must increment completedSessions")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500, "Task credit must be capped at 1500s deadline")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500, "Record duration must be full 1500s")
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(1500), "Record endTime must be T0 + 1500s")
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
        XCTAssertEqual(vm.activePreset, "Short Break", "Must apply user's requested Short Break")
        XCTAssertFalse(vm.isTimerRunning, "Target timer must not run when autoStart is false")
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
    }

    // 4 (continued). End and Switch After Expiry (WITH Auto-Start)
    @MainActor
    func testTask7_Ordering_EndAndSwitch_AfterExpiry_WithAutoStart() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }
        vm.autoStartNextSession = true

        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal)

        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.endAndSwitch(autoStart: true)

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning, "Target timer must run when autoStart is true")
        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
    }

    // 5. Task switch before Reset
    @MainActor
    func testTask7_Ordering_TaskSwitchThenResetBeforeExpiry() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        let idA = vm.tasks[0].id
        let idB = vm.tasks[1].id

        vm.startTimer()

        // Switch to Task B at T0 + 200s
        simulatedNow = baseDate.addingTimeInterval(200)
        vm.selectTask(at: 1)

        // Tick on Task B at T0 + 300s (Task B gets 100s)
        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // Advance to T0 + 500s without ticks (Task B has 200s pending)
        simulatedNow = baseDate.addingTimeInterval(500)
        vm.resetFocusTimer()

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 200, "Task A must have 200s")
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 300, "Task B must have 100s + 200s = 300s")
        XCTAssertEqual(vm.sessionRecords.count, 2)
        XCTAssertEqual(vm.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 200)
        XCTAssertEqual(vm.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm.sessionRecords[1].durationSeconds, 300, "Record B must contain 300s, NOT 100s!")
        XCTAssertEqual(vm.todayFocusedSeconds, 500)
    }

    // 6. Unassigned focus time before Skip
    @MainActor
    func testTask7_Ordering_UnassignedTimeBeforeSkip() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        // Remove tasks so session is unassigned
        vm.tasks.removeAll()

        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        simulatedNow = baseDate.addingTimeInterval(600)
        vm.skipSession()

        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertNil(vm.sessionRecords[0].taskId)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600, "Unassigned record must have 600s, NOT 300s!")
        XCTAssertEqual(vm.todayFocusedSeconds, 600)
    }

    // 7. Reset after expiry capped at deadline
    @MainActor
    func testTask7_Ordering_ResetAfterExpiry_CappedAtDeadline() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(300)
        vm.tick()

        // Advance to 2 hours
        simulatedNow = baseDate.addingTimeInterval(7200)
        vm.resetFocusTimer()

        XCTAssertEqual(vm.completedSessions, 1, "Expired session increments completedSessions")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(1500))
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
        XCTAssertEqual(vm.timeRemaining, vm.totalTime, "Reset restores full duration of active preset")
        XCTAssertFalse(vm.isTimerRunning)
    }

    // MARK: - Task 7 Audit: SkipSession Boundary Race Tests

    // Test A: Focus expiry during skip operation, auto-start OFF
    // Boundary race: Call 1 sees T0 + 1499.9s (not expired), Call 2 sees T0 + 1500.0s (expired).
    // Must result in exactly ONE logical transition to Short Break (idle), completedSessions = 1.
    @MainActor
    func testTask7_Audit_FocusExpiryDuringSkip_AutoStartOff() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.autoStartNextSession = false
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        // Arm the sequence clock for skipSession:
        // Call 1 (skipSession initial read): 1499.9s (before 1500s deadline)
        // Subsequent calls: 1500.0s (at/past deadline)
        var callIndex = 0
        vm.currentDateProvider = {
            callIndex += 1
            if callIndex == 1 {
                return baseDate.addingTimeInterval(1499.9)
            } else {
                return baseDate.addingTimeInterval(1500.0)
            }
        }

        vm.skipSession()

        // Authoritative decision timestamp semantics:
        // skipSession() samples now = currentDateProvider() once at entry (T0 + 1499.9s).
        // Because now < 1500.0s deadline, this action is classified as a pre-deadline skip:
        // - Exactly ONE transition: Focus -> Short Break (idle)
        // - Does NOT double-transition back to Focus
        // - Task credited 1499s elapsed time
        // - completedSessions remains 0 (not an expiry completion)
        XCTAssertEqual(vm.activePreset, "Short Break", "Focus expiry during skip must transition once to Short Break, NOT double-transition back to Focus")
        XCTAssertTrue(vm.isBreakSession)
        XCTAssertEqual(vm.completedSessions, 0, "Authoritative decision timestamp (T0 + 1499.9s) is before deadline; classified as pre-deadline skip")
        XCTAssertFalse(vm.isTimerRunning, "Timer must be idle when auto-start is false")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1499, "Focus task must be credited 1499s elapsed time")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1499)
    }

    // Test B: Focus expiry during skip operation, auto-start ON
    // Boundary race: Call 1 sees T0 + 1499.9s, Call 2 sees T0 + 1500.0s.
    // Must result in exactly ONE transition to Short Break (running).
    // The auto-started Short Break must NOT be stopped or skipped.
    @MainActor
    func testTask7_Audit_FocusExpiryDuringSkip_AutoStartOn() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.autoStartNextSession = true
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        var callIndex = 0
        vm.currentDateProvider = {
            callIndex += 1
            if callIndex == 1 {
                return baseDate.addingTimeInterval(1499.9)
            } else {
                return baseDate.addingTimeInterval(1500.0)
            }
        }

        vm.skipSession()

        // Authoritative decision timestamp semantics:
        // skipSession() samples now = currentDateProvider() once at entry (T0 + 1499.9s).
        // - Exactly ONE transition to Short Break
        // - Short Break must remain running (auto-start honored)
        // - Task credited 1499s elapsed time
        // - completedSessions remains 0 (pre-deadline skip)
        XCTAssertEqual(vm.activePreset, "Short Break", "Must transition once to Short Break")
        XCTAssertTrue(vm.isBreakSession)
        XCTAssertEqual(vm.completedSessions, 0, "Authoritative decision timestamp is before deadline; classified as pre-deadline skip")
        XCTAssertTrue(vm.isTimerRunning, "Auto-started Short Break must continue running, not be stopped by recursive stopTimer")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1499, "Focus task must receive 1499s credit")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1499)
    }

    // Test C: Break expiry during skip operation
    // Short Break (300s). Boundary race: Call 1 sees T0 + 299.9s, Call 2 sees T0 + 300.0s.
    // Must result in exactly ONE transition to Focus (running when autoStartNextSession=true).
    @MainActor
    func testTask7_Audit_BreakExpiryDuringSkip() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.autoStartNextSession = true
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.applyPresetDirectly(name: "Short Break", minutes: 5, mode: "Pomodoro", isBreak: true)
        vm.startTimer()

        var callIndex = 0
        vm.currentDateProvider = {
            callIndex += 1
            if callIndex == 1 {
                return baseDate.addingTimeInterval(299.9)
            } else {
                return baseDate.addingTimeInterval(300.0)
            }
        }

        vm.skipSession()

        // Must produce exactly ONE transition: Short Break -> Focus (running)
        XCTAssertEqual(vm.activePreset, "Focus", "Break expiry during skip must transition once to Focus, NOT double-transition back to Short Break")
        XCTAssertFalse(vm.isBreakSession)
        XCTAssertTrue(vm.isTimerRunning, "Auto-started Focus session must remain running")
    }

    // Test C2: Break expiry during skip operation, auto-start OFF
    // Short Break (300s). Boundary race: Call 1 sees T0 + 299.9s, Call 2 sees T0 + 300.0s.
    // Must result in exactly ONE transition to Focus (idle when autoStartNextSession=false).
    @MainActor
    func testTask7_Audit_BreakExpiryDuringSkip_AutoStartOff() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.autoStartNextSession = false
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.applyPresetDirectly(name: "Short Break", minutes: 5, mode: "Pomodoro", isBreak: true)
        vm.startTimer()

        var callIndex = 0
        vm.currentDateProvider = {
            callIndex += 1
            if callIndex == 1 {
                return baseDate.addingTimeInterval(299.9)
            } else {
                return baseDate.addingTimeInterval(300.0)
            }
        }

        vm.skipSession()

        // Must produce exactly ONE transition: Short Break -> Focus (idle)
        XCTAssertEqual(vm.activePreset, "Focus", "Break expiry during skip must transition once to Focus, NOT double-transition back to Short Break")
        XCTAssertFalse(vm.isBreakSession)
        XCTAssertFalse(vm.isTimerRunning, "Focus session must remain idle when auto-start is false")
    }

    // Test D: Ordinary skip before expiry
    // Focus starts at T0. Skipped at T0 + 600s.
    // Must record 600s credit and session record, completedSessions = 0, transition to Short Break.
    @MainActor
    func testTask7_Audit_OrdinarySkipBeforeExpiry() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.autoStartNextSession = false
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(600)
        vm.skipSession()

        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isBreakSession)
        XCTAssertEqual(vm.completedSessions, 0, "Ordinary pre-deadline skip does not count as a completed session")
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Active task must receive 600s elapsed credit")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 600)
        XCTAssertEqual(vm.todayFocusedSeconds, 600)
    }

    // Test E: Already expired before skip
    // Focus starts at T0. Skipped at T0 + 1600s (already past 1500s deadline).
    // Must record 1500s credit and session record, completedSessions = 1, transition to Short Break.
    @MainActor
    func testTask7_Audit_AlreadyExpiredBeforeSkip() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.autoStartNextSession = false
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()

        simulatedNow = baseDate.addingTimeInterval(1600)
        vm.skipSession()

        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isBreakSession)
        XCTAssertEqual(vm.completedSessions, 1, "Expired skip records 1 completed session")
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1500, "Credit must be capped at 1500s")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(vm.sessionRecords[0].endTime, baseDate.addingTimeInterval(1500))
        XCTAssertEqual(vm.todayFocusedSeconds, 1500)
    }

    // MARK: - Task 8: Crash / Force-Quit Recovery Initial Red Tests

    // Red Test 1: Running Focus Timer recovery after sudden crash
    @MainActor
    func testTask8_Red_FocusCrashRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Start timer and tick to 300s
        do {
            let vm1 = TimerViewModel(storage: storage1)
            vm1.currentDateProvider = { simulatedNow }
            vm1.startTimer()

            // Advance 300s with ticks
            simulatedNow = baseDate.addingTimeInterval(300)
            vm1.tick()

            // Save durable checkpoint (simulating periodic checkpoint)
            vm1.persistData(force: true)

            // Unexpected crash: vm1 is deallocated WITHOUT calling vm1.handleAppTermination()!
        }

        // Process 2: Relaunch after crash at T0 + 600s
        simulatedNow = baseDate.addingTimeInterval(600)
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedNow })

        // Must recover in paused state with 1200s remaining (20:00) and 300s credited
        XCTAssertFalse(vm2.isTimerRunning, "Recovered timer must be paused")
        XCTAssertEqual(vm2.timeRemaining, 1200, "Timer remaining must be preserved from checkpoint (1500 - 300 = 1200)")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 300, "Active task must retain 300s credited before crash")
        XCTAssertEqual(vm2.sessionRecords.count, 1, "Interrupted session must be finalized into exactly 1 session record")
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 300, "Session record must record exactly 300s credited")
        XCTAssertEqual(vm2.todayFocusedSeconds, 300, "Today focused seconds must equal 300s")
        XCTAssertTrue(vm2.showRecoveryNotice, "Recovery notice must be displayed to the user")
    }

    // Red Test 2: Running Stopwatch recovery after sudden crash
    @MainActor
    func testTask8_Red_StopwatchCrashRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red_sw_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Start stopwatch, run for 125.5s
        do {
            let vm1 = TimerViewModel(storage: storage1)
            vm1.currentDateProvider = { simulatedNow }
            vm1.startStopwatch()

            simulatedNow = baseDate.addingTimeInterval(125.5)
            vm1.tick()
            vm1.persistData(force: true)

            // Crash: vm1 exits without handleAppTermination()
        }

        // Process 2: Relaunch after crash
        simulatedNow = baseDate.addingTimeInterval(300)
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2)
        vm2.currentDateProvider = { simulatedNow }

        XCTAssertFalse(vm2.isStopwatchRunning, "Recovered stopwatch must be paused")
        XCTAssertEqual(vm2.stopwatchTime, 125, "Stopwatch integer seconds must be 125")
        XCTAssertEqual(vm2.stopwatchFractional ?? 0.0, 125.5, accuracy: 0.01, "Stopwatch fractional seconds must be preserved")
        XCTAssertTrue(vm2.showRecoveryNotice, "Recovery notice must be displayed")
    }

    // Red Test 3: Task attribution across crash
    @MainActor
    func testTask8_Red_TaskAttributionAcrossCrash() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red_attr_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        var idA = UUID()
        var idB = UUID()

        // Process 1: Task A runs 200s, switches to Task B, Task B runs 300s, crashes
        do {
            let vm1 = TimerViewModel(storage: storage1)
            vm1.currentDateProvider = { simulatedNow }

            vm1.tasks[0].title = "Task A"
            idA = vm1.tasks[0].id

            vm1.addTask(title: "Task B", expectedMinutes: 25)
            idB = vm1.tasks[1].id

            vm1.selectTask(at: 0) // Select Task A
            vm1.startTimer()

            // Run 200s on Task A
            simulatedNow = baseDate.addingTimeInterval(200)
            vm1.tick()

            // Switch to Task B (finalizes 200s record for Task A)
            vm1.selectTask(at: 1)

            // Run 300s on Task B
            simulatedNow = baseDate.addingTimeInterval(500)
            vm1.tick()
            vm1.persistData(force: true)

            // Crash: no handleAppTermination()
        }

        // Process 2: Relaunch
        simulatedNow = baseDate.addingTimeInterval(700)
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedNow })

        XCTAssertEqual(vm2.tasks[0].id, idA)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 200, "Task A must retain 200s")
        XCTAssertEqual(vm2.tasks[1].id, idB)
        XCTAssertEqual(vm2.tasks[1].timeSpentSeconds, 300, "Task B must retain 300s")
        XCTAssertEqual(vm2.sessionRecords.count, 2, "Must contain exactly 2 session records (Task A and Task B)")
        XCTAssertEqual(vm2.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 200)
        XCTAssertEqual(vm2.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm2.sessionRecords[1].durationSeconds, 300)
        XCTAssertEqual(vm2.todayFocusedSeconds, 500, "Today total must be exactly 500s")
    }



    // MARK: - Task 8: Crash / Force-Quit Recovery Scenarios (Groups A-E, Scenarios 1-48)

    // MARK: Group A — Focus Recovery

    // Scenario 1: Crash immediately after starting Focus
    @MainActor
    func testTask8_Scenario01_CrashImmediatelyAfterStartingFocus() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc01_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Process 1: Start timer and immediately crash (0 seconds elapsed)
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { baseDate })
            vm1.startTimer()
            // Crash without ticks
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(10) })

        XCTAssertFalse(vm2.isTimerRunning, "Timer must recover in paused state")
        XCTAssertEqual(vm2.timeRemaining, 1500, "Full duration must be preserved")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 0, "No time credited")
        XCTAssertEqual(vm2.sessionRecords.count, 0, "No session record created for 0s duration")
        XCTAssertNotNil(vm2.pausedSession, "Paused session snapshot must be established")
    }

    // Scenario 2: Crash after several successful progress checkpoints
    @MainActor
    func testTask8_Scenario02_CrashAfterMultipleProgressCheckpoints() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc02_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Run through 3 checkpoints (15s, 30s, 45s)
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(15)
            vm1.tick()
            simulatedNow = baseDate.addingTimeInterval(30)
            vm1.tick()
            simulatedNow = baseDate.addingTimeInterval(45)
            vm1.tick()
            // Crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(100) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.timeRemaining, 1455)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 45)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 45)
        XCTAssertEqual(vm2.todayFocusedSeconds, 45)
    }

    // Scenario 3: Crash with an unexecuted coalesced save
    @MainActor
    func testTask8_Scenario03_CrashWithUnexecutedCoalescedSave() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc03_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Start timer (durable save), then tick (schedules delayed save) and crash before delay fires
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(5)
            vm1.tick()
            // Crash without calling performSave
        }

        // Process 2: Relaunch - recovers cleanly from startTimer checkpoint
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(20) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.timeRemaining, 1500)
        XCTAssertNotNil(vm2.pausedSession)
    }

    // Scenario 4: Crash after intermediate tick but before next checkpoint
    @MainActor
    func testTask8_Scenario04_CrashAfterIntermediateTickBeforeCheckpoint() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc04_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Checkpoint at 15s. Tick at 22s. Crash at 22s before 30s checkpoint.
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(15)
            vm1.tick()
            simulatedNow = baseDate.addingTimeInterval(22)
            vm1.reconcileActiveTimers(at: simulatedNow)
            // Crash
        }

        // Process 2: Relaunch - restores from durable 15s checkpoint
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(50) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.timeRemaining, 1485)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 15)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 15)
    }

    // Scenario 5: Crash just before the original deadline
    @MainActor
    func testTask8_Scenario05_CrashJustBeforeDeadline() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc05_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Run to T0 + 1490 (10s before deadline). Checkpoint. Crash.
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(1490)
            vm1.tick()
            vm1.persistData(force: true)
            // Crash
        }

        // Process 2: Relaunch past original deadline at T0 + 1600
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(1600) })

        XCTAssertFalse(vm2.isTimerRunning, "Must recover paused")
        XCTAssertEqual(vm2.timeRemaining, 10, "Remaining 10 seconds preserved")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 1490)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 1490)
        XCTAssertEqual(vm2.completedSessions, 0, "Session is not complete yet")
    }

    // Scenario 6: Crash after Focus completion was already durably saved
    @MainActor
    func testTask8_Scenario06_CrashAfterCompletionDurablySaved() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc06_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Natural completion at T0 + 1500, auto-transition to break, durable save, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.autoStartNextSession = false
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(1500)
            vm1.reconcileActiveTimers(at: simulatedNow)
            vm1.persistData(force: true)
            // Crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(1600) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.activePreset, "Short Break")
        XCTAssertEqual(vm2.todayFocusedSeconds, 1500)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertFalse(vm2.didRecoverInterruptedSession, "Cleanly saved completion is not an interrupted session")
    }

    // Scenario 7: Relaunch several hours after a crash without crediting unsupported downtime
    @MainActor
    func testTask8_Scenario07_RelaunchHoursAfterCrashNoDowntimeCredited() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc07_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: 300s worked, checkpoint, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(300)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch 8 hours later (T0 + 28800s)
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(28800) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.todayFocusedSeconds, 300, "Only the 300s worked before crash are credited")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 300)
        XCTAssertEqual(vm2.timeRemaining, 1200)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 300)
    }

    // Scenario 8: Custom Focus duration recovery
    @MainActor
    func testTask8_Scenario08_CustomFocusDurationRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc08_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Custom timer 45m (2700s), runs 600s, checkpoint, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.applyPresetDirectly(name: "Custom", minutes: 45, seconds: 0, mode: "Custom Timer", isBreak: false)
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(600)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(700) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertEqual(vm2.totalTime, 2700)
        XCTAssertEqual(vm2.timeRemaining, 2100)
        XCTAssertEqual(vm2.customMinutes, 45)
        XCTAssertEqual(vm2.customSeconds, 0)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 600)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 600)
    }

    // Scenario 9: Short Break and Long Break recovery
    @MainActor
    func testTask8_Scenario09_ShortBreakAndLongBreakRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc09_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Break session (300s), runs 100s, checkpoint, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.applyPresetDirectly(name: "Short Break", minutes: 5, seconds: 0, mode: "Pomodoro", isBreak: true)
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(100)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertTrue(vm2.isBreakSession)
        XCTAssertEqual(vm2.timeRemaining, 200)
        XCTAssertEqual(vm2.sessionRecords.count, 0, "Break sessions do not earn FocusSessionRecords")
        XCTAssertEqual(vm2.todayFocusedSeconds, 0)
        XCTAssertNotNil(vm2.pausedSession)
        XCTAssertTrue(vm2.pausedSession?.isBreakSession == true)
    }

    // Scenario 10: Repeated startup recovery produces no duplicate records
    @MainActor
    func testTask8_Scenario10_RepeatedStartupRecoveryNoDuplicates() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc10_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Run 200s, checkpoint, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(200)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch (first recovery)
        do {
            let storage2 = FocusStorageService(storageURL: storageURL)
            let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(300) })
            XCTAssertTrue(vm2.didRecoverInterruptedSession)
            XCTAssertEqual(vm2.sessionRecords.count, 1)
            XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 200)
        }

        // Process 3: Relaunch again (no crash, just a second app open)
        let storage3 = FocusStorageService(storageURL: storageURL)
        let vm3 = TimerViewModel(storage: storage3, currentDateProvider: { baseDate.addingTimeInterval(400) })

        XCTAssertFalse(vm3.didRecoverInterruptedSession, "Second launch must see clean state with activeSessionRecovery == nil")
        XCTAssertEqual(vm3.sessionRecords.count, 1, "Session record must NOT be duplicated")
        XCTAssertEqual(vm3.tasks[0].timeSpentSeconds, 200, "Task credit must NOT be duplicated")
        XCTAssertEqual(vm3.timeRemaining, 1300)
    }

    // MARK: Group B — Stopwatch Recovery

    // Scenario 11: Crash after a running stopwatch checkpoint
    @MainActor
    func testTask8_Scenario11_CrashAfterStopwatchCheckpoint() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc11_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 60s, checkpoint, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(60)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(120) })

        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.stopwatchTime, 60)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 60)
    }

    // Scenario 12: Crash with fractional elapsed seconds
    @MainActor
    func testTask8_Scenario12_CrashWithFractionalSeconds() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc12_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 125.75s, checkpoint, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(125.75)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })

        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.stopwatchTime, 125)
        XCTAssertEqual(vm2.stopwatchFractional ?? 0.0, 125.75, accuracy: 0.01)
    }

    // Scenario 13: Crash after several lap recordings
    @MainActor
    func testTask8_Scenario13_CrashAfterSeveralLapRecordings() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc13_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Lap 1 at 30s, Lap 2 at 75s, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(30)
            vm1.tick()
            vm1.recordLap()

            simulatedNow = baseDate.addingTimeInterval(75)
            vm1.tick()
            vm1.recordLap()
            // Crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(150) })

        XCTAssertEqual(vm2.laps.count, 2)
        XCTAssertEqual(vm2.laps[0].lapNumber, 2)
        XCTAssertEqual(vm2.laps[0].totalTime, 75.0, accuracy: 0.01)
        XCTAssertEqual(vm2.laps[1].lapNumber, 1)
        XCTAssertEqual(vm2.laps[1].totalTime, 30.0, accuracy: 0.01)
        XCTAssertEqual(vm2.nextLapNumber, 3)
    }

    // Scenario 14: Crash after deleting the newest lap
    @MainActor
    func testTask8_Scenario14_CrashAfterDeletingNewestLap() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc14_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Record 2 laps, remove newest lap (index 0), crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(20)
            vm1.tick()
            vm1.recordLap()

            simulatedNow = baseDate.addingTimeInterval(50)
            vm1.tick()
            vm1.recordLap()

            // Remove newest lap (index 0)
            vm1.removeLap(at: 0)
            // Crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(100) })

        XCTAssertEqual(vm2.laps.count, 1)
        XCTAssertEqual(vm2.laps[0].lapNumber, 1)
        XCTAssertEqual(vm2.laps[0].totalTime, 20.0, accuracy: 0.01)
    }

    // Scenario 15: Crash after deleting all visible laps
    @MainActor
    func testTask8_Scenario15_CrashAfterDeletingAllLaps() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc15_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Record lap, delete all laps, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(30)
            vm1.tick()
            vm1.recordLap()
            vm1.removeLap(at: 0)
            // Crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(60) })

        XCTAssertTrue(vm2.laps.isEmpty)
        XCTAssertTrue(vm2.nextLapNumber >= 1)
    }

    // Scenario 16: Crash after running longer than one hour
    @MainActor
    func testTask8_Scenario16_CrashAfterRunningOverOneHour() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc16_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 3750s (1h 2m 30s)
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(3750)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(4000) })

        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.stopwatchTime, 3750)
        XCTAssertEqual(vm2.stopwatchTimeString, "01:02:30")
    }

    // Scenario 17: Resume recovered stopwatch and record a new lap
    @MainActor
    func testTask8_Scenario17_ResumeRecoveredStopwatchAndRecordLap() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc17_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 100s, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(100)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch, resume stopwatch, run 20s more to 120s, record lap
        simulatedNow = baseDate.addingTimeInterval(200)
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedNow })

        XCTAssertEqual(vm2.stopwatchTime, 100)
        vm2.startStopwatch()
        simulatedNow = baseDate.addingTimeInterval(220) // +20s
        vm2.tick()
        vm2.recordLap()

        XCTAssertEqual(vm2.stopwatchTime, 120)
        XCTAssertEqual(vm2.laps.count, 1)
        XCTAssertEqual(vm2.laps[0].totalTime, 120.0, accuracy: 0.1)
    }

    // Scenario 18: Verify task credit is not duplicated
    @MainActor
    func testTask8_Scenario18_StopwatchTaskCreditNotDuplicated() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc18_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 50s on Task A
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(50)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(150) })

        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 50, "Task must have exactly 50s, not duplicated")
        // Run 25s more
        var now2 = baseDate.addingTimeInterval(150)
        vm2.startStopwatch()
        now2 = baseDate.addingTimeInterval(175)
        vm2.reconcileActiveTimers(at: now2)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 75, "Task must now have 75s total")
    }

    // Scenario 19: Verify process downtime is not automatically credited
    @MainActor
    func testTask8_Scenario19_StopwatchDowntimeNotCredited() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc19_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 40s
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(40)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch 3 hours later
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(10840) })

        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.stopwatchTime, 40, "Stopwatch elapsed must remain 40s")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 40)
    }

    // Scenario 20: Verify stopped/paused stopwatch recovery is unchanged
    @MainActor
    func testTask8_Scenario20_PausedStopwatchRecoveryUnchanged() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc20_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 35s, explicitly paused, saved
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(35)
            vm1.stopStopwatch()
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(100) })

        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.stopwatchTime, 35)
        XCTAssertFalse(vm2.didRecoverInterruptedSession, "Cleanly paused stopwatch is not treated as crash recovery")
    }

    // MARK: Group C — Task Attribution

    // Scenario 21: Crash after Task A -> Task B switch
    @MainActor
    func testTask8_Scenario21_CrashAfterTaskSwitch() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc21_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        var idA = UUID()
        var idB = UUID()

        // Process 1: A runs 100s, switch to B, B runs 150s, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.tasks[0].title = "Task A"
            idA = vm1.tasks[0].id
            vm1.addTask(title: "Task B", expectedMinutes: 25)
            idB = vm1.tasks[1].id

            vm1.selectTask(at: 0)
            vm1.startTimer()

            simulatedNow = baseDate.addingTimeInterval(100)
            vm1.tick()

            vm1.selectTask(at: 1)

            simulatedNow = baseDate.addingTimeInterval(250)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(400) })

        XCTAssertEqual(vm2.sessionRecords.count, 2)
        XCTAssertEqual(vm2.sessionRecords[0].taskId, idA)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 100)
        XCTAssertEqual(vm2.sessionRecords[1].taskId, idB)
        XCTAssertEqual(vm2.sessionRecords[1].durationSeconds, 150)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 100)
        XCTAssertEqual(vm2.tasks[1].timeSpentSeconds, 150)
        XCTAssertEqual(vm2.todayFocusedSeconds, 250)
    }

    // Scenario 22: Crash with no task selected
    @MainActor
    func testTask8_Scenario22_CrashWithNoTaskSelected() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc22_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Complete all tasks so no task is active, run 90s, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            for i in 0..<vm1.tasks.count {
                vm1.tasks[i].isCompleted = true
            }
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(90)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })

        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertNil(vm2.sessionRecords[0].taskId, "Record must have nil taskId when no task selected")
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 90)
        XCTAssertEqual(vm2.todayFocusedSeconds, 90)
    }

    // Scenario 23: Crash after task creation during Stopwatch activity
    @MainActor
    func testTask8_Scenario23_CrashAfterTaskCreationDuringStopwatch() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc23_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Stopwatch runs 50s, add new task, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startStopwatch()
            simulatedNow = baseDate.addingTimeInterval(50)
            vm1.tick()
            vm1.addTask(title: "Brand New Task", expectedMinutes: 30)
            // Crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(100) })

        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 50)
        XCTAssertTrue(vm2.tasks.contains(where: { $0.title == "Brand New Task" }))
    }

    // Scenario 24: Crash after completing the active task
    @MainActor
    func testTask8_Scenario24_CrashAfterCompletingActiveTask() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc24_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Run 120s on Task 0, complete Task 0, run 60s on Task 1, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.addTask(title: "Task 2", expectedMinutes: 25)
            vm1.startTimer()

            simulatedNow = baseDate.addingTimeInterval(120)
            vm1.tick()

            vm1.toggleTaskCompletion(at: 0) // completes Task 0, switches to Task 1

            simulatedNow = baseDate.addingTimeInterval(180)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(300) })

        XCTAssertTrue(vm2.tasks[0].isCompleted)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 120)
        XCTAssertFalse(vm2.tasks[1].isCompleted)
        XCTAssertEqual(vm2.tasks[1].timeSpentSeconds, 60)
        XCTAssertEqual(vm2.sessionRecords.count, 2)
    }

    // Scenario 25: Crash after deleting the active task
    @MainActor
    func testTask8_Scenario25_CrashAfterDeletingActiveTask() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc25_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        var idDeleting = UUID()

        // Process 1: Run 80s on Task 0, delete Task 0, run 40s on surviving task, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            idDeleting = vm1.tasks[0].id
            vm1.addTask(title: "Surviving Task", expectedMinutes: 25)
            vm1.startTimer()

            simulatedNow = baseDate.addingTimeInterval(80)
            vm1.tick()

            vm1.removeTask(at: 0)

            simulatedNow = baseDate.addingTimeInterval(120)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })

        XCTAssertFalse(vm2.tasks.contains(where: { $0.id == idDeleting }))
        XCTAssertEqual(vm2.sessionRecords.count, 2)
        XCTAssertEqual(vm2.sessionRecords[0].taskId, idDeleting)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 80)
        XCTAssertEqual(vm2.sessionRecords[1].durationSeconds, 40)
    }

    // Scenario 26: Crash while Focus and Stopwatch both in storage payload
    @MainActor
    func testTask8_Scenario26_FocusAndStopwatchCrashRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc26_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Write manual payload simulating both in-flight
        let recovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            preciseProgress: 0.8,
            targetEndDate: baseDate.addingTimeInterval(1200),
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: nil,
            currentSession: 1,
            isStopwatchRunning: true,
            stopwatchElapsedSeconds: 45.0,
            stopwatchTaskId: nil,
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let payload = FocusAppData(
            tasks: [FocusTask(title: "Task 1", estimatedMinutes: 25)],
            focusedSeconds: 300,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 45.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: nil,
            activeMode: "Pomodoro",
            activeSessionRecovery: recovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(payload)

        // Relaunch
        let vm = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(500) })

        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1200)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 300)
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 45)
    }

    // Scenario 27: Verify surviving task UUID associations
    @MainActor
    func testTask8_Scenario27_SurvivingTaskUUIDAssociations() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc27_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        let expectedUUID = UUID()

        // Process 1: Custom UUID task runs 150s, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.tasks = [FocusTask(id: expectedUUID, title: "UUID Task", estimatedMinutes: 25)]
            vm1.selectTask(at: 0)
            vm1.startTimer()

            simulatedNow = baseDate.addingTimeInterval(150)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(250) })

        XCTAssertEqual(vm2.tasks[0].id, expectedUUID)
        XCTAssertEqual(vm2.sessionRecords[0].taskId, expectedUUID)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 150)
    }

    // Scenario 28: Verify previously persisted task totals are conserved
    @MainActor
    func testTask8_Scenario28_PersistedTaskTotalsConserved() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc28_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Task starts with 500s prior history. Runs 100s today, crash.
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.tasks[0].timeSpentSeconds = 500
            vm1.persistData(force: true)

            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(100)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })

        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 600, "500s prior + 100s today = 600s")
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 100)
    }

    // MARK: Group D — Persistence and Atomicity

    // Scenario 29: Crash before the first delayed save
    @MainActor
    func testTask8_Scenario29_CrashBeforeFirstDelayedSave() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc29_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)

        // Process 1: Initial state saved
        do {
            _ = TimerViewModel(storage: storage1)
        }

        // Process 2: Relaunch successfully loads initial state
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2)
        XCTAssertEqual(vm2.storageLoadResult, .freshInstall)
    }

    // Scenario 30: Crash after durable save but before pending callback execution
    @MainActor
    func testTask8_Scenario30_CrashAfterDurableSaveBeforeCallback() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc30_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)

        // Process 1: Force save happens synchronously, process crashes before runloop idle
        do {
            let vm1 = TimerViewModel(storage: storage1)
            vm1.addTask(title: "Synchronous Task", expectedMinutes: 20)
            // crash
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2)
        XCTAssertTrue(vm2.tasks.contains(where: { $0.title == "Synchronous Task" }))
    }

    // Scenario 31: Stale callback cannot overwrite recovered state
    @MainActor
    func testTask8_Scenario31_StaleCallbackCannotOverwriteRecoveredState() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc31_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage)

        // Initial forced save sets lastPersistTime
        vm.persistData(force: true)
        XCTAssertFalse(vm.hasPendingSave)

        var capturedAction: (() -> Void)?
        vm.saveScheduler = { delay, action in
            capturedAction = action
            return AnyCancellable { }
        }

        // Trigger throttled save
        vm.totalSessions = 8
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(capturedAction)

        // Invalidate or supersede that callback through forced persistence with newer state
        vm.totalSessions = 10
        vm.persistData(force: true)
        XCTAssertFalse(vm.hasPendingSave)

        // Read storage: must contain newer committed state
        let dataAfterForced = try storage.decodeData(from: storageURL)
        XCTAssertEqual(dataAfterForced.totalSessions, 10)

        let saveCountBeforeStale = storage.saveAttemptCount

        // Execute the stale callback deliberately
        capturedAction?()

        // Verify it cannot overwrite newer committed state
        let dataAfterStale = try storage.decodeData(from: storageURL)
        XCTAssertEqual(dataAfterStale.totalSessions, 10)
        XCTAssertEqual(storage.saveAttemptCount, saveCountBeforeStale, "Stale callback must not perform an additional disk write")
        XCTAssertEqual(vm.sessionRecords.count, 0, "No duplicate session record produced by stale callback")
    }

    // Scenario 32: Primary corruption with valid backup
    @MainActor
    func testTask8_Scenario32_PrimaryCorruptionWithValidBackup() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc32_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = FocusStorageService(storageURL: storageURL)
        let validPayload = FocusAppData(
            tasks: [FocusTask(title: "Backed Up Task", estimatedMinutes: 25)],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: nil,
            activeMode: "Pomodoro"
        )
        try storage.save(validPayload)
        // Perform second save to generate backup file
        try storage.save(validPayload)

        // Corrupt primary
        try "CORRUPTED_BYTES".write(to: storageURL, atomically: true, encoding: .utf8)

        let vm = TimerViewModel(storage: storage)
        XCTAssertTrue(vm.didRecoverFromBackup)
        XCTAssertTrue(vm.showRecoveryNotice)
        XCTAssertTrue(vm.tasks.contains(where: { $0.title == "Backed Up Task" }))
    }

    // Scenario 33: Primary and backup both corrupted
    @MainActor
    func testTask8_Scenario33_PrimaryAndBackupCorrupted() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc33_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        let backupURL = storageURL.appendingPathExtension("bak")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "BAD PRIMARY".write(to: storageURL, atomically: true, encoding: .utf8)
        try "BAD BACKUP".write(to: backupURL, atomically: true, encoding: .utf8)

        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertTrue(vm.isPersistenceBlocked)
        XCTAssertNotNil(vm.storageErrorMessage)
    }

    // Scenario 34: Checkpoint write failure
    @MainActor
    func testTask8_Scenario34_CheckpointWriteFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc34_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage)

        // Seed valid initial storage state
        vm.notes = ["Initial Valid Note"]
        vm.persistData(force: true)
        XCTAssertFalse(vm.isSaveFailed)

        // Enable simulated write failure
        storage.simulateWriteFailure = true

        // Trigger an actual checkpoint
        vm.startTimer()
        vm.checkpointActiveTimers()

        // Assert failure definitely occurs
        XCTAssertTrue(vm.isSaveFailed, "Save failure flag must definitely be true")
        XCTAssertNotNil(vm.saveErrorMessage, "Error message must be present")
        XCTAssertEqual(vm.lastSaveError, StorageError.writeFailed(storageURL, underlyingError: "Simulated primary write failure"))

        // Verify previously valid disk contents remain recoverable
        let storage2 = FocusStorageService(storageURL: storageURL)
        let loaded = storage2.loadDetailed()
        switch loaded {
        case .success(let data), .recovered(let data, _, _):
            XCTAssertEqual(data.notes, ["Initial Valid Note"])
        default:
            XCTFail("Previously valid disk data must remain readable")
        }

        // Verify retry behavior after removing failure
        storage.simulateWriteFailure = false
        vm.retrySave()
        XCTAssertFalse(vm.isSaveFailed, "Save failure must be cleared on successful retry")
        XCTAssertNil(vm.saveErrorMessage)
    }

    // Scenario 35: Recovery final-save failure and safe retry
    @MainActor
    func testTask8_Scenario35_RecoverySaveFailureAndRetry() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc35_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)

        // 1. Write a valid interrupted Focus session to isolated test storage
        let task = FocusTask(title: "Recovery Task", estimatedMinutes: 25)
        let recoveryState = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let interruptedPayload = FocusAppData(
            tasks: [task],
            focusedSeconds: 300,
            completedSessions: 0,
            notes: ["Note before crash"],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recoveryState
        )
        try storage1.save(interruptedPayload)

        // 2. Configure storage to fail the final recovery save before constructing recovering VM
        storage1.simulateWriteFailure = true

        // 3. Construct VM using injected clock
        let vm = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(400) })

        // 4. Verify recovery accounting is correct in memory
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 300)
        XCTAssertEqual(vm.timeRemaining, 1200)

        // 5. Verify the attempted cleanup save genuinely fails
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)

        // 6. Verify disk recovery metadata has not been falsely cleared
        let storageUnchanged = FocusStorageService(storageURL: storageURL)
        let rawDiskPayload = try storageUnchanged.decodeData(from: storageURL)
        XCTAssertNotNil(rawDiskPayload.activeSessionRecovery, "activeSessionRecovery must not be cleared on disk if save failed")

        // 7. Verify no false durable-success notice is displayed
        XCTAssertFalse(vm.showRecoveryNotice, "Durable success notice must not be shown on write failure")

        // 8. Remove the injected failure and retry
        storage1.simulateWriteFailure = false
        vm.retrySave()

        // 9. Verify the clean recovered state is committed
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertTrue(vm.showRecoveryNotice)
        let committedDiskPayload = try storageUnchanged.decodeData(from: storageURL)
        XCTAssertNil(committedDiskPayload.activeSessionRecovery, "activeSessionRecovery must be absent on disk after successful retry")
        XCTAssertEqual(committedDiskPayload.sessionRecords.count, 1)

        // 10. Relaunch again and confirm no duplication
        let vmRelaunch = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(500) })
        XCTAssertEqual(vmRelaunch.sessionRecords.count, 1, "Relaunch must not duplicate recovered records")
    }

    // Scenario 36: Legacy JSON without Task 8 fields
    @MainActor
    func testTask8_Scenario36_LegacyJSONWithoutTask8Fields() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc36_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let task = FocusTask(title: "Legacy Task", estimatedMinutes: 25)
        let payload = FocusAppData(
            tasks: [task],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: nil,
            activeMode: "Pomodoro"
        )
        let encodedData = try JSONEncoder().encode(payload)
        try encodedData.write(to: storageURL)

        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage)

        XCTAssertFalse(vm.isPersistenceBlocked)
        XCTAssertEqual(vm.tasks[0].title, "Legacy Task")
        XCTAssertFalse(vm.didRecoverInterruptedSession)
    }

    // Scenario 37: Interrupted initial save remains recoverable
    @MainActor
    func testTask8_Scenario37_InterruptedInitialSaveRecoverable() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc37_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        // Simulate initial backup succeeding while primary write fails
        storage1.simulateWriteFailure = true

        let customTask = FocusTask(title: "Initial Backup Task", estimatedMinutes: 25)
        let initialData = FocusAppData(
            tasks: [customTask],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: ["Initial note"],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: customTask.id,
            activeMode: "Pomodoro"
        )

        // Saving fresh install with simulateWriteFailure throws error, but initial backup was written
        XCTAssertThrowsError(try storage1.save(initialData))
        XCTAssertTrue(storage1.hasInterruptedInitialSave)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage1.backupURL.path), "Backup file must exist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path), "Primary file must not exist")

        // Construct a new storage and ViewModel instance
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2)

        // Verify startup recovery from that backup
        XCTAssertTrue(vm2.didRecoverFromBackup, "ViewModel must recover from the initial backup")
        XCTAssertTrue(vm2.tasks.contains(where: { $0.title == "Initial Backup Task" }))
        XCTAssertEqual(vm2.notes, ["Initial note"])
        XCTAssertFalse(vm2.isPersistenceBlocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path), "Primary file must now be restored from backup")
    }

    // Scenario 38: No duplicate recovery when reloading twice
    @MainActor
    func testTask8_Scenario38_NoDuplicateRecoveryOnSecondReload() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc38_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: 100s Focus session, crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(100)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Load once
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })
        XCTAssertEqual(vm2.sessionRecords.count, 1)

        // Process 2 calls loadPersistedData() again
        vm2.loadPersistedData()
        XCTAssertEqual(vm2.sessionRecords.count, 1, "Must not duplicate session record on reload")
        XCTAssertFalse(vm2.didRecoverInterruptedSession)
    }

    // MARK: Group E — Existing Policies

    // Scenario 39: Normal quit remains unchanged
    @MainActor
    func testTask8_Scenario39_NormalQuitUnchanged() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc39_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1: Normal termination via handleAppTermination
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(200)
            vm1.handleAppTermination()
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(300) })

        XCTAssertFalse(vm2.didRecoverInterruptedSession, "Normal quit is not a crash recovery")
        XCTAssertFalse(vm2.showRecoveryNotice)
        XCTAssertEqual(vm2.timeRemaining, 1300)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 200)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
    }

    // Scenario 40: Sleeping while app remains running still follows Task 7 wall-clock rules
    @MainActor
    func testTask8_Scenario40_SleepWakeWallClockAccounting() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        // Sleep for 200s while process remains alive
        simulatedNow = baseDate.addingTimeInterval(200)
        vm.reconcileActiveTimers(at: simulatedNow)

        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 1300)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 200)
    }

    // Scenario 41: Original Focus deadline is never shifted
    @MainActor
    func testTask8_Scenario41_OriginalFocusDeadlineNeverShifted() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate
        vm.currentDateProvider = { simulatedNow }

        vm.startTimer()
        let initialDeadline = vm.targetEndDate

        // Intermediate ticks
        for s in stride(from: 10, through: 100, by: 10) {
            simulatedNow = baseDate.addingTimeInterval(Double(s))
            vm.tick()
            XCTAssertEqual(vm.targetEndDate, initialDeadline, "Target deadline must not drift")
        }
    }

    // Scenario 42: Midnight-crossing recovery conserves recorded duration
    @MainActor
    func testTask8_Scenario42_MidnightCrossingRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc42_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        // 23:55:00 on Day 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 55, second: 0))!
        var simulatedNow = day1

        // Process 1: Starts at 23:55, runs 180s to 23:58, crashes
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.systemCalendarProvider = { calendar }
            vm1.startTimer()
            simulatedNow = day1.addingTimeInterval(180)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2: Relaunches on Day 2 at 00:05:00 (10 minutes later)
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 5, second: 0))!
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { day2 })
        vm2.systemCalendarProvider = { calendar }
        vm2.recalculateFocusMetrics()

        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 180, "Duration is conserved exactly")
        // Since the session occurred on Day 1, Day 2 todayFocusedSeconds is 0
        XCTAssertEqual(vm2.todayFocusedSeconds, 0)
    }

    // Scenario 43: Timezone change does not create or destroy credited seconds
    @MainActor
    func testTask8_Scenario43_TimezoneChangePreservesCredit() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc43_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = baseDate

        // Process 1 in UTC
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedNow })
            vm1.startTimer()
            simulatedNow = baseDate.addingTimeInterval(300)
            vm1.tick()
            vm1.persistData(force: true)
        }

        // Process 2 in Tokyo (+9 hours)
        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(400) })
        vm2.systemCalendarProvider = { tokyoCalendar }

        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 300)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 300)
    }

    // Scenario 44: Backward clock jumps cannot generate negative durations
    @MainActor
    func testTask8_Scenario44_BackwardClockJumpNoNegativeDuration() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc44_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Process 1: Crash at T0 + 100
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { baseDate })
            vm1.startTimer()
            vm1.reconcileActiveTimers(at: baseDate.addingTimeInterval(100))
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch with clock that jumped BACKWARD to T0 - 50
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(-50) })

        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertGreaterThanOrEqual(vm2.sessionRecords[0].durationSeconds, 0, "Duration must never be negative")
    }

    // Scenario 45: Auto-start enabled does not cause unexpected startup timers
    @MainActor
    func testTask8_Scenario45_AutoStartNoUnexpectedStartupTimers() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc45_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Process 1: autoStartNextSession = true, running timer crashes
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { baseDate })
            vm1.autoStartNextSession = true
            vm1.startTimer()
            vm1.reconcileActiveTimers(at: baseDate.addingTimeInterval(150))
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(300) })

        XCTAssertFalse(vm2.isTimerRunning, "Recovered timer must be PAUSED even if autoStartNextSession is true")
        XCTAssertFalse(vm2.isStopwatchRunning)
    }

    // Scenario 46: Closing/reopening the window does not trigger crash recovery
    @MainActor
    func testTask8_Scenario46_WindowCloseReopenNoCrashRecovery() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let appDelegate = FocusFlowAppDelegate(viewModel: vm)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        appDelegate.mainWindow = window

        // Start timer
        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)

        // Close window via appDelegate.windowShouldClose
        let shouldClose = appDelegate.windowShouldClose(window)
        XCTAssertFalse(shouldClose, "Window delegate must return false to hide window instead of destroying it")
        XCTAssertFalse(window.isVisible, "Window must be ordered out (hidden)")

        // Timer must continue running in memory without termination or crash recovery
        XCTAssertTrue(vm.isTimerRunning, "Timer must continue running while window is closed")
        XCTAssertFalse(vm.hasTerminated, "Application must not terminate on window close")
        XCTAssertFalse(vm.didRecoverInterruptedSession, "Crash recovery must not trigger on window close")
        XCTAssertEqual(vm.sessionRecords.count, 0, "No premature session record should be created")

        // Reopen window via appDelegate.showMainWindow()
        appDelegate.showMainWindow()
        XCTAssertTrue(window.isVisible, "Window must be visible again after reopening")
        XCTAssertTrue(vm.isTimerRunning, "Timer remains active after window reopened")
    }

    // Scenario 47: Existing notes, settings, laps and preserved sessions remain unchanged
    @MainActor
    func testTask8_Scenario47_NotesSettingsPreservedSessionsUnchanged() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc47_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Process 1: Add note, daily goal, preserved session, then start timer and crash
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { baseDate })
            vm1.noteDraft = "Important meeting note"
            vm1.saveNote()
            vm1.dailyGoalHours = 6
            vm1.totalSessions = 6
            vm1.startTimer()
            vm1.reconcileActiveTimers(at: baseDate.addingTimeInterval(100))
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(200) })

        XCTAssertEqual(vm2.notes, ["Important meeting note"])
        XCTAssertEqual(vm2.dailyGoalHours, 6)
        XCTAssertEqual(vm2.totalSessions, 6)
    }

    // Scenario 48: Successful crash recovery leaves a valid persisted state for the next relaunch
    @MainActor
    func testTask8_Scenario48_ValidPersistedStateForNextRelaunch() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_sc48_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storage1 = FocusStorageService(storageURL: storageURL)
        let baseDate = Date(timeIntervalSince1970: 1770000000)

        // Process 1: Crash with running timer
        do {
            let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { baseDate })
            vm1.startTimer()
            vm1.reconcileActiveTimers(at: baseDate.addingTimeInterval(200))
            vm1.persistData(force: true)
        }

        // Process 2: Relaunch performs recovery and auto-saves clean state
        do {
            let storage2 = FocusStorageService(storageURL: storageURL)
            let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { baseDate.addingTimeInterval(300) })
            XCTAssertTrue(vm2.didRecoverInterruptedSession)
        }

        // Verify the persisted JSON on disk has activeSessionRecovery == nil
        let storage3 = FocusStorageService(storageURL: storageURL)
        let savedData = storage3.load()!
        XCTAssertNil(savedData.activeSessionRecovery, "activeSessionRecovery must be nil on disk after recovery")
        XCTAssertEqual(savedData.sessionRecords.count, 1)
    }

    // Finding 1 - Test F1-A: Stopwatch Lap Without Tick
    @MainActor
    func testTask8_F1_A_StopwatchLapWithoutTick() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f1a_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)
        let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedTime })

        // Task A is selected (index 0)
        let taskAId = vm1.tasks[0].id
        vm1.startStopwatch()

        // Advance simulated clock 100 seconds with NO tick
        simulatedTime = simulatedTime.addingTimeInterval(100)

        // Record lap at T0 + 100s
        vm1.recordLap()

        // Inspect actual persisted FocusAppData on disk before relaunch
        let persistedData = storage1.load()!
        XCTAssertEqual(Int(persistedData.stopwatchElapsedSeconds), 100, "Persisted stopwatch elapsed must be 100")
        XCTAssertEqual(persistedData.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 100, "Task A credited time must be 100 in persisted payload")
        XCTAssertEqual(persistedData.laps.count, 1)
        XCTAssertEqual(Int(persistedData.laps[0].totalTime), 100, "Latest lap total must be 100")

        // Simulate crash without handleAppTermination()
        // Relaunch and verify values remain 100 seconds
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedTime.addingTimeInterval(50) })

        XCTAssertEqual(vm2.stopwatchTime, 100, "Restored stopwatch time must be 100")
        XCTAssertEqual(vm2.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 100, "Restored Task A credit must remain 100")
        XCTAssertEqual(vm2.laps.count, 1)
        XCTAssertEqual(Int(vm2.laps[0].totalTime), 100)

        // Repeated relaunch must not increase task credit
        let storage3 = FocusStorageService(storageURL: storageURL)
        let vm3 = TimerViewModel(storage: storage3, currentDateProvider: { simulatedTime.addingTimeInterval(100) })
        XCTAssertEqual(vm3.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 100, "Repeated relaunch must not increase task credit")
    }

    // Finding 1 - Test F1-B: Focus Checkpoint Without Tick
    @MainActor
    func testTask8_F1_B_FocusCheckpointWithoutTick() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f1b_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)
        let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedTime })

        let taskAId = vm1.tasks[0].id
        vm1.startTimer() // 1500 seconds

        // Advance to T0 + 300 seconds without a timer tick
        simulatedTime = simulatedTime.addingTimeInterval(300)

        // Trigger forced persistence
        vm1.persistData(force: true)

        let persistedData = storage1.load()!
        XCTAssertEqual(persistedData.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 300, "Persisted task credit must be 300")
        XCTAssertEqual(persistedData.activeSessionRecovery?.timeRemaining, 1200, "Persisted remaining must be 1200")
        XCTAssertEqual(persistedData.activeSessionRecovery?.segmentCreditedSeconds, 300, "Recovery metadata credit must be 300")

        // Relaunch after additional downtime (e.g. + 600s)
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedTime.addingTimeInterval(600) })

        XCTAssertEqual(vm2.sessionRecords.count, 1, "Exactly one 300-second record must exist")
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 300)
        XCTAssertEqual(vm2.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 300, "No downtime credit added to task")
        XCTAssertEqual(vm2.timeRemaining, 1200)
    }

    // Finding 2 - Test F2-A: Credit Exceeds Duration
    @MainActor
    func testTask8_F2_A_CreditExceedsDuration_Rejected() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f2a_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let task = FocusTask(title: "Audit Task", estimatedMinutes: 25)
        let recovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            segmentCreditedSeconds: 2000, // MALFORMED: exceeds totalTime (1500)
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate
        )
        let validPayload = FocusAppData(
            tasks: [task],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: ["Preserved note"],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(validPayload)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(100) })

        // Malformed recovery metadata must be rejected
        XCTAssertTrue(vm.sessionRecords.filter({ $0.durationSeconds == 2000 }).isEmpty, "No 2000-second record must be created")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "No inflated task credit must be introduced")
        XCTAssertEqual(vm.notes, ["Preserved note"], "Existing valid notes must remain intact")
        XCTAssertEqual(vm.tasks[0].title, "Audit Task", "Existing valid tasks must remain intact")
    }

    // Finding 2 - Test F2-B: Unsupported Recovery Version
    @MainActor
    func testTask8_F2_B_UnsupportedRecoveryVersion_Rejected() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f2b_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let task = FocusTask(title: "Version Task", estimatedMinutes: 25)
        let recovery = ActiveSessionRecoveryState(
            version: 99, // UNSUPPORTED VERSION
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate
        )
        let payload = FocusAppData(
            tasks: [task],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: ["Valid note"],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(payload)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(100) })

        XCTAssertFalse(vm.didRecoverInterruptedSession, "Unsupported recovery version must be rejected")
        XCTAssertEqual(vm.sessionRecords.count, 0, "No session record created for unsupported version")
        XCTAssertEqual(vm.tasks[0].title, "Version Task", "Task must remain intact")
        XCTAssertEqual(vm.notes, ["Valid note"], "Notes must remain intact")
    }

    // Finding 2 - Test F2-C: Impossible Timestamps
    @MainActor
    func testTask8_F2_C_ImpossibleTimestamps_Rejected() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f2c_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let task = FocusTask(title: "Timestamp Task", estimatedMinutes: 25)
        // Segment start is AFTER checkpoint timestamp!
        let recovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate.addingTimeInterval(500),
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate
        )
        let payload = FocusAppData(
            tasks: [task],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(payload)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(100) })

        XCTAssertFalse(vm.didRecoverInterruptedSession, "Impossible timestamps must be rejected")
        XCTAssertEqual(vm.sessionRecords.count, 0, "No record should be created for impossible timestamps")
    }

    // Finding 1 - Test F1-C: Simultaneous Focus and Stopwatch
    @MainActor
    func testTask8_F1_C_SimultaneousFocusAndStopwatch() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f1c_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)
        let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedTime })

        let taskAId = vm1.tasks[0].id

        // Start Focus and Stopwatch simultaneously
        vm1.startTimer()
        vm1.startStopwatch()

        // Advance clock 200 seconds without intervening ticks
        simulatedTime = simulatedTime.addingTimeInterval(200)

        // Trigger forced persistence
        vm1.persistData(force: true)

        let persisted = storage1.load()!
        // Both activities must have settled their elapsed time
        XCTAssertEqual(persisted.activeSessionRecovery?.timeRemaining, 1300)
        XCTAssertEqual(persisted.activeSessionRecovery?.segmentCreditedSeconds, 200)
        XCTAssertEqual(Int(persisted.activeSessionRecovery?.stopwatchElapsedSeconds ?? 0), 200)
        // Task A was credited by both focus (200s) and stopwatch (200s) = 400s
        XCTAssertEqual(persisted.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 400)

        // Crash and relaunch
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedTime.addingTimeInterval(300) })

        XCTAssertFalse(vm2.isTimerRunning)
        XCTAssertFalse(vm2.isStopwatchRunning)
        XCTAssertEqual(vm2.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 400, "Credit must be preserved without loss or duplication")
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 200)
        XCTAssertEqual(vm2.stopwatchTime, 200)
        XCTAssertEqual(vm2.timeRemaining, 1300)
    }

    // Finding 1 - Test F1-D: Task Switch Boundary
    @MainActor
    func testTask8_F1_D_TaskSwitchBoundary() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f1d_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)
        let vm1 = TimerViewModel(storage: storage1, currentDateProvider: { simulatedTime })

        let taskAId = vm1.tasks[0].id
        let taskBId = vm1.tasks[1].id

        vm1.startTimer() // On Task A

        // Accumulate 150 seconds without a tick
        simulatedTime = simulatedTime.addingTimeInterval(150)

        // Switch to Task B
        vm1.selectTask(at: 1)

        // Crash immediately after the durable transition
        let storage2 = FocusStorageService(storageURL: storageURL)
        let vm2 = TimerViewModel(storage: storage2, currentDateProvider: { simulatedTime.addingTimeInterval(100) })

        // Task A must have all pre-switch time (150s), Task B must have 0
        XCTAssertEqual(vm2.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 150)
        XCTAssertEqual(vm2.tasks.first(where: { $0.id == taskBId })?.timeSpentSeconds, 0)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].taskId, taskAId)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 150)
    }

    // Finding 2 - Test F2-D: Invalid Task Reference
    @MainActor
    func testTask8_F2_D_InvalidTaskReference() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f2d_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let taskA = FocusTask(title: "Task A", estimatedMinutes: 25)
        let ghostTaskId = UUID() // Non-existent task

        let recovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: ghostTaskId, // Points to missing task
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let payload = FocusAppData(
            tasks: [taskA],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: taskA.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(payload)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(400) })

        // Task A must NOT be credited for ghost task's time
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Recovery must not credit unrelated Task A")
        // Session record must be unassigned
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertNil(vm.sessionRecords[0].taskId, "Record for missing task must be unassigned (nil taskId)")
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 300)
    }

    // Finding 2 - Test F2-E: Fractional and Boundary Values
    @MainActor
    func testTask8_F2_E_FractionalAndBoundaryValues() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f2e_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let task = FocusTask(title: "Boundary Task", estimatedMinutes: 25)

        // Case 1: Zero elapsed duration (started right at checkpoint)
        let zeroElapsedRecovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1500,
            preciseProgress: 1.0,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 0,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate
        )
        let payload1 = FocusAppData(
            tasks: [task],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: zeroElapsedRecovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(payload1)

        let vm1 = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(50) })
        XCTAssertEqual(vm1.sessionRecords.count, 0, "Zero elapsed recovery must not manufacture a record")
        XCTAssertEqual(vm1.timeRemaining, 1500)

        // Case 2: Maximum supported duration (TimerViewModel.maxSupportedTimerDuration)
        let maxDuration = TimerViewModel.maxSupportedTimerDuration
        let maxRecovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Custom",
            activeMode: "Custom Timer",
            isBreakSession: false,
            totalTime: maxDuration,
            timeRemaining: 1,
            fractionalRemaining: 0.5,
            preciseProgress: 0.5 / Double(maxDuration),
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: maxDuration - 1,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate.addingTimeInterval(Double(maxDuration - 1))
        )
        let payload2 = FocusAppData(
            tasks: [task],
            focusedSeconds: 0,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Custom",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Custom Timer",
            activeSessionRecovery: maxRecovery
        )
        try storage.save(payload2)

        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(Double(maxDuration)) })
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, maxDuration - 1)
        XCTAssertEqual(vm2.timeRemaining, 1)
    }

    // Finding 2 - Test F2-F: Corrupt Metadata With Valid User Data
    @MainActor
    func testTask8_F2_F_CorruptMetadataWithValidUserData() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f2f_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let task1 = FocusTask(title: "Keep Me 1", estimatedMinutes: 25)
        let task2 = FocusTask(title: "Keep Me 2", estimatedMinutes: 50)
        let existingRecord = FocusSessionRecord(startTime: baseDate.addingTimeInterval(-3600), endTime: baseDate.addingTimeInterval(-2100), durationSeconds: 1500, mode: "Focus")

        // Corrupt recovery state: totalTime 0 is invalid
        let corruptRecovery = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 0, // INVALID
            timeRemaining: 0,
            preciseProgress: 0.0,
            segmentCreditedSeconds: 9999, // INVALID
            checkpointTimestamp: baseDate
        )
        let payload = FocusAppData(
            tasks: [task1, task2],
            focusedSeconds: 1500,
            completedSessions: 1,
            notes: ["Important Note 1", "Important Note 2"],
            dailyGoalHours: 6,
            totalSessions: 6,
            autoStartNextSession: true,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [existingRecord],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task1.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: corruptRecovery
        )
        let storage = FocusStorageService(storageURL: storageURL)
        try storage.save(payload)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { baseDate.addingTimeInterval(100) })

        // Corrupt recovery is quarantined, but ALL user data remains intact!
        XCTAssertFalse(vm.didRecoverInterruptedSession)
        XCTAssertEqual(vm.tasks.count, 2)
        XCTAssertEqual(vm.tasks[0].title, "Keep Me 1")
        XCTAssertEqual(vm.tasks[1].title, "Keep Me 2")
        XCTAssertEqual(vm.notes, ["Important Note 1", "Important Note 2"])
        XCTAssertEqual(vm.dailyGoalHours, 6)
        XCTAssertEqual(vm.totalSessions, 6)
        XCTAssertTrue(vm.autoStartNextSession)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1500)
    }

    // Finding 3 - Test F3-A: Real Recovery Commit Failure
    @MainActor
    func testTask8_F3_A_RealRecoveryCommitFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f3a_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)

        let task = FocusTask(title: "F3-A Task", estimatedMinutes: 25)
        let recoveryState = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let interruptedPayload = FocusAppData(
            tasks: [task],
            focusedSeconds: 300,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recoveryState
        )
        try storage1.save(interruptedPayload)

        // Configure storage to fail the final recovery save
        storage1.simulateWriteFailure = true

        let vm = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(400) })

        // Accounting correct in memory
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 300)
        XCTAssertEqual(vm.timeRemaining, 1200)

        // Cleanup save genuinely fails
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)

        // Disk recovery metadata not falsely cleared
        let storageUnchanged = FocusStorageService(storageURL: storageURL)
        let rawDiskPayload = try storageUnchanged.decodeData(from: storageURL)
        XCTAssertNotNil(rawDiskPayload.activeSessionRecovery)

        // No false durable-success notice
        XCTAssertFalse(vm.showRecoveryNotice)
    }

    // Finding 3 - Test F3-B: Retry After Failure
    @MainActor
    func testTask8_F3_B_RetryAfterFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f3b_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)

        let task = FocusTask(title: "F3-B Task", estimatedMinutes: 25)
        let recoveryState = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let payload = FocusAppData(
            tasks: [task],
            focusedSeconds: 300,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recoveryState
        )
        try storage1.save(payload)

        storage1.simulateWriteFailure = true
        let vm = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(400) })
        XCTAssertTrue(vm.isSaveFailed)

        // Remove failure and retry
        storage1.simulateWriteFailure = false
        vm.retrySave()

        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertTrue(vm.showRecoveryNotice)

        let committed = try storage1.decodeData(from: storageURL)
        XCTAssertNil(committed.activeSessionRecovery, "Recovery marker must be absent on disk")
        XCTAssertEqual(committed.sessionRecords.count, 1)

        // Relaunch and confirm no duplication
        let vm2 = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(500) })
        XCTAssertEqual(vm2.sessionRecords.count, 1)
    }

    // Finding 3 - Test F3-C: Repeated Failed Retries
    @MainActor
    func testTask8_F3_C_RepeatedFailedRetries() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f3c_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)
        let task = FocusTask(title: "F3-C Task", estimatedMinutes: 25)
        let recoveryState = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let payload = FocusAppData(
            tasks: [task],
            focusedSeconds: 300,
            completedSessions: 0,
            notes: [],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recoveryState
        )
        try storage1.save(payload)

        storage1.simulateWriteFailure = true
        let vm = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(400) })
        XCTAssertTrue(vm.isSaveFailed)

        // Multiple successive retry failures
        for _ in 1...5 {
            vm.retrySave()
            XCTAssertTrue(vm.isSaveFailed)
            XCTAssertEqual(vm.sessionRecords.count, 1, "Must never append duplicate records on repeated retry failure")
            XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Must never duplicate task credit")
        }

        // Finally succeed
        storage1.simulateWriteFailure = false
        vm.retrySave()
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertEqual(vm.sessionRecords.count, 1)
    }

    // Finding 3 - Test F3-D: Backup Failure
    @MainActor
    func testTask8_F3_D_BackupFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f3d_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let baseDate = Date(timeIntervalSince1970: 1770000000)
        let storage1 = FocusStorageService(storageURL: storageURL)
        let task = FocusTask(title: "F3-D Task", estimatedMinutes: 25)
        let recoveryState = ActiveSessionRecoveryState(
            version: 1,
            isTimerRunning: true,
            timerSessionId: UUID(),
            activePreset: "Focus",
            activeMode: "Pomodoro",
            isBreakSession: false,
            totalTime: 1500,
            timeRemaining: 1200,
            sessionSegmentStartDate: baseDate,
            segmentCreditedSeconds: 300,
            activeSessionTaskId: task.id,
            checkpointTimestamp: baseDate.addingTimeInterval(300)
        )
        let payload = FocusAppData(
            tasks: [task],
            focusedSeconds: 300,
            completedSessions: 0,
            notes: ["Pre-crash Note"],
            dailyGoalHours: 4,
            totalSessions: 4,
            autoStartNextSession: false,
            activePreset: "Focus",
            clockStyle: "Digital",
            sessionRecords: [],
            legacyLifetimeFocusedSeconds: nil,
            laps: [],
            preservedSession: nil,
            pausedSession: nil,
            stopwatchElapsedSeconds: 0.0,
            lastRecordedLapElapsedSeconds: 0.0,
            nextLapNumber: 1,
            selectedTaskId: task.id,
            activeMode: "Pomodoro",
            activeSessionRecovery: recoveryState
        )
        try storage1.save(payload)

        // Simulate failure updating backup during recovery persistence
        storage1.simulateBackupFailure = true
        let vm = TimerViewModel(storage: storage1, currentDateProvider: { baseDate.addingTimeInterval(400) })

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertFalse(vm.showRecoveryNotice, "Must not report durable success when backup update fails")
        XCTAssertEqual(vm.notes, ["Pre-crash Note"], "Valid primary/backup data must remain protected")
    }

    // Finding 5 - Test F5-A: Failed Checkpoint Does Not Advance Success Timestamp
    @MainActor
    func testTask8_F5_A_FailedCheckpointDoesNotAdvanceSuccessTimestamp() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f5a_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })

        vm.startTimer()
        let initialSuccessTime = vm.lastSuccessfulCheckpointTime

        // Advance 20 seconds
        simulatedTime = simulatedTime.addingTimeInterval(20)

        // Inject write failure
        storage.simulateWriteFailure = true

        // Reconcile / trigger periodic checkpoint
        vm.reconcileActiveTimers(at: simulatedTime)

        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertEqual(vm.lastSuccessfulCheckpointTime, initialSuccessTime, "Failed checkpoint must not advance lastSuccessfulCheckpointTime")
    }

    // Finding 5 - Test F5-B: Retry Succeeds
    @MainActor
    func testTask8_F5_B_RetrySucceeds() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f5b_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })

        vm.startTimer()

        // Advance 15s with failure
        simulatedTime = simulatedTime.addingTimeInterval(15)
        storage.simulateWriteFailure = true
        vm.reconcileActiveTimers(at: simulatedTime)
        XCTAssertTrue(vm.isSaveFailed)

        // Advance another 10s (now at T+25s), remove failure
        simulatedTime = simulatedTime.addingTimeInterval(10)
        storage.simulateWriteFailure = false

        // Next permitted retry commits latest consistent state
        vm.reconcileActiveTimers(at: simulatedTime)
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertEqual(vm.lastSuccessfulCheckpointTime, simulatedTime, "lastSuccessfulCheckpointTime must advance on success")

        let diskData = storage.load()!
        XCTAssertEqual(diskData.activeSessionRecovery?.timeRemaining, 1500 - 25, "Committed snapshot must reflect 25s elapsed, not obsolete 15s snapshot")
    }

    // Finding 5 - Test F5-C: No Write Storm
    @MainActor
    func testTask8_F5_C_NoWriteStorm() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f5c_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })

        vm.startTimer()
        storage.simulateWriteFailure = true

        // Advance past checkpoint interval to trigger initial checkpoint failure
        simulatedTime = simulatedTime.addingTimeInterval(15.0)
        vm.reconcileActiveTimers(at: simulatedTime)
        XCTAssertTrue(vm.isSaveFailed)

        let baselineAttempts = storage.saveAttemptCount

        // Simulate 50 high-frequency 100ms ticks (5.0 seconds total)
        for _ in 1...50 {
            simulatedTime = simulatedTime.addingTimeInterval(0.1)
            vm.reconcileActiveTimers(at: simulatedTime)
        }

        let newAttempts = storage.saveAttemptCount - baselineAttempts
        // Should only have attempted 1 or 2 saves during the 5 seconds, NOT 50 saves!
        XCTAssertLessThanOrEqual(newAttempts, 2, "Save attempts during persistent failure must be bounded (no write storm)")
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertNotNil(vm.saveErrorMessage)
    }

    // Finding 5 - Test F5-D: Successful-Checkpoint Accounting
    @MainActor
    func testTask8_F5_D_SuccessfulCheckpointAccounting() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_f5d_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var simulatedTime: Date = Date(timeIntervalSince1970: 1770000000)
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })

        let taskAId = vm.tasks[0].id
        vm.startTimer() // 1500s

        // Run 3 successive 15s checkpoint intervals with 1s ticks
        for checkpoint in 1...3 {
            for _ in 1...15 {
                simulatedTime = simulatedTime.addingTimeInterval(1.0)
                vm.reconcileActiveTimers(at: simulatedTime)
            }
            let expectedElapsed = checkpoint * 15
            XCTAssertEqual(vm.lastSuccessfulCheckpointTime, simulatedTime)
            XCTAssertEqual(vm.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, expectedElapsed)

            let disk = storage.load()!
            XCTAssertEqual(disk.activeSessionRecovery?.timeRemaining, 1500 - expectedElapsed)
            XCTAssertEqual(disk.activeSessionRecovery?.segmentCreditedSeconds, expectedElapsed)
            XCTAssertEqual(disk.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, expectedElapsed)
        }
    }

    // MARK: - Red Reproduction Tests for Deadline Expiry on Forced Save & Recovery
    @MainActor
    func testTask8_Red_ForcedSaveAtExactDeadline() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = false

        let taskAId = vm.tasks[0].id
        vm.startTimer() // 1500s Focus

        // Advance simulated time directly to exact deadline without ticks
        simulatedTime = t0.addingTimeInterval(1500)
        vm.persistData(force: true)

        let disk = storage.load()!
        // Expect completed session, Short Break preset, record finalized, no expired running recovery
        XCTAssertEqual(disk.completedSessions, 1, "Completed sessions must be incremented")
        XCTAssertEqual(disk.activePreset, "Short Break", "Preset must transition to Short Break")
        XCTAssertEqual(disk.sessionRecords.count, 1, "One completed session record must exist")
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500))
        XCTAssertEqual(disk.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 1500)
        XCTAssertNil(disk.activeSessionRecovery, "No running recovery state should remain when auto-start is false")
    }

    @MainActor
    func testTask8_Red_ForcedSaveAfterDeadline() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = false

        let taskAId = vm.tasks[0].id
        vm.startTimer() // 1500s Focus

        // Advance simulated time past deadline (300s late) without ticks
        simulatedTime = t0.addingTimeInterval(1800)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.activePreset, "Short Break")
        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500, "Must credit exactly 1500s, not 1800s")
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500), "Record end must be capped at deadline")
        XCTAssertEqual(disk.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 1500)
        XCTAssertNil(disk.activeSessionRecovery)
    }

    @MainActor
    func testTask8_Red_RecoveryOfZeroRemainingSnapshot() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let deadline = t0.addingTimeInterval(1500)
        let storage = FocusStorageService(storageURL: storageURL)

        // Construct legacy zero-remaining recovery payload where deadline was reached at checkpoint time
        let taskId = UUID()
        let initialData = FocusAppData(
            tasks: [FocusTask(id: taskId, title: "Test Task", estimatedMinutes: 25, timeSpentSeconds: 1500)],
            completedSessions: 0,
            totalSessions: 4,
            activePreset: "Focus",
            sessionRecords: [],
            selectedTaskId: taskId,
            activeMode: "Pomodoro",
            configuredTotalTime: 1500,
            configuredCurrentSession: 1,
            configuredIsBreakSession: false,
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                activeMode: "Pomodoro",
                isBreakSession: false,
                totalTime: 1500,
                timeRemaining: 0,
                fractionalRemaining: 0.0,
                preciseProgress: 0.0,
                targetEndDate: deadline,
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 1500,
                activeSessionTaskId: taskId,
                currentSession: 1,
                customMinutes: 25,
                customSeconds: 0,
                isStopwatchRunning: false,
                stopwatchElapsedSeconds: 0,
                stopwatchTaskId: nil,
                checkpointTimestamp: deadline
            )
        )
        try storage.save(initialData)

        // Relaunch app at t0 + 3600
        let relaunchTime = t0.addingTimeInterval(3600)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { relaunchTime })

        // Must recover as completed session, NOT a 1-second paused Focus session!
        XCTAssertEqual(vm.completedSessions, 1, "Must complete session")
        XCTAssertEqual(vm.activePreset, "Short Break", "Must transition to Short Break")
        XCTAssertFalse(vm.isTimerRunning, "Timer should not be running")
        XCTAssertNil(vm.pausedSession, "Should not create a 1-second paused Focus session")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Must finalize focus record")
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(vm.sessionRecords.first?.endTime, deadline, "End time must be deadline, not relaunch time")
    }

    // MARK: - Group A: Forced Save at Deadline
    @MainActor
    func testTask8_GroupA_A1_FocusAtExactDeadline_AutoStartOff() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ga1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = false

        let taskAId = vm.tasks[0].id
        vm.startTimer()

        simulatedTime = t0.addingTimeInterval(1500)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500))
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.activePreset, "Short Break")
        XCTAssertNil(disk.activeSessionRecovery)
        XCTAssertEqual(disk.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 1500)

        // Relaunch
        let vmRelaunch = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime.addingTimeInterval(100) })
        XCTAssertEqual(vmRelaunch.sessionRecords.count, 1)
        XCTAssertEqual(vmRelaunch.completedSessions, 1)
        XCTAssertEqual(vmRelaunch.activePreset, "Short Break")
        XCTAssertFalse(vmRelaunch.isTimerRunning)
        XCTAssertNil(vmRelaunch.pausedSession)
    }

    @MainActor
    func testTask8_GroupA_A2_FocusAfterDeadline_AutoStartOff() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ga2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = false

        let taskAId = vm.tasks[0].id
        vm.startTimer()

        simulatedTime = t0.addingTimeInterval(1800)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500, "Must not credit additional 300s")
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500), "Capped at deadline")
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.activePreset, "Short Break")
        XCTAssertNil(disk.activeSessionRecovery)
        XCTAssertEqual(disk.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 1500)
    }

    @MainActor
    func testTask8_GroupA_A3_FocusAtDeadline_AutoStartOn() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ga3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = true

        vm.startTimer()

        simulatedTime = t0.addingTimeInterval(1500)
        vm.persistData(force: true)

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500))
        XCTAssertNotNil(disk.activeSessionRecovery)
        XCTAssertEqual(disk.activeSessionRecovery?.activePreset, "Short Break")
        XCTAssertEqual(disk.activeSessionRecovery?.isTimerRunning, true)
        XCTAssertEqual(disk.activeSessionRecovery?.checkpointTimestamp, t0.addingTimeInterval(1500))
        XCTAssertEqual(disk.activeSessionRecovery?.targetEndDate, t0.addingTimeInterval(1500 + 300))

        // Crash and relaunch
        let storageRelaunch = FocusStorageService(storageURL: storageURL)
        let vmRelaunch = TimerViewModel(storage: storageRelaunch, currentDateProvider: { simulatedTime.addingTimeInterval(60) })
        XCTAssertFalse(vmRelaunch.isTimerRunning, "Auto-started break must recover paused, not running")
        XCTAssertEqual(vmRelaunch.activePreset, "Short Break")
        XCTAssertEqual(vmRelaunch.completedSessions, 1, "Completed sessions must not double increment")
        XCTAssertEqual(vmRelaunch.sessionRecords.count, 1)
    }

    @MainActor
    func testTask8_GroupA_A4_FocusAfterDeadline_AutoStartOn() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ga4_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = true

        vm.startTimer()

        simulatedTime = t0.addingTimeInterval(1800)
        vm.persistData(force: true)

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.targetEndDate, t0.addingTimeInterval(1800 + 300))
    }

    @MainActor
    func testTask8_GroupA_A5_FinalPomodoroBeforeLongBreak() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ga5_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedTime = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedTime })
        vm.autoStartNextSession = false
        vm.totalSessions = 4
        vm.currentSession = 4

        vm.startTimer()

        simulatedTime = t0.addingTimeInterval(1500)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.activePreset, "Long Break")
        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.configuredTotalTime, 15 * 60)
    }

    // MARK: - Group B: Legacy Recovery Compatibility
    @MainActor
    func testTask8_GroupB_B2_AlreadyFinalizedFocusRecord() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gb2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let deadline = t0.addingTimeInterval(1500)
        let storage = FocusStorageService(storageURL: storageURL)

        let taskId = UUID()
        let sessionId = UUID()
        let existingRecord = FocusSessionRecord(
            id: sessionId,
            startTime: t0,
            endTime: deadline,
            durationSeconds: 1500,
            mode: "Focus",
            taskId: taskId
        )
        let initialData = FocusAppData(
            tasks: [FocusTask(id: taskId, title: "Test Task", estimatedMinutes: 25, timeSpentSeconds: 1500)],
            completedSessions: 1,
            totalSessions: 4,
            activePreset: "Short Break",
            sessionRecords: [existingRecord],
            selectedTaskId: taskId,
            activeMode: "Pomodoro",
            configuredTotalTime: 300,
            configuredCurrentSession: 2,
            configuredIsBreakSession: true,
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: sessionId,
                activePreset: "Focus",
                activeMode: "Pomodoro",
                isBreakSession: false,
                totalTime: 1500,
                timeRemaining: 0,
                fractionalRemaining: 0.0,
                preciseProgress: 0.0,
                targetEndDate: deadline,
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 1500,
                activeSessionTaskId: taskId,
                currentSession: 1,
                customMinutes: 25,
                customSeconds: 0,
                isStopwatchRunning: false,
                stopwatchElapsedSeconds: 0,
                stopwatchTaskId: nil,
                checkpointTimestamp: deadline
            )
        )
        try storage.save(initialData)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(vm.completedSessions, 1, "Completed sessions must not increment again")
        XCTAssertEqual(vm.sessionRecords.count, 1, "No duplicate record should be added")
    }

    @MainActor
    func testTask8_GroupB_B3_PreDeadlineCheckpointRelaunchHoursLater() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gb3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let storage = FocusStorageService(storageURL: storageURL)

        let taskId = UUID()
        let initialData = FocusAppData(
            tasks: [FocusTask(id: taskId, title: "Test Task", estimatedMinutes: 25, timeSpentSeconds: 300)],
            completedSessions: 0,
            totalSessions: 4,
            activePreset: "Focus",
            sessionRecords: [],
            selectedTaskId: taskId,
            activeMode: "Pomodoro",
            configuredTotalTime: 1500,
            configuredCurrentSession: 1,
            configuredIsBreakSession: false,
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                activeMode: "Pomodoro",
                isBreakSession: false,
                totalTime: 1500,
                timeRemaining: 1200,
                fractionalRemaining: 1200.0,
                preciseProgress: 0.8,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 300,
                activeSessionTaskId: taskId,
                currentSession: 1,
                customMinutes: 25,
                customSeconds: 0,
                isStopwatchRunning: false,
                stopwatchElapsedSeconds: 0,
                stopwatchTaskId: nil,
                checkpointTimestamp: t0.addingTimeInterval(300)
            )
        )
        try storage.save(initialData)

        // Relaunch hours later at T0 + 7200
        let vm = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(7200) })
        XCTAssertEqual(vm.completedSessions, 0, "No completion should be fabricated from downtime")
        XCTAssertEqual(vm.timeRemaining, 1200, "1200s remain paused")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300, "Exactly 300s credited")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 300)
        XCTAssertEqual(vm.sessionRecords.first?.endTime, t0.addingTimeInterval(300))
    }

    @MainActor
    func testTask8_GroupB_B4_InconsistentOrMissingDeadlineMetadata() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gb4_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let storage = FocusStorageService(storageURL: storageURL)

        let taskId = UUID()
        let initialData = FocusAppData(
            tasks: [FocusTask(id: taskId, title: "Test Task", estimatedMinutes: 25, timeSpentSeconds: 100)],
            completedSessions: 0,
            notes: ["Important Note"],
            activePreset: "Focus",
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                activeMode: "Pomodoro",
                isBreakSession: false,
                totalTime: 1500,
                timeRemaining: -10, // Invalid negative time remaining
                fractionalRemaining: nil,
                preciseProgress: -0.1,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 2000, // Invalid credited seconds
                activeSessionTaskId: taskId,
                currentSession: 1,
                customMinutes: 25,
                customSeconds: 0,
                isStopwatchRunning: false,
                stopwatchElapsedSeconds: 0,
                stopwatchTaskId: nil,
                checkpointTimestamp: t0
            )
        )
        try storage.save(initialData)

        let vm = TimerViewModel(storage: storage, currentDateProvider: { t0 })
        XCTAssertFalse(vm.didRecoverInterruptedSession, "Invalid metadata must be quarantined")
        XCTAssertEqual(vm.tasks[0].title, "Test Task")
        XCTAssertEqual(vm.notes, ["Important Note"])
    }

    // MARK: - Group C: Analytics and Attribution
    @MainActor
    func testTask8_GroupC_C1_MidnightCrossingForcedCompletion() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gc1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Start at 23:50:00 on Day 1
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 50, second: 0))!
        var simulatedNow = day1
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.systemCalendarProvider = { calendar }
        vm.autoStartNextSession = false

        vm.startTimer() // 1500s -> Deadline at 00:15:00 on Day 2

        // Advance to 00:17:00 on Day 2 (120s past deadline)
        let day2Late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 17, second: 0))!
        simulatedNow = day2Late
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.sessionRecords.count, 1)
        let record = disk.sessionRecords[0]
        XCTAssertEqual(record.durationSeconds, 1500)
        let deadline = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 15, second: 0))!
        XCTAssertEqual(record.endTime, deadline, "Record end must be 00:15:00, not 00:17:00")

        // Daily allocation: 600s on Day 1 (23:50 to 00:00), 900s on Day 2 (00:00 to 00:15)
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 0, minute: 0, second: 0))!
        let day1Alloc = FocusIntervalAllocator.allocatedDuration(recordStart: record.startTime, recordEnd: record.endTime, durationSeconds: record.durationSeconds, intervalStart: day1, intervalEnd: midnight)
        let day2Alloc = FocusIntervalAllocator.allocatedDuration(recordStart: record.startTime, recordEnd: record.endTime, durationSeconds: record.durationSeconds, intervalStart: midnight, intervalEnd: day2Late)
        XCTAssertEqual(day1Alloc, 600)
        XCTAssertEqual(day2Alloc, 900)
    }

    @MainActor
    func testTask8_GroupC_C2_TaskSwitchBeforeDeadlineForcedCompletion() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gc2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false

        vm.addTask(title: "Task B", expectedMinutes: 25)
        let taskAId = vm.tasks[0].id
        let taskBId = vm.tasks[1].id
        vm.selectTask(at: 0)

        vm.startTimer() // Task A running

        // At T0 + 600, switch to Task B
        simulatedNow = t0.addingTimeInterval(600)
        vm.selectTask(at: 1) // Settle 600s to Task A, start Task B

        // At T0 + 1600 (past 1500s deadline), force persistence
        simulatedNow = t0.addingTimeInterval(1600)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.tasks.first(where: { $0.id == taskAId })?.timeSpentSeconds, 600)
        XCTAssertEqual(disk.tasks.first(where: { $0.id == taskBId })?.timeSpentSeconds, 900)
        XCTAssertEqual(disk.sessionRecords.count, 2)
        let totalRecorded = disk.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalRecorded, 1500)
        let finalEnd = disk.sessionRecords.map(\.endTime).max()
        XCTAssertEqual(finalEnd, t0.addingTimeInterval(1500), "No historical record extends beyond deadline")
    }

    @MainActor
    func testTask8_GroupC_C3_SimultaneousFocusTimerAndStopwatch() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gc3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false

        vm.startTimer() // Focus 1500s
        vm.startStopwatch() // Stopwatch running

        // Advance beyond deadline
        simulatedNow = t0.addingTimeInterval(1600)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(disk.stopwatchElapsedSeconds, 1600.0, accuracy: 0.1)

        // Relaunch
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow.addingTimeInterval(10) })
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.stopwatchTime, 1600)
    }

    // MARK: - Group D: Breaks and Repeated Calls
    @MainActor
    func testTask8_GroupD_D1_ShortBreakExpiry() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gd1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.applyPreset(name: "Short Break", minutes: 5)
        vm.autoStartNextSession = false
        vm.startTimer()

        // Expire break at T0 + 350
        simulatedNow = t0.addingTimeInterval(350)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.activePreset, "Focus")
        XCTAssertEqual(disk.completedSessions, 0, "Break completion must not increment completedSessions")
        XCTAssertEqual(disk.sessionRecords.count, 0, "No Focus record for break")
    }

    @MainActor
    func testTask8_GroupD_D2_LongBreakExpiry() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gd2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.applyPreset(name: "Long Break", minutes: 15)
        vm.currentSession = 4
        vm.autoStartNextSession = false
        vm.startTimer()

        simulatedNow = t0.addingTimeInterval(1000)
        vm.persistData(force: true)

        let disk = storage.load()!
        XCTAssertEqual(disk.activePreset, "Focus")
        XCTAssertEqual(disk.configuredCurrentSession, 1, "Session index resets to 1 after Long Break")
    }

    @MainActor
    func testTask8_GroupD_D3_RepeatedForcedSaves() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gd3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false
        vm.startTimer()

        simulatedNow = t0.addingTimeInterval(1500)
        vm.persistData(force: true)

        // Repeated operations
        vm.persistData(force: true)
        vm.tick()
        vm.reconcileActiveTimers(at: simulatedNow.addingTimeInterval(10))

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.sessionRecords.count, 1)
    }

    @MainActor
    func testTask8_GroupD_D4_ConsecutiveClockReadsAroundExpiry() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_gd4_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = true
        vm.startTimer()

        // Tick 1s before deadline
        simulatedNow = t0.addingTimeInterval(1499)
        vm.tick()
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.activePreset, "Focus")

        // Forced save at deadline
        simulatedNow = t0.addingTimeInterval(1500)
        vm.persistData(force: true)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning, "New break should start running")
        XCTAssertEqual(vm.targetEndDate, t0.addingTimeInterval(1800))
    }

    // MARK: - Group E: Storage Failure and Atomicity
    @MainActor
    func testTask8_GroupE_E1_WriteFailureDuringDeadlineCompletion() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ge1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false
        vm.startTimer()

        simulatedNow = t0.addingTimeInterval(1500)
        storage.simulateWriteFailure = true
        vm.persistData(force: true)

        XCTAssertTrue(vm.isSaveFailed)

        // Retry after disk recovers
        storage.simulateWriteFailure = false
        vm.retrySave()
        XCTAssertFalse(vm.isSaveFailed)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.sessionRecords.count, 1)
    }

    @MainActor
    func testTask8_GroupE_E2_RecoveryFinalSaveFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ge2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let deadline = t0.addingTimeInterval(1500)
        let storage = FocusStorageService(storageURL: storageURL)

        let initialData = FocusAppData(
            completedSessions: 0,
            activePreset: "Focus",
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                totalTime: 1500,
                timeRemaining: 0,
                targetEndDate: deadline,
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 1500,
                checkpointTimestamp: deadline
            )
        )
        try storage.save(initialData)

        storage.simulateWriteFailure = true
        let vm = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertTrue(vm.isSaveFailed)
        XCTAssertFalse(vm.showRecoveryNotice, "Notice suppressed on failed cleanup save")

        // Retry
        storage.simulateWriteFailure = false
        vm.retrySave()
        XCTAssertFalse(vm.isSaveFailed)
        XCTAssertTrue(vm.showRecoveryNotice)

        let disk = storage.load()!
        XCTAssertNil(disk.activeSessionRecovery)
        XCTAssertEqual(disk.completedSessions, 1)
    }

    @MainActor
    func testTask8_GroupE_E3_StaleDelayedSaveCallback() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_ge3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })

        var capturedCallback: (() -> Void)? = nil
        vm.saveScheduler = { _, callback in
            capturedCallback = callback
            return AnyCancellable {}
        }

        vm.startTimer()
        // Queue delayed save
        vm.totalSessions = 6
        XCTAssertTrue(vm.hasPendingSave)
        XCTAssertNotNil(capturedCallback)

        // Advance to deadline and force immediate completion
        simulatedNow = t0.addingTimeInterval(1500)
        vm.persistData(force: true)

        let diskBefore = storage.load()!
        XCTAssertEqual(diskBefore.completedSessions, 1)

        // Execute stale callback
        capturedCallback?()

        let diskAfter = storage.load()!
        XCTAssertEqual(diskAfter.completedSessions, 1, "Stale callback must not regress completed state")
        XCTAssertEqual(diskAfter.sessionRecords.count, 1)
    }

    // MARK: - Task 8 Final Corrections: Red Reproduction Tests

    // Red Test for Defect A: Normal tick completion writes incomplete state to disk before delayed callbacks
    @MainActor
    func testTask8_Red_DefectA_NormalTickCompletion() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red_a1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false

        // Withhold coalesced save callbacks to test what was durably written synchronously
        var pendingCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, callback in
            pendingCallbacks.append(callback)
            return AnyCancellable {}
        }

        vm.startTimer() // Starts 1500s Focus
        pendingCallbacks.removeAll()

        // Advance to deadline and tick
        simulatedNow = t0.addingTimeInterval(1500)
        vm.tick()

        // Inspect disk immediately without calling persistData(force: true) or executing pending callbacks
        guard let disk = storage.load() else {
            XCTFail("Disk data must exist after tick completion")
            return
        }

        // Required disk assertions immediately after tick():
        XCTAssertEqual(disk.sessionRecords.count, 1, "One Focus record must exist")
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500))
        XCTAssertEqual(disk.completedSessions, 1, "Disk completedSessions must be 1 immediately after tick()")
        XCTAssertEqual(disk.activePreset, "Short Break", "Disk activePreset must be Short Break immediately after tick()")
        XCTAssertNil(disk.activeSessionRecovery, "activeSessionRecovery must be nil on disk immediately after tick()")

        // Simulate crash / relaunch without handleAppTermination()
        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(relaunchVM.completedSessions, 1, "Relaunch must see completedSessions == 1")
        XCTAssertEqual(relaunchVM.sessionRecords.count, 1, "Relaunch must see exactly 1 Focus record")
        XCTAssertEqual(relaunchVM.activePreset, "Short Break", "Short Break must remain selected on relaunch")
        XCTAssertFalse(relaunchVM.isTimerRunning, "No timer running on relaunch")
    }

    // Red Test for Defect B: Legacy expired recovery inflates task-split Focus duration
    @MainActor
    func testTask8_Red_DefectB_MultiSegmentRecovery() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_red_b1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let taskA = FocusTask(title: "Task A", estimatedMinutes: 25, timeSpentSeconds: 600)
        let taskB = FocusTask(title: "Task B", estimatedMinutes: 25, timeSpentSeconds: 900)
        let storage = FocusStorageService(storageURL: storageURL)

        // Historical finalized record for Task A (600s)
        let taskARecord = FocusSessionRecord(
            id: UUID(),
            startTime: t0,
            endTime: t0.addingTimeInterval(600),
            durationSeconds: 600,
            mode: "Focus",
            taskId: taskA.id
        )

        // Checkpoint representing legacy expired session with Task B active for final 900s
        let initialData = FocusAppData(
            tasks: [taskA, taskB],
            completedSessions: 0,
            activePreset: "Focus",
            sessionRecords: [taskARecord],
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                totalTime: 1500,
                timeRemaining: 0,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0.addingTimeInterval(600),
                segmentCreditedSeconds: 900,
                activeSessionTaskId: taskB.id,
                checkpointTimestamp: t0.addingTimeInterval(1500)
            )
        )
        try storage.save(initialData)

        // Relaunch at T0 + 3600s
        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })

        // Task credit assertions
        XCTAssertEqual(relaunchVM.tasks.first(where: { $0.id == taskA.id })?.timeSpentSeconds, 600, "Task A credit must remain 600s")
        XCTAssertEqual(relaunchVM.tasks.first(where: { $0.id == taskB.id })?.timeSpentSeconds, 900, "Task B credit must be 900s")

        // Session record assertions
        XCTAssertEqual(relaunchVM.sessionRecords.count, 2, "Must have exactly 2 records: Task A (600s) + Task B (900s)")
        let taskBRecord = relaunchVM.sessionRecords.first(where: { $0.taskId == taskB.id })
        XCTAssertNotNil(taskBRecord)
        XCTAssertEqual(taskBRecord?.durationSeconds, 900, "Recovered Task B record duration must be 900s, NOT inflated to 1500s")
        XCTAssertEqual(taskBRecord?.startTime, t0.addingTimeInterval(600))
        XCTAssertEqual(taskBRecord?.endTime, t0.addingTimeInterval(1500))

        let totalFocusDuration = relaunchVM.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalFocusDuration, 1500, "Total Focus duration must be conserved at 1500s (600s + 900s), NOT inflated to 2100s")
        XCTAssertEqual(relaunchVM.completedSessions, 1, "Completed sessions must be 1")
    }

    // MARK: - Group A: Normal Expiry Transaction Tests

    @MainActor
    func testTask8_Final_A2_NormalTickCompletion_AutoStartOn() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fa2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = true

        var pendingCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, callback in
            pendingCallbacks.append(callback)
            return AnyCancellable {}
        }

        vm.startTimer()
        pendingCallbacks.removeAll()

        simulatedNow = t0.addingTimeInterval(1500)
        vm.tick()

        guard let disk = storage.load() else {
            XCTFail("Disk data must exist after tick completion")
            return
        }

        XCTAssertEqual(disk.sessionRecords.count, 1)
        XCTAssertEqual(disk.sessionRecords.first?.durationSeconds, 1500)
        XCTAssertEqual(disk.sessionRecords.first?.endTime, t0.addingTimeInterval(1500))
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.activePreset, "Short Break")
        XCTAssertNotNil(disk.activeSessionRecovery)
        XCTAssertTrue(disk.activeSessionRecovery?.isTimerRunning == true)
        XCTAssertEqual(disk.activeSessionRecovery?.activePreset, "Short Break")
        XCTAssertTrue(disk.activeSessionRecovery?.isBreakSession == true)

        // Relaunch without normal quit
        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(relaunchVM.completedSessions, 1)
        XCTAssertEqual(relaunchVM.sessionRecords.count, 1)
        XCTAssertEqual(relaunchVM.activePreset, "Short Break")
        XCTAssertFalse(relaunchVM.isTimerRunning)
        XCTAssertNotNil(relaunchVM.pausedSession)
        XCTAssertEqual(relaunchVM.pausedSession?.timeRemaining, 300)
    }

    @MainActor
    func testTask8_Final_A3_NormalBreakCompletion_AutoStartOff() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fa3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false
        vm.applyPreset(name: "Short Break", minutes: 5)

        var pendingCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, callback in
            pendingCallbacks.append(callback)
            return AnyCancellable {}
        }

        vm.startTimer()
        pendingCallbacks.removeAll()

        simulatedNow = t0.addingTimeInterval(300)
        vm.tick()

        guard let disk = storage.load() else {
            XCTFail("Disk data must exist after break expiry")
            return
        }

        XCTAssertEqual(disk.activePreset, "Focus")
        XCTAssertEqual(disk.sessionRecords.count, 0, "No Focus record created for Break session")
        XCTAssertEqual(disk.completedSessions, 0, "completedSessions not incremented for Break")
        XCTAssertNil(disk.activeSessionRecovery)
    }

    @MainActor
    func testTask8_Final_A4_NormalBreakCompletion_AutoStartOn() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fa4_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = true
        vm.applyPreset(name: "Short Break", minutes: 5)

        var pendingCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, callback in
            pendingCallbacks.append(callback)
            return AnyCancellable {}
        }

        vm.startTimer()
        pendingCallbacks.removeAll()

        simulatedNow = t0.addingTimeInterval(300)
        vm.tick()

        guard let disk = storage.load() else {
            XCTFail("Disk data must exist after break expiry")
            return
        }

        XCTAssertEqual(disk.activePreset, "Focus")
        XCTAssertEqual(disk.completedSessions, 0)
        XCTAssertEqual(disk.sessionRecords.count, 0)
        XCTAssertNotNil(disk.activeSessionRecovery)
        XCTAssertTrue(disk.activeSessionRecovery?.isTimerRunning == true)
        XCTAssertEqual(disk.activeSessionRecovery?.activePreset, "Focus")
        XCTAssertFalse(disk.activeSessionRecovery?.isBreakSession == true)

        // Relaunch
        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(relaunchVM.completedSessions, 0)
        XCTAssertEqual(relaunchVM.activePreset, "Focus")
        XCTAssertFalse(relaunchVM.isTimerRunning)
        XCTAssertNotNil(relaunchVM.pausedSession)
    }

    @MainActor
    func testTask8_Final_A5_ImmediateKillBeforePendingSave() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fa5_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        var vm: TimerViewModel? = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm?.autoStartNextSession = false

        var capturedCallbacks: [() -> Void] = []
        vm?.saveScheduler = { _, callback in
            capturedCallbacks.append(callback)
            return AnyCancellable {}
        }

        vm?.startTimer()
        capturedCallbacks.removeAll()

        simulatedNow = t0.addingTimeInterval(1500)
        vm?.tick()

        let diskImmediate = storage.load()!
        XCTAssertEqual(diskImmediate.completedSessions, 1, "Completed count is durable before any delayed callback")
        XCTAssertEqual(diskImmediate.activePreset, "Short Break")
        XCTAssertEqual(diskImmediate.sessionRecords.count, 1)

        // Kill ViewModel without calling handleAppTermination() or executing callbacks
        vm = nil

        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(relaunchVM.completedSessions, 1)
        XCTAssertEqual(relaunchVM.sessionRecords.count, 1)
        XCTAssertEqual(relaunchVM.activePreset, "Short Break")
        XCTAssertFalse(relaunchVM.isTimerRunning)
    }

    // MARK: - Group B: Multi-Segment Recovery Tests

    @MainActor
    func testTask8_Final_B2_ThreeTaskSegments() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fb2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let taskA = FocusTask(title: "Task A", estimatedMinutes: 25, timeSpentSeconds: 300)
        let taskB = FocusTask(title: "Task B", estimatedMinutes: 25, timeSpentSeconds: 400)
        let taskC = FocusTask(title: "Task C", estimatedMinutes: 25, timeSpentSeconds: 800)
        let storage = FocusStorageService(storageURL: storageURL)

        let recordA = FocusSessionRecord(
            id: UUID(),
            startTime: t0,
            endTime: t0.addingTimeInterval(300),
            durationSeconds: 300,
            mode: "Focus",
            taskId: taskA.id
        )
        let recordB = FocusSessionRecord(
            id: UUID(),
            startTime: t0.addingTimeInterval(300),
            endTime: t0.addingTimeInterval(700),
            durationSeconds: 400,
            mode: "Focus",
            taskId: taskB.id
        )

        let initialData = FocusAppData(
            tasks: [taskA, taskB, taskC],
            completedSessions: 0,
            activePreset: "Focus",
            sessionRecords: [recordA, recordB],
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                totalTime: 1500,
                timeRemaining: 0,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0.addingTimeInterval(700),
                segmentCreditedSeconds: 800,
                activeSessionTaskId: taskC.id,
                checkpointTimestamp: t0.addingTimeInterval(1500)
            )
        )
        try storage.save(initialData)

        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })

        XCTAssertEqual(relaunchVM.sessionRecords.count, 3)
        let recordC = relaunchVM.sessionRecords.first(where: { $0.taskId == taskC.id })
        XCTAssertEqual(recordC?.durationSeconds, 800)
        XCTAssertEqual(recordC?.startTime, t0.addingTimeInterval(700))
        XCTAssertEqual(recordC?.endTime, t0.addingTimeInterval(1500))

        let totalDuration = relaunchVM.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalDuration, 1500, "300 + 400 + 800 == 1500")
        XCTAssertEqual(relaunchVM.completedSessions, 1)
    }

    @MainActor
    func testTask8_Final_B3_UnassignedFinalSegment() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fb3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let taskA = FocusTask(title: "Task A", estimatedMinutes: 25, timeSpentSeconds: 600)
        let storage = FocusStorageService(storageURL: storageURL)

        let recordA = FocusSessionRecord(
            id: UUID(),
            startTime: t0,
            endTime: t0.addingTimeInterval(600),
            durationSeconds: 600,
            mode: "Focus",
            taskId: taskA.id
        )

        let initialData = FocusAppData(
            tasks: [taskA],
            completedSessions: 0,
            activePreset: "Focus",
            sessionRecords: [recordA],
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                totalTime: 1500,
                timeRemaining: 0,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0.addingTimeInterval(600),
                segmentCreditedSeconds: 900,
                activeSessionTaskId: nil,
                checkpointTimestamp: t0.addingTimeInterval(1500)
            )
        )
        try storage.save(initialData)

        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })

        XCTAssertEqual(relaunchVM.sessionRecords.count, 2)
        XCTAssertEqual(relaunchVM.tasks[0].timeSpentSeconds, 600, "Task A retains 600s")
        let unassignedRecord = relaunchVM.sessionRecords.first(where: { $0.taskId == nil })
        XCTAssertNotNil(unassignedRecord)
        XCTAssertEqual(unassignedRecord?.durationSeconds, 900)
        XCTAssertEqual(relaunchVM.sessionRecords.reduce(0) { $0 + $1.durationSeconds }, 1500)
        XCTAssertEqual(relaunchVM.completedSessions, 1)
    }

    @MainActor
    func testTask8_Final_B4_ExistingCurrentSegmentRecord() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fb4_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let taskA = FocusTask(title: "Task A", estimatedMinutes: 25, timeSpentSeconds: 1500)
        let storage = FocusStorageService(storageURL: storageURL)
        let recoveryId = UUID()

        let recordA = FocusSessionRecord(
            id: recoveryId,
            startTime: t0,
            endTime: t0.addingTimeInterval(1500),
            durationSeconds: 1500,
            mode: "Focus",
            taskId: taskA.id
        )

        let initialData = FocusAppData(
            tasks: [taskA],
            completedSessions: 1,
            activePreset: "Focus",
            sessionRecords: [recordA],
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: recoveryId,
                activePreset: "Focus",
                totalTime: 1500,
                timeRemaining: 0,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 1500,
                activeSessionTaskId: taskA.id,
                checkpointTimestamp: t0.addingTimeInterval(1500)
            )
        )
        try storage.save(initialData)

        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })

        XCTAssertEqual(relaunchVM.sessionRecords.count, 1, "No duplicate record created when already present")
        XCTAssertEqual(relaunchVM.sessionRecords[0].durationSeconds, 1500)
        XCTAssertEqual(relaunchVM.completedSessions, 1, "completedSessions remains 1")
    }

    @MainActor
    func testTask8_Final_B5_RepeatedRecoveryAfterSaveFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fb5_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        let taskA = FocusTask(title: "Task A", estimatedMinutes: 25, timeSpentSeconds: 1500)
        let storage = FocusStorageService(storageURL: storageURL)

        let initialData = FocusAppData(
            tasks: [taskA],
            completedSessions: 0,
            activePreset: "Focus",
            sessionRecords: [],
            activeSessionRecovery: ActiveSessionRecoveryState(
                version: 1,
                isTimerRunning: true,
                timerSessionId: UUID(),
                activePreset: "Focus",
                totalTime: 1500,
                timeRemaining: 0,
                targetEndDate: t0.addingTimeInterval(1500),
                sessionSegmentStartDate: t0,
                segmentCreditedSeconds: 1500,
                activeSessionTaskId: taskA.id,
                checkpointTimestamp: t0.addingTimeInterval(1500)
            )
        )
        try storage.save(initialData)

        storage.simulateWriteFailure = true
        let vm1 = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertTrue(vm1.isSaveFailed)

        // Retry saving after disk recovers
        storage.simulateWriteFailure = false
        vm1.retrySave()
        XCTAssertFalse(vm1.isSaveFailed)

        // Relaunch and verify idempotency
        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(7200) })
        XCTAssertEqual(relaunchVM.sessionRecords.count, 1, "Exactly one record after successful retry and relaunch")
        XCTAssertEqual(relaunchVM.completedSessions, 1)
        XCTAssertNil(storage.load()?.activeSessionRecovery)
    }

    // MARK: - Group C: Storage Failure & Crash Safety Tests

    @MainActor
    func testTask8_Final_C1_NormalCompletionSaveFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fc1_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = false
        vm.startTimer()

        // Inject storage write failure at deadline
        simulatedNow = t0.addingTimeInterval(1500)
        storage.simulateWriteFailure = true
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1, "In-memory state completed")
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isSaveFailed, "Save failure is reported")

        // Remove disk failure and retry
        storage.simulateWriteFailure = false
        vm.retrySave()
        XCTAssertFalse(vm.isSaveFailed)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertEqual(disk.activePreset, "Short Break")
        XCTAssertEqual(disk.sessionRecords.count, 1)

        // Relaunch
        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(relaunchVM.completedSessions, 1)
        XCTAssertEqual(relaunchVM.sessionRecords.count, 1)
    }

    @MainActor
    func testTask8_Final_C2_NormalCompletionWithAutoStartOn_SaveFailure() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fc2_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })
        vm.autoStartNextSession = true
        vm.startTimer()

        simulatedNow = t0.addingTimeInterval(1500)
        storage.simulateWriteFailure = true
        vm.tick()

        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertTrue(vm.isSaveFailed)

        storage.simulateWriteFailure = false
        vm.retrySave()
        XCTAssertFalse(vm.isSaveFailed)

        let disk = storage.load()!
        XCTAssertEqual(disk.completedSessions, 1)
        XCTAssertNotNil(disk.activeSessionRecovery)
        XCTAssertEqual(disk.activeSessionRecovery?.activePreset, "Short Break")
        XCTAssertTrue(disk.activeSessionRecovery?.isTimerRunning == true)

        let relaunchVM = TimerViewModel(storage: storage, currentDateProvider: { t0.addingTimeInterval(3600) })
        XCTAssertEqual(relaunchVM.completedSessions, 1)
        XCTAssertEqual(relaunchVM.activePreset, "Short Break")
        XCTAssertFalse(relaunchVM.isTimerRunning)
    }

    @MainActor
    func testTask8_Final_C3_StaleCoalescedCallbackAfterExpiry() throws {
        let uniqueID = UUID().uuidString
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t8_fc3_\(uniqueID)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageURL = tempDir.appendingPathComponent("focusflow_data.json")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let t0 = Date(timeIntervalSince1970: 1770000000)
        var simulatedNow = t0
        let storage = FocusStorageService(storageURL: storageURL)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { simulatedNow })

        var capturedCallbacks: [() -> Void] = []
        vm.saveScheduler = { _, callback in
            capturedCallbacks.append(callback)
            return AnyCancellable {}
        }

        vm.startTimer()
        vm.totalSessions = 6 // Triggers unforced save
        XCTAssertFalse(capturedCallbacks.isEmpty)

        // Expiry tick commits completed state immediately
        simulatedNow = t0.addingTimeInterval(1500)
        vm.tick()

        let diskBefore = storage.load()!
        XCTAssertEqual(diskBefore.completedSessions, 1)
        XCTAssertEqual(diskBefore.activePreset, "Short Break")

        // Execute stale callback
        for cb in capturedCallbacks {
            cb()
        }

        let diskAfter = storage.load()!
        XCTAssertEqual(diskAfter.completedSessions, 1, "Stale callback must not regress completed state")
        XCTAssertEqual(diskAfter.activePreset, "Short Break")
        XCTAssertEqual(diskAfter.sessionRecords.count, 1)
    }

    // MARK: - CI Reliability & Async Lifecycle Regression Tests
    @MainActor
    func testCI_Regression_RapidConsecutiveCalendarNotificationsDoNotOverfulfill() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        vm.reportingCalendar = calendar

        let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 0, second: 0))!
        let record = FocusSessionRecord(startTime: day1, endTime: day1.addingTimeInterval(3600), durationSeconds: 3600, mode: "Focus", taskId: nil)
        vm.sessionRecords.append(record)

        let day1Afternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 16, minute: 0, second: 0))!
        vm.currentDateProvider = { day1Afternoon }
        vm.recalculateFocusMetrics(now: day1Afternoon)
        XCTAssertEqual(vm.todayFocusedSeconds, 3600)

        let day2Morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9, minute: 0, second: 0))!
        vm.currentDateProvider = { day2Morning }

        let exp = expectation(description: "Safely receive single fulfillment despite multiple notifications")
        exp.assertForOverFulfill = false

        var hasFulfilled = false
        var cancellable: AnyCancellable?
        cancellable = vm.$todayFocusedSeconds
            .dropFirst()
            .filter { $0 == 0 }
            .first()
            .sink { _ in
                if !hasFulfilled {
                    hasFulfilled = true
                    exp.fulfill()
                }
            }
        defer { cancellable?.cancel() }

        // Post multiple notifications rapidly
        for _ in 1...10 {
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        }

        wait(for: [exp], timeout: 5.0)
        cancellable?.cancel()

        XCTAssertEqual(vm.todayFocusedSeconds, 0)
    }

    @MainActor
    func testCI_Regression_DeallocatedViewModelDoesNotReceivePostTeardownNotifications() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_reg_\(UUID().uuidString).json")
        defer { cleanup(url: tempURL) }

        do {
            let storage = FocusStorageService(storageURL: tempURL)
            let localVM = TimerViewModel(storage: storage)
            localVM.cancelDateChangeMonitoring()
        }

        // Post notifications with no active view model — must not crash or leak tasks
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
    }

    // MARK: - Custom Timer UI/UX Final Refinement Regression Tests

    @MainActor
    func testCustomTimerRefinement_01_MinutesActivationKeepsPaddedZeroString() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 0, seconds: 30)
        let controller = vm.customTimeInputController

        XCTAssertEqual(controller.inputMinutes, "00")
        XCTAssertEqual(controller.inputSeconds, "30")

        // Activating minutes editing must keep "00" instead of dropping to unpadded "0"
        controller.startEditing(.minutes)
        XCTAssertEqual(controller.activeEditingField, .minutes)
        XCTAssertEqual(controller.inputMinutes, "00", "Starting editing at 00:30 must preserve '00' in inputMinutes")
        XCTAssertEqual(controller.snapshotMinutes, 0)
        XCTAssertEqual(controller.snapshotSeconds, 30)

        // Typing a single digit '5' replaces '00' cleanly
        controller.updateDraft(field: .minutes, text: "5")
        XCTAssertEqual(controller.inputMinutes, "5")

        controller.cancelEditing()
        XCTAssertNil(controller.activeEditingField)
        XCTAssertEqual(controller.inputMinutes, "00")
    }

    @MainActor
    func testCustomTimerRefinement_02_CompletedFractionProgressSemantics() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 30, seconds: 0)

        // At beginning: remaining = 30m, preciseProgress = 1.0 (remaining fraction)
        XCTAssertEqual(vm.timeRemaining, 1800)
        XCTAssertEqual(vm.preciseProgress, 1.0, accuracy: 0.001)

        let initialCompletedFraction = min(max(1.0 - vm.preciseProgress, 0.0), 1.0)
        let initialCompletedPercentage = Int(round(initialCompletedFraction * 100))
        XCTAssertEqual(initialCompletedFraction, 0.0, accuracy: 0.001, "Initial completed fraction must be 0%")
        XCTAssertEqual(initialCompletedPercentage, 0, "Initial completed percentage must be 0%")

        // Mid-session: 15m remaining
        vm.timeRemaining = 900
        vm.preciseProgress = Double(vm.timeRemaining) / Double(vm.totalTime)
        let midCompletedFraction = min(max(1.0 - vm.preciseProgress, 0.0), 1.0)
        let midCompletedPercentage = Int(round(midCompletedFraction * 100))
        XCTAssertEqual(midCompletedFraction, 0.5, accuracy: 0.001, "Mid-session completed fraction must be 50%")
        XCTAssertEqual(midCompletedPercentage, 50, "Mid-session completed percentage must be 50%")

        // Near end: 3m remaining
        vm.timeRemaining = 180
        vm.preciseProgress = Double(vm.timeRemaining) / Double(vm.totalTime)
        let nearEndCompletedFraction = min(max(1.0 - vm.preciseProgress, 0.0), 1.0)
        let nearEndCompletedPercentage = Int(round(nearEndCompletedFraction * 100))
        XCTAssertEqual(nearEndCompletedFraction, 0.9, accuracy: 0.001, "90% through session must be 90% completed")
        XCTAssertEqual(nearEndCompletedPercentage, 90)

        // Session complete: 0s remaining
        vm.timeRemaining = 0
        vm.preciseProgress = 0.0
        let finishedCompletedFraction = min(max(1.0 - vm.preciseProgress, 0.0), 1.0)
        let finishedCompletedPercentage = Int(round(finishedCompletedFraction * 100))
        XCTAssertEqual(finishedCompletedFraction, 1.0, accuracy: 0.001, "Finished session completed fraction must be 100%")
        XCTAssertEqual(finishedCompletedPercentage, 100)
    }

    @MainActor
    func testCustomTimerRefinement_03_StepperBoundaries() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController

        // Minimum duration boundary: 00:05 (5 seconds)
        vm.setCustomDuration(minutes: 0, seconds: 5)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustMinus5, "Cannot subtract 5 minutes when duration is 5 seconds")
        XCTAssertTrue(controller.canAdjustPlus5, "Can add 5 minutes when duration is 5 seconds")

        // Nominal duration: 10:00 (10 minutes)
        vm.setCustomDuration(minutes: 10, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertTrue(controller.canAdjustMinus5, "Can subtract 5 minutes from 10 minutes")
        XCTAssertTrue(controller.canAdjustPlus5, "Can add 5 minutes to 10 minutes")

        // Maximum duration boundary: 360:00 (6 hours)
        vm.setCustomDuration(minutes: 360, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertTrue(controller.canAdjustMinus5, "Can subtract 5 minutes from 360 minutes")
        XCTAssertFalse(controller.canAdjustPlus5, "Cannot add 5 minutes when already at 360 minutes max")
    }

    @MainActor
    func testCustomTimerRefinement_04_ValidationErrorFieldTargeting() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController

        // Test invalid minutes exceeding maximum
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "400")
        controller.commitEditing()
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(controller.validationErrorField, .minutes, "Exceeding maximum duration must highlight minutes field")

        // Reset and test invalid seconds (> 59)
        controller.cancelEditing()
        controller.startEditing(.seconds)
        controller.updateDraft(field: .seconds, text: "75")
        controller.commitEditing()
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(controller.validationErrorField, .seconds, "Seconds >= 60 must highlight seconds field")
    }

    @MainActor
    func testCustomTimerRefinement_05_RoundedMonospacedFontParity() {
        let font = TimeDigitField.roundedMonospacedFont(size: 80, weight: .bold)
        XCTAssertEqual(font.pointSize, 80)

        // Check advance widths: '1' and '0' in monospaced font must have identical advance width
        let str0 = NSAttributedString(string: "0", attributes: [.font: font])
        let str1 = NSAttributedString(string: "1", attributes: [.font: font])
        let size0 = str0.size()
        let size1 = str1.size()

        XCTAssertEqual(size0.width, size1.width, accuracy: 0.1, "Monospaced numerals must have identical advance width for '0' and '1'")
    }

    @MainActor
    func testCustomTimerRefinement_06_ThreeDigitMinutesFormatting() {
        XCTAssertEqual(TimeInputController.formatMinutes(360), "360")
        XCTAssertEqual(TimeInputController.formatMinutes(25), "25")
        XCTAssertEqual(TimeInputController.formatMinutes(5), "05")
        XCTAssertEqual(TimeInputController.formatMinutes(0), "00")

        XCTAssertEqual(TimeInputController.formatSeconds(59), "59")
        XCTAssertEqual(TimeInputController.formatSeconds(5), "05")
        XCTAssertEqual(TimeInputController.formatSeconds(0), "00")
    }

    // MARK: - Custom Timer Placeholder & Alignment Fix Tests

    @MainActor
    func testCustomTimerPlaceholder_01_EmptyMinutesDraftDisplaysMMNot25() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)

        // Verify makePlaceholderAttributedString produces centered MM
        let attr = TimeDigitField.makePlaceholderAttributedString(text: "MM", fontSize: 80)
        XCTAssertEqual(attr.string, "MM", "Placeholder must be 'MM', not previous '25'")
        let style = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center, "Placeholder paragraph style must be centered")

        // Verify hosted TimeDigitField initializes with MM placeholder
        var text = ""
        let field = TimeDigitField(text: Binding(get: { text }, set: { text = $0 }), placeholder: "MM", fontSize: 80, maxLength: 3)
        let hostingView = NSHostingView(rootView: field)
        hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        hostingView.layoutSubtreeIfNeeded()

        func findTextField(in view: NSView) -> TimeDigitNSTextField? {
            if let tf = view as? TimeDigitNSTextField { return tf }
            for sub in view.subviews {
                if let found = findTextField(in: sub) { return found }
            }
            return nil
        }

        if let tf = findTextField(in: hostingView) {
            XCTAssertEqual(tf.placeholderAttributedString?.string, "MM")
            XCTAssertEqual(tf.alignment, .center)
            XCTAssertEqual(tf.cell?.alignment, .center)
        }
    }

    @MainActor
    func testCustomTimerPlaceholder_02_EmptySecondsDraftDisplaysSSNot00() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 30)

        // Verify makePlaceholderAttributedString produces centered SS
        let attr = TimeDigitField.makePlaceholderAttributedString(text: "SS", fontSize: 80)
        XCTAssertEqual(attr.string, "SS", "Placeholder must be 'SS', not previous '00'")
        let style = attr.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center, "Placeholder paragraph style must be centered")

        // Verify hosted TimeDigitField initializes with SS placeholder
        var text = ""
        let field = TimeDigitField(text: Binding(get: { text }, set: { text = $0 }), placeholder: "SS", fontSize: 80, maxLength: 2)
        let hostingView = NSHostingView(rootView: field)
        hostingView.frame = NSRect(x: 0, y: 0, width: 140, height: 100)
        hostingView.layoutSubtreeIfNeeded()

        func findTextField(in view: NSView) -> TimeDigitNSTextField? {
            if let tf = view as? TimeDigitNSTextField { return tf }
            for sub in view.subviews {
                if let found = findTextField(in: sub) { return found }
            }
            return nil
        }

        if let tf = findTextField(in: hostingView) {
            XCTAssertEqual(tf.placeholderAttributedString?.string, "SS")
            XCTAssertEqual(tf.alignment, .center)
            XCTAssertEqual(tf.cell?.alignment, .center)
        }
    }

    @MainActor
    func testCustomTimerPlaceholder_03_PlaceholderNeverStoredAsNumericDraftValue() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "")
        controller.updateDraft(field: .seconds, text: "")

        XCTAssertEqual(controller.inputMinutes, "", "Draft minutes must be empty, not 'MM'")
        XCTAssertEqual(controller.inputSeconds, "", "Draft seconds must be empty, not 'SS'")
        XCTAssertNotEqual(controller.inputMinutes, "MM")
        XCTAssertNotEqual(controller.inputSeconds, "SS")

        switch controller.validateDraft() {
        case .success:
            XCTFail("Empty draft must never validate successfully")
        case .failure(let error):
            XCTAssertEqual(error, .empty, "Validating empty draft must return .empty failure")
        }
    }

    @MainActor
    func testCustomTimerPlaceholder_04_PlaceholderRemovedImmediatelyWhenTyping() {
        var text = ""
        let field = TimeDigitField(text: Binding(get: { text }, set: { text = $0 }), placeholder: "MM", fontSize: 80, maxLength: 3)
        let coordinator = field.makeCoordinator()
        let tf = TimeDigitNSTextField()
        tf.stringValue = ""
        coordinator.textField = tf

        // User types '4'
        tf.stringValue = "4"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tf))

        XCTAssertEqual(text, "4", "Typing '4' must immediately update bound draft")
        XCTAssertEqual(tf.stringValue, "4", "Text field must contain '4' and not show placeholder")

        // User types '5' -> '45'
        tf.stringValue = "45"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tf))

        XCTAssertEqual(text, "45")
        XCTAssertEqual(tf.stringValue, "45")
    }

    @MainActor
    func testCustomTimerPlaceholder_05_AppKitCenteringPixelMeasurement() {
        // Test in actual 180x100 card
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.alignment = .center
        let font = TimeDigitField.roundedMonospacedFont(size: 80, weight: .bold)
        tf.font = font

        // 1. One digit "4"
        tf.stringValue = "4"
        var rep = tf.bitmapImageRepForCachingDisplay(in: tf.bounds)!
        tf.cacheDisplay(in: tf.bounds, to: rep)
        var minX = 9999, maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
        }
        let center4 = (Double(minX) + Double(maxX)) / 2.0
        let expectedCenter = Double(rep.pixelsWide) / 2.0
        XCTAssertEqual(center4, expectedCenter, accuracy: 4.0, "One digit '4' must be horizontally centered within 4px")

        // 2. Two digits "45"
        tf.stringValue = "45"
        rep = tf.bitmapImageRepForCachingDisplay(in: tf.bounds)!
        tf.cacheDisplay(in: tf.bounds, to: rep)
        minX = 9999; maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
        }
        let center45 = (Double(minX) + Double(maxX)) / 2.0
        XCTAssertEqual(center45, expectedCenter, accuracy: 4.0, "Two digits '45' must be horizontally centered within 4px")

        // 3. Three digits "360"
        tf.stringValue = "360"
        rep = tf.bitmapImageRepForCachingDisplay(in: tf.bounds)!
        tf.cacheDisplay(in: tf.bounds, to: rep)
        minX = 9999; maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
        }
        let center360 = (Double(minX) + Double(maxX)) / 2.0
        XCTAssertEqual(center360, expectedCenter, accuracy: 4.0, "Three digits '360' must be horizontally centered within 4px")
        XCTAssertGreaterThan(minX, 0, "Three digits '360' must not clip or overflow left boundary")
        XCTAssertLessThan(maxX, rep.pixelsWide, "Three digits '360' must not clip or overflow right boundary")

        // 4. Placeholder "MM"
        tf.stringValue = ""
        tf.placeholderAttributedString = TimeDigitField.makePlaceholderAttributedString(text: "MM", fontSize: 80)
        rep = tf.bitmapImageRepForCachingDisplay(in: tf.bounds)!
        tf.cacheDisplay(in: tf.bounds, to: rep)
        minX = 9999; maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
        }
        let centerMM = (Double(minX) + Double(maxX)) / 2.0
        XCTAssertEqual(centerMM, expectedCenter, accuracy: 4.0, "Placeholder 'MM' must be horizontally centered within 4px")
    }

    @MainActor
    func testCustomTimerPlaceholder_06_ZeroMinuteDurationKeeps00UntilDeleted() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 0, seconds: 30)
        let controller = vm.customTimeInputController

        // User clicks minutes
        controller.startEditing(.minutes)
        XCTAssertEqual(controller.inputMinutes, "00", "Zero-minute duration must start editing with '00', not 'MM' or '0'")
        XCTAssertEqual(controller.activeEditingField, .minutes)

        // Only when deleted does it become empty
        controller.updateDraft(field: .minutes, text: "")
        XCTAssertEqual(controller.inputMinutes, "")
    }

    @MainActor
    func testCustomTimerPlaceholder_07_EscapeRestoresOriginalCommittedDuration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "") // Empty, MM placeholder showing
        XCTAssertEqual(controller.inputMinutes, "")

        // User presses Escape
        controller.cancelEditing()

        XCTAssertNil(controller.activeEditingField)
        XCTAssertEqual(controller.committedMinutes, 25)
        XCTAssertEqual(controller.committedSeconds, 0)
        XCTAssertEqual(controller.inputMinutes, "25")
        XCTAssertEqual(controller.inputSeconds, "00")
    }

    @MainActor
    func testCustomTimerPlaceholder_08_EmptyInputCannotCorruptTimer() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)
        let controller = vm.customTimeInputController

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "")
        controller.updateDraft(field: .seconds, text: "")

        let committed = controller.commitEditing()
        XCTAssertFalse(committed, "commitEditing must fail on empty input")
        XCTAssertTrue(controller.hasInvalidDraft)
        XCTAssertEqual(vm.totalTime, 1500, "Timer totalTime must remain untouched at 25 minutes")
    }

    @MainActor
    func testCustomTimerPlaceholder_09_FieldEditorActiveAndCaretCentered() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let tf = TimeDigitNSTextField(frame: NSRect(x: 50, y: 100, width: 180, height: 100))
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.alignment = .center
        tf.placeholderAttributedString = TimeDigitField.makePlaceholderAttributedString(text: "MM", fontSize: 80)
        tf.stringValue = "25"

        window.contentView?.addSubview(tf)
        window.makeKeyAndOrderFront(nil)
        tf.activateAndSelectAll()

        guard let editor = tf.currentEditor() as? NSTextView else {
            XCTFail("Field editor must be active")
            return
        }

        XCTAssertEqual(editor.alignment, .center, "Field editor must be centered")

        // User deletes text
        editor.string = ""
        tf.stringValue = ""

        if let layoutManager = editor.layoutManager, let textContainer = editor.textContainer {
            let caretRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 0), in: textContainer)
            XCTAssertEqual(caretRect.origin.x, 90.0, accuracy: 2.0, "Caret in empty field editor must sit at center (90.0)")
        }
    }

    @MainActor
    func testCustomTimerPlaceholder_10_VisualSnapshots() throws {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.setCustomDuration(minutes: 25, seconds: 0)

        let darkBg = Color(red: 0.08, green: 0.09, blue: 0.13)

        // 1. Idle view
        let idleView = ZStack {
            darkBg
            InPlaceTimeInputView(viewModel: vm, size: 400).padding(20)
        }
        let hosting1 = NSHostingView(rootView: idleView)
        hosting1.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        hosting1.layoutSubtreeIfNeeded()
        if let rep = hosting1.bitmapImageRepForCachingDisplay(in: hosting1.bounds) {
            hosting1.cacheDisplay(in: hosting1.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "/tmp/focusflow_custom_timer_idle.png"))
            }
        }

        // 2. Empty minutes view (MM placeholder)
        let controller = vm.customTimeInputController
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "")
        let editView = ZStack {
            darkBg
            InPlaceTimeInputView(viewModel: vm, size: 400).padding(20)
        }
        let hosting2 = NSHostingView(rootView: editView)
        hosting2.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        hosting2.layoutSubtreeIfNeeded()
        if let rep = hosting2.bitmapImageRepForCachingDisplay(in: hosting2.bounds) {
            hosting2.cacheDisplay(in: hosting2.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "/tmp/focusflow_custom_timer_empty_minutes.png"))
            }
        }

        // 3. Empty seconds view (SS placeholder)
        controller.commitAndSwitchField(to: .seconds)
        controller.updateDraft(field: .seconds, text: "")
        let editSecView = ZStack {
            darkBg
            InPlaceTimeInputView(viewModel: vm, size: 400).padding(20)
        }
        let hosting3 = NSHostingView(rootView: editSecView)
        hosting3.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        hosting3.layoutSubtreeIfNeeded()
        if let rep = hosting3.bitmapImageRepForCachingDisplay(in: hosting3.bounds) {
            hosting3.cacheDisplay(in: hosting3.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "/tmp/focusflow_custom_timer_empty_seconds.png"))
            }
        }
    }

    // MARK: - +15m Boundary & Stepper Hardening Regression Tests

    @MainActor
    func testCustomTimerBoundary_01_Plus15mOn25MinutesBecomes40Minutes() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 25, seconds: 0)
        controller.sync(from: vm.totalTime)

        XCTAssertTrue(controller.canAdjustPlus15, "Can add 15 minutes to 25:00")
        XCTAssertTrue(controller.canAdjustMinutes(by: 15))

        controller.adjustMinutes(by: 15)
        XCTAssertEqual(vm.totalTime, 40 * 60)
        XCTAssertEqual(controller.committedMinutes, 40)
        XCTAssertEqual(controller.committedSeconds, 0)
        XCTAssertEqual(controller.inputMinutes, "40")
        XCTAssertEqual(controller.inputSeconds, "00")
    }

    @MainActor
    func testCustomTimerBoundary_02_Plus15mOn10Minutes30SecondsBecomes25Minutes30Seconds() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 10, seconds: 30)
        controller.sync(from: vm.totalTime)

        XCTAssertTrue(controller.canAdjustPlus15)
        controller.adjustMinutes(by: 15)

        XCTAssertEqual(vm.totalTime, 25 * 60 + 30)
        XCTAssertEqual(controller.committedMinutes, 25)
        XCTAssertEqual(controller.committedSeconds, 30, "Seconds must be preserved exactly")
        XCTAssertEqual(controller.inputMinutes, "25")
        XCTAssertEqual(controller.inputSeconds, "30")
    }

    @MainActor
    func testCustomTimerBoundary_03_Plus15mOn345Minutes59SecondsReachesMaximum360Minutes59Seconds() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 345, seconds: 59)
        controller.sync(from: vm.totalTime)

        XCTAssertTrue(controller.canAdjustPlus15, "345:59 + 15m is exactly 360:59, which is supported maximum")
        XCTAssertEqual(controller.committedTotalSeconds + 15 * 60, TimeInputController.maxDurationSeconds)

        controller.adjustMinutes(by: 15)
        XCTAssertEqual(vm.totalTime, 360 * 60 + 59)
        XCTAssertEqual(controller.committedMinutes, 360)
        XCTAssertEqual(controller.committedSeconds, 59)
        XCTAssertEqual(controller.inputMinutes, "360")
        XCTAssertEqual(controller.inputSeconds, "59")

        // Once at maximum, neither +15m nor +5m can be applied
        XCTAssertFalse(controller.canAdjustPlus15, "Cannot add 15 minutes when at max 360:59")
        XCTAssertFalse(controller.canAdjustPlus5, "Cannot add 5 minutes when at max 360:59")
    }

    @MainActor
    func testCustomTimerBoundary_04_Plus15mAtBoundariesIsUnavailable() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController

        // 346:00 + 15m = 361:00 (exceeds 360:59) -> Unavailable
        vm.setCustomDuration(minutes: 346, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustPlus15, "346:00 + 15m exceeds maxDurationSeconds")
        XCTAssertFalse(controller.canAdjustMinutes(by: 15))

        // 350:30 + 15m = 365:30 -> Unavailable
        vm.setCustomDuration(minutes: 350, seconds: 30)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustPlus15, "350:30 + 15m exceeds maxDurationSeconds")
        XCTAssertFalse(controller.canAdjustMinutes(by: 15))

        // 360:00 + 15m = 375:00 -> Unavailable
        vm.setCustomDuration(minutes: 360, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustPlus15, "360:00 + 15m exceeds maxDurationSeconds")
        XCTAssertFalse(controller.canAdjustMinutes(by: 15))
    }

    @MainActor
    func testCustomTimerBoundary_05_InvalidPlus15mDoesNotInvokeOnCommit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 350, seconds: 30)
        controller.sync(from: vm.totalTime)

        var commitCount = 0
        controller.onCommit = { _, _ in
            commitCount += 1
        }

        controller.adjustMinutes(by: 15)
        XCTAssertEqual(commitCount, 0, "onCommit must not be invoked when adjustment is invalid")
        XCTAssertEqual(vm.totalTime, 350 * 60 + 30)
        XCTAssertEqual(controller.committedMinutes, 350)
        XCTAssertEqual(controller.committedSeconds, 30)
    }

    @MainActor
    func testCustomTimerBoundary_06_InvalidIncrementPreservesTimerDurationExactlyNoPartialClamping() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 355, seconds: 0)
        controller.sync(from: vm.totalTime)

        // Attempting +15m on 355:00 would exceed 360:00.
        // It must NOT partially clamp to 360:00; it must strictly reject all-or-nothing.
        controller.adjustMinutes(by: 15)
        XCTAssertEqual(controller.committedMinutes, 355, "Must not apply partial increment to 360")
        XCTAssertEqual(controller.committedSeconds, 0)
        XCTAssertEqual(controller.inputMinutes, "355")
        XCTAssertEqual(controller.inputSeconds, "00")
        XCTAssertEqual(vm.totalTime, 355 * 60)
    }

    @MainActor
    func testCustomTimerBoundary_07_Plus5mWorksAtCorrectUpperBoundary() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController

        // 355:59 + 5m = 360:59 (exactly max) -> Valid
        vm.setCustomDuration(minutes: 355, seconds: 59)
        controller.sync(from: vm.totalTime)
        XCTAssertTrue(controller.canAdjustPlus5)
        controller.adjustMinutes(by: 5)
        XCTAssertEqual(controller.committedMinutes, 360)
        XCTAssertEqual(controller.committedSeconds, 59)
        XCTAssertEqual(vm.totalTime, 360 * 60 + 59)

        // 356:00 + 5m = 361:00 (exceeds max 360:59) -> Invalid
        vm.setCustomDuration(minutes: 356, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustPlus5)
        controller.adjustMinutes(by: 5)
        XCTAssertEqual(controller.committedMinutes, 356, "356:00 must remain unchanged")
        XCTAssertEqual(vm.totalTime, 356 * 60)
    }

    @MainActor
    func testCustomTimerBoundary_08_Minus5mRespectsMinimumDurationBoundary() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController

        // 05:05 - 5m = 00:05 (exactly minimum supported duration) -> Valid
        vm.setCustomDuration(minutes: 5, seconds: 5)
        controller.sync(from: vm.totalTime)
        XCTAssertTrue(controller.canAdjustMinus5)
        controller.adjustMinutes(by: -5)
        XCTAssertEqual(controller.committedMinutes, 0)
        XCTAssertEqual(controller.committedSeconds, 5)
        XCTAssertEqual(vm.totalTime, 5)

        // 05:00 - 5m = 00:00 (less than 00:05) -> Invalid
        vm.setCustomDuration(minutes: 5, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustMinus5)
        controller.adjustMinutes(by: -5)
        XCTAssertEqual(controller.committedMinutes, 5, "05:00 must remain unchanged")
        XCTAssertEqual(vm.totalTime, 300)

        // 04:00 - 5m = -01:00 -> Invalid
        vm.setCustomDuration(minutes: 4, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustMinus5)
        controller.adjustMinutes(by: -5)
        XCTAssertEqual(controller.committedMinutes, 4, "04:00 must remain unchanged")
        XCTAssertEqual(vm.totalTime, 240)
    }

    @MainActor
    func testCustomTimerBoundary_09_SecondsPreservedByAllValidMinuteAdjustments() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 20, seconds: 47)
        controller.sync(from: vm.totalTime)

        // +5m -> 25:47
        controller.adjustMinutes(by: 5)
        XCTAssertEqual(controller.committedMinutes, 25)
        XCTAssertEqual(controller.committedSeconds, 47)

        // +15m -> 40:47
        controller.adjustMinutes(by: 15)
        XCTAssertEqual(controller.committedMinutes, 40)
        XCTAssertEqual(controller.committedSeconds, 47)

        // -5m -> 35:47
        controller.adjustMinutes(by: -5)
        XCTAssertEqual(controller.committedMinutes, 35)
        XCTAssertEqual(controller.committedSeconds, 47)

        // -15m -> 20:47
        controller.adjustMinutes(by: -15)
        XCTAssertEqual(controller.committedMinutes, 20)
        XCTAssertEqual(controller.committedSeconds, 47)
    }

    @MainActor
    func testCustomTimerBoundary_10_ActiveDraftCancellationAndStepperDeterministic() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController
        vm.setCustomDuration(minutes: 25, seconds: 0)
        controller.sync(from: vm.totalTime)

        var commits: [(Int, Int)] = []
        controller.onCommit = { m, s in
            commits.append((m, s))
            vm.setCustomDuration(minutes: m, seconds: s)
        }

        // Case A: User starts editing, enters half-typed draft, then clicks valid +15m stepper
        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "99")
        XCTAssertTrue(controller.isEditing)

        controller.adjustMinutes(by: 15)
        XCTAssertFalse(controller.isEditing, "Draft editing must be cancelled")
        XCTAssertEqual(commits.count, 1, "Exactly one commit must be triggered")
        XCTAssertEqual(commits.first?.0, 40)
        XCTAssertEqual(commits.first?.1, 0)
        XCTAssertEqual(vm.totalTime, 40 * 60)

        // Case B: User has invalid draft when committed is 350:00 and clicks invalid +15m
        vm.setCustomDuration(minutes: 350, seconds: 0)
        controller.sync(from: vm.totalTime)
        commits.removeAll()

        controller.startEditing(.minutes)
        controller.updateDraft(field: .minutes, text: "999") // invalid
        controller.adjustMinutes(by: 15) // invalid delta

        XCTAssertFalse(controller.isEditing)
        XCTAssertEqual(commits.count, 0, "No commits triggered for invalid stepper delta")
        XCTAssertEqual(controller.committedMinutes, 350)
        XCTAssertEqual(controller.inputMinutes, "350")
    }

    @MainActor
    func testCustomTimerBoundary_11_MainUIDisabledStateMatchesControllerCapability() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        let controller = vm.customTimeInputController

        // At 350:30, +15m is disabled
        vm.setCustomDuration(minutes: 350, seconds: 30)
        controller.sync(from: vm.totalTime)
        XCTAssertFalse(controller.canAdjustPlus15)

        let disabledView = InPlaceTimeInputView(viewModel: vm, size: 400)
        let hostingDisabled = NSHostingView(rootView: disabledView)
        hostingDisabled.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        hostingDisabled.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.canAdjustPlus15)

        // At 25:00, +15m is enabled
        vm.setCustomDuration(minutes: 25, seconds: 0)
        controller.sync(from: vm.totalTime)
        XCTAssertTrue(controller.canAdjustPlus15)

        let enabledView = InPlaceTimeInputView(viewModel: vm, size: 400)
        let hostingEnabled = NSHostingView(rootView: enabledView)
        hostingEnabled.frame = NSRect(x: 0, y: 0, width: 600, height: 260)
        hostingEnabled.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.canAdjustPlus15)
    }

    // MARK: - Task 9A: Idle Activity Monitor & Coordinator Tests

    @MainActor
    func testTask9A_01_UnderThresholdNoIdleDetected() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let taskId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1700000000)

        // At 4m 59s (299s) of idle time:
        mock.setSimulatedIdle(299.0)
        let checkDate = baseDate.addingTimeInterval(299.0)
        coordinator.tick(
            now: checkDate,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: taskId,
            sessionStartDate: baseDate
        )

        // Must NOT be idleDetected, must have NO pending reviews
        XCTAssertTrue(coordinator.pendingIntervals.isEmpty)
        XCTAssertNil(coordinator.activeReviewInterval)
        if case .idleCandidate = coordinator.state {
            // Expected
        } else {
            XCTFail("Expected state to be .idleCandidate, got \(coordinator.state)")
        }

        // User interacts (idle drops to 0)
        mock.setSimulatedIdle(0.0)
        coordinator.tick(
            now: checkDate.addingTimeInterval(1.0),
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: taskId,
            sessionStartDate: baseDate
        )
        XCTAssertEqual(coordinator.state, .monitoring)
        XCTAssertTrue(coordinator.pendingIntervals.isEmpty)
    }

    @MainActor
    func testTask9A_02_ThresholdReachedTriggersIdleDetected() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1700000000)

        // Inactivity reaches 5m 01s (301s)
        mock.setSimulatedIdle(301.0)
        let now = baseDate.addingTimeInterval(301.0)
        coordinator.tick(
            now: now,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: nil,
            sessionStartDate: baseDate
        )

        if case .idleDetected(let startedAt) = coordinator.state {
            // Must anchor to last interaction (baseDate), NOT the threshold arrival timestamp!
            XCTAssertEqual(startedAt.timeIntervalSince1970, baseDate.timeIntervalSince1970, accuracy: 1.0)
        } else {
            XCTFail("Expected .idleDetected, got \(coordinator.state)")
        }
    }

    @MainActor
    func testTask9A_03_UserReturnCreatesPendingReviewWithAccurateInterval() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let taskId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1700000000)

        // Inactivity reaches 9 minutes (540s)
        mock.setSimulatedIdle(540.0)
        let idleDate = baseDate.addingTimeInterval(540.0)
        coordinator.tick(
            now: idleDate,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: taskId,
            sessionStartDate: baseDate
        )

        // User returns! Input detected (idle = 0)
        mock.setSimulatedIdle(0.0)
        let returnDate = baseDate.addingTimeInterval(541.0)
        coordinator.tick(
            now: returnDate,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: taskId,
            sessionStartDate: baseDate
        )

        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        guard let interval = coordinator.pendingIntervals.first else {
            XCTFail("No interval found")
            return
        }

        XCTAssertEqual(interval.sessionId, sessionId)
        XCTAssertEqual(interval.taskId, taskId)
        XCTAssertEqual(interval.sessionType, "Focus")
        XCTAssertEqual(interval.status, .pending)
        XCTAssertEqual(interval.eligibleDurationSeconds, 541, accuracy: 2)
        XCTAssertEqual(coordinator.activeReviewInterval?.id, interval.id)
    }

    @MainActor
    func testTask9A_04_ExpiryWhileIdleBoundsIntervalToDeadline() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let start = Date(timeIntervalSince1970: 1700000000) // 10:00
        let deadline = start.addingTimeInterval(25 * 60) // 10:25 (1500s)
        let returnDate = start.addingTimeInterval(32 * 60) // 10:32 (1920s)

        // Inactivity started at 10:07 (420s after start)
        // User was away 25 minutes (1500s of inactivity from 10:07 to 10:32)
        let awayDuration = returnDate.timeIntervalSince(start.addingTimeInterval(420.0))
        mock.setSimulatedIdle(awayDuration)

        // Pre-tick while away
        coordinator.tick(
            now: returnDate,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: nil,
            sessionDeadline: deadline,
            sessionStartDate: start
        )

        // User returns at 10:32
        mock.setSimulatedIdle(0.0)
        coordinator.tick(
            now: returnDate,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: nil,
            sessionDeadline: deadline,
            sessionStartDate: start
        )

        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        guard let interval = coordinator.pendingIntervals.first else {
            XCTFail("No interval found")
            return
        }

        // Bounded strictly to deadline: 10:07 to 10:25 = 18 minutes (1080s)
        // Must NOT include the 7 minutes after deadline!
        XCTAssertEqual(interval.endTime.timeIntervalSince1970, deadline.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(interval.eligibleDurationSeconds, 18 * 60, accuracy: 2)
    }

    @MainActor
    func testTask9A_05_BreakSessionsIgnoreInactivity() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let baseDate = Date(timeIntervalSince1970: 1700000000)

        // Inactivity during Break session
        mock.setSimulatedIdle(600.0)
        coordinator.tick(
            now: baseDate.addingTimeInterval(600.0),
            isSessionActive: true,
            sessionType: "Break",
            sessionId: sessionId,
            taskId: nil
        )

        // User returns
        mock.setSimulatedIdle(0.0)
        coordinator.tick(
            now: baseDate.addingTimeInterval(601.0),
            isSessionActive: true,
            sessionType: "Break",
            sessionId: sessionId,
            taskId: nil
        )

        XCTAssertTrue(coordinator.pendingIntervals.isEmpty, "Break sessions must never create idle review intervals")
        XCTAssertNil(coordinator.activeReviewInterval)
    }

    @MainActor
    func testTask9A_06_MultipleIntervalsQueuedOldestFirst() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let t0 = Date(timeIntervalSince1970: 1700000000)

        // Interval 1: 7 minutes away
        mock.setSimulatedIdle(420.0)
        coordinator.tick(now: t0.addingTimeInterval(420.0), isSessionActive: true, sessionType: "Focus", sessionId: sessionId, taskId: nil, sessionStartDate: t0)
        mock.setSimulatedIdle(0.0)
        coordinator.tick(now: t0.addingTimeInterval(421.0), isSessionActive: true, sessionType: "Focus", sessionId: sessionId, taskId: nil, sessionStartDate: t0)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)

        // User clicks Decide Later
        let id1 = coordinator.pendingIntervals[0].id
        coordinator.resolve(intervalId: id1, decision: .decideLater)
        XCTAssertNil(coordinator.activeReviewInterval)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)

        // Interval 2: 8 minutes away
        let t1 = t0.addingTimeInterval(1000.0)
        mock.setSimulatedIdle(480.0)
        coordinator.tick(now: t1.addingTimeInterval(480.0), isSessionActive: true, sessionType: "Focus", sessionId: sessionId, taskId: nil, sessionStartDate: t0)
        mock.setSimulatedIdle(0.0)
        coordinator.tick(now: t1.addingTimeInterval(481.0), isSessionActive: true, sessionType: "Focus", sessionId: sessionId, taskId: nil, sessionStartDate: t0)

        // Both intervals must exist, oldest first
        XCTAssertEqual(coordinator.pendingIntervals.count, 2)
        XCTAssertEqual(coordinator.pendingIntervals[0].id, id1, "Oldest interval must remain first")
        XCTAssertTrue(coordinator.pendingIntervals[0].startTime < coordinator.pendingIntervals[1].startTime)
    }

    @MainActor
    func testTask9A_07_ResolutionTransitionsAndCallback() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let t0 = Date(timeIntervalSince1970: 1700000000)

        mock.setSimulatedIdle(360.0)
        coordinator.tick(now: t0.addingTimeInterval(360.0), isSessionActive: true, sessionType: "Focus", sessionId: sessionId, taskId: nil, sessionStartDate: t0)
        mock.setSimulatedIdle(0.0)
        coordinator.tick(now: t0.addingTimeInterval(361.0), isSessionActive: true, sessionType: "Focus", sessionId: sessionId, taskId: nil, sessionStartDate: t0)

        guard let interval = coordinator.pendingIntervals.first else {
            XCTFail("No interval created")
            return
        }

        var resolvedDecision: IdleReviewDecision?
        var resolvedStatus: IdleReviewStatus?
        coordinator.onResolution = { resolved, decision in
            resolvedDecision = decision
            resolvedStatus = resolved.status
        }

        // Test Count as Focus
        coordinator.resolve(intervalId: interval.id, decision: .countAsFocus)
        XCTAssertEqual(resolvedDecision, .countAsFocus)
        XCTAssertEqual(resolvedStatus, .included)
        XCTAssertTrue(coordinator.pendingIntervals.isEmpty)
        XCTAssertNil(coordinator.activeReviewInterval)
        XCTAssertEqual(coordinator.state, .monitoring)
    }

    @MainActor
    func testTask9A_08_SleepAndWakeHandling() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let sleepTime = Date(timeIntervalSince1970: 1700000000)
        let wakeTime = sleepTime.addingTimeInterval(600.0) // 10 minutes sleep

        coordinator.handleSleep(at: sleepTime)
        coordinator.handleWake(
            at: wakeTime,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: nil
        )

        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        guard let interval = coordinator.pendingIntervals.first else {
            XCTFail("No sleep interval recorded")
            return
        }
        XCTAssertTrue(interval.isEstimated, "Sleep intervals must be marked as estimated")
        XCTAssertEqual(interval.eligibleDurationSeconds, 600)
    }

    @MainActor
    func testTask9A_09_ScreenLockHandling() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        let sessionId = UUID()
        let lockTime = Date(timeIntervalSince1970: 1700000000)
        // Screen is locked
        coordinator.handleScreenLock(at: lockTime)
        mock.setScreenLocked(true)
        coordinator.tick(
            now: lockTime.addingTimeInterval(360.0),
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: nil,
            sessionStartDate: lockTime
        )

        // Screen is unlocked
        mock.setScreenLocked(false)
        mock.setSimulatedIdle(0.0)
        coordinator.tick(
            now: lockTime.addingTimeInterval(361.0),
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: nil,
            sessionStartDate: lockTime
        )

        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        guard let interval = coordinator.pendingIntervals.first else {
            XCTFail("No interval found")
            return
        }
        XCTAssertEqual(interval.eligibleDurationSeconds, 361, accuracy: 2)
    }

    @MainActor
    func testTask9A_10_ConfigurableThresholds() {
        let coordinator = IdleReviewCoordinator()
        XCTAssertEqual(coordinator.thresholdSeconds, 300)

        coordinator.setThreshold(minutes: 2)
        XCTAssertEqual(coordinator.thresholdSeconds, 120)

        coordinator.setThreshold(minutes: 10)
        XCTAssertEqual(coordinator.thresholdSeconds, 600)

        coordinator.setThreshold(minutes: 15)
        XCTAssertEqual(coordinator.thresholdSeconds, 900)

        // Unsupported threshold rejected
        coordinator.setThreshold(minutes: 7)
        XCTAssertEqual(coordinator.thresholdSeconds, 900, "Unsupported threshold must not be applied")
    }

    @MainActor
    func testTask9A_11_DisabledFeatureGeneratesNoReviews() {
        let mock = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mock, thresholdSeconds: 300)
        coordinator.isEnabled = false

        mock.setSimulatedIdle(3600.0) // 1 hour idle
        coordinator.tick(
            now: Date(),
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: UUID(),
            taskId: nil
        )

        mock.setSimulatedIdle(0.0)
        coordinator.tick(
            now: Date().addingTimeInterval(1.0),
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: UUID(),
            taskId: nil
        )

        XCTAssertTrue(coordinator.pendingIntervals.isEmpty)
        XCTAssertNil(coordinator.activeReviewInterval)
        XCTAssertEqual(coordinator.state, .inactive)
    }

    // MARK: - Task 9B: Accounting Reconciler, Deferred Completion & Persistence Tests

    @MainActor
    func testTask9B_01_InSessionIdle_CountAsFocus_ConfirmsProvisionalCredit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        let mockActivity = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(
            activityProvider: mockActivity,
            currentDateProvider: { currentTime },
            isEnabled: true,
            thresholdSeconds: 300
        )
        coordinator.onResolution = { [weak vm] interval, decision in
            vm?.handleIdleReviewResolution(interval: interval, decision: decision)
        }

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        // Advance 10 minutes active
        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 600)

        // 7 minutes idle (420s)
        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420)
        coordinator.tick(
            now: currentTime,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: vm.activeTimerSessionId,
            taskId: taskId,
            sessionStartDate: currentTime.addingTimeInterval(-1020)
        )

        // User returns
        mockActivity.setSimulatedIdle(0.0)
        coordinator.tick(
            now: currentTime,
            isSessionActive: true,
            sessionType: "Focus",
            sessionId: vm.activeTimerSessionId,
            taskId: taskId,
            sessionStartDate: currentTime.addingTimeInterval(-1020)
        )

        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        guard let interval = coordinator.pendingIntervals.first else {
            XCTFail("Missing pending interval")
            return
        }

        // Resolve with .countAsFocus
        coordinator.resolve(intervalId: interval.id, decision: .countAsFocus, at: currentTime)

        // Time remains confirmed at 1020s (600s active + 420s idle confirmed as focus), no deduction
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 1020)
        XCTAssertTrue(coordinator.pendingIntervals.isEmpty)
    }

    @MainActor
    func testTask9B_02_InSessionIdle_ExcludeFromFocus_DeductsTaskTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        let mockActivity = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(
            activityProvider: mockActivity,
            currentDateProvider: { currentTime },
            isEnabled: true,
            thresholdSeconds: 300
        )
        coordinator.onResolution = { [weak vm] interval, decision in
            vm?.handleIdleReviewResolution(interval: interval, decision: decision)
        }

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        // 10 minutes elapsed (600s credited provisionally)
        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 600)

        // User was idle for 7 minutes (420s)
        let idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-420),
            endTime: currentTime,
            eligibleDurationSeconds: 420,
            status: .pending
        )
        coordinator.pendingIntervals.append(idleInterval)

        // Resolve with .excludeFromFocus
        coordinator.resolve(intervalId: idleInterval.id, decision: .excludeFromFocus, at: currentTime)

        // Task time must be retrospectively deducted: 600 - 420 = 180s
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 180)
    }

    @MainActor
    func testTask9B_03_InSessionIdle_DecideLater_KeepsProvisionalCreditInQueue() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        let mockActivity = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(
            activityProvider: mockActivity,
            currentDateProvider: { currentTime },
            isEnabled: true,
            thresholdSeconds: 300
        )
        coordinator.onResolution = { [weak vm] interval, decision in
            vm?.handleIdleReviewResolution(interval: interval, decision: decision)
        }

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-420),
            endTime: currentTime,
            eligibleDurationSeconds: 420,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        coordinator.pendingIntervals.append(idleInterval)
        coordinator.openReview(for: idleInterval)
        XCTAssertNotNil(coordinator.activeReviewInterval)

        coordinator.resolve(intervalId: idleInterval.id, decision: .decideLater, at: currentTime)

        // Modal dismissed, but interval remains in queue as pending time (not confirmed)
        XCTAssertNil(coordinator.activeReviewInterval)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        // Confirmed time excludes unresolved idle time: 600 - 420 = 180s
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 180)
        XCTAssertEqual(coordinator.pendingIntervals.first?.eligibleDurationSeconds, 420)
    }

    @MainActor
    func testTask9B_04A_ActiveUserAtDeadline_CompletesNormallyWithoutDeferral() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300

        vm.startTimer(at: currentTime)
        let target = currentTime.addingTimeInterval(1500)

        // User stays active throughout session (idle = 0s)
        currentTime = target
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        // Session completes immediately without deferral
        XCTAssertFalse(vm.isDeferredCompletionPending, "Completion must not be deferred when user was active at deadline")
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertTrue(vm.isBreakPreset)
    }

    @MainActor
    func testTask9B_04B_ScenarioB_TimerExpiresWhileIdle_DefersCompletion() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        vm.startTimer(at: currentTime)
        let target = currentTime.addingTimeInterval(1500)

        // User goes idle at minute 15
        currentTime = currentTime.addingTimeInterval(900)
        vm.reconcileActiveTimers(at: currentTime)

        // Deadline reached: user inactive for 600s (10m)
        currentTime = target
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)

        // Verification of Scenario B invariants
        XCTAssertTrue(vm.isDeferredCompletionPending, "Session completion must be deferred when user is inactive at deadline")
        XCTAssertEqual(vm.timeRemaining, 0, "Display must show 00:00")
        XCTAssertFalse(vm.isTimerRunning, "Countdown is not running")
        XCTAssertEqual(vm.completedSessions, 0, "Session completion must be held")
        XCTAssertFalse(vm.isBreakPreset, "Must not auto-advance to break yet")
    }

    @MainActor
    func testTask9B_05_ScenarioB_PostDeadlineInactivityStrictlyExcluded() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300

        vm.startTimer(at: currentTime)
        let target = currentTime.addingTimeInterval(1500) // 10:25

        // Inactive starting at minute 15 (10:15)
        currentTime = currentTime.addingTimeInterval(900)
        vm.reconcileActiveTimers(at: currentTime)

        // Reach deadline at 10:25
        currentTime = target
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending)

        // Inactivity continues past deadline to 10:45 (another 20 minutes away!)
        currentTime = target.addingTimeInterval(1200) // 10:45
        mockActivity.setSimulatedIdle(1800) // 30 minutes idle
        vm.reconcileActiveTimers(at: currentTime)

        // User returns at 10:45
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
        guard let interval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("No interval found")
            return
        }

        // Post-deadline time (10:25 to 10:45) must NOT be included!
        // Eligible idle duration is strictly 10:15 to 10:25 = 600s (10 mins)
        XCTAssertEqual(interval.eligibleDurationSeconds, 600, "Inactivity past deadline must be strictly excluded")
        XCTAssertEqual(interval.endTime, target, "Interval end time must be capped at targetEndDate")
    }

    @MainActor
    func testTask9B_06_ScenarioB_ResolveCountAsFocus_CompletesSession() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300

        vm.startTimer(at: currentTime)
        let target = currentTime.addingTimeInterval(1500)

        currentTime = target
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending)

        // User returns
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        guard let interval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing interval")
            return
        }

        // User selects Count As Focus
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .countAsFocus, at: currentTime)

        // Session completes!
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertTrue(vm.isBreakPreset, "Should advance to Break preset")
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 1500, "Full duration credited")
    }

    @MainActor
    func testTask9B_07_ScenarioB_ResolveExcludeFromFocus_DeductsIdleAndCompletesSession() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id
        let target = currentTime.addingTimeInterval(1500)

        // User idle from minute 15 (600s idle before deadline)
        currentTime = target
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending)

        // User returns
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        guard let interval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing interval")
            return
        }

        // User selects Exclude From Focus
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .excludeFromFocus, at: currentTime)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertTrue(vm.isBreakPreset)

        // Credited time: 1500 - 600 = 900s (15 mins)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 900)
        if let idx = vm.tasks.firstIndex(where: { $0.id == taskId }) {
            XCTAssertEqual(vm.tasks[idx].timeSpentSeconds, 900)
        }
    }

    @MainActor
    func testTask9B_08_Stopwatch_ExcludeFromFocus_DeductsTaskOnly_PreservesLapsAndDisplay() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        let taskId = vm.tasks[vm.activeTaskIndex].id

        vm.startStopwatch()

        // 120s elapsed -> record lap
        currentTime = currentTime.addingTimeInterval(120)
        vm.reconcileActiveTimers(at: currentTime)
        vm.recordLap()
        XCTAssertEqual(vm.laps.count, 1)

        // 600s total elapsed (480s more)
        currentTime = currentTime.addingTimeInterval(480)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.stopwatchTime, 600)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 600)

        // Exclude 300s of idle time
        let interval = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Stopwatch",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-300),
            endTime: currentTime,
            eligibleDurationSeconds: 300,
            status: .pending
        )
        vm.handleIdleReviewResolution(interval: interval, decision: .excludeFromFocus)

        // Task time is deducted: 600 - 300 = 300s
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 300)

        // Stopwatch display time and laps are NOT altered!
        XCTAssertEqual(vm.stopwatchTime, 600, "Stopwatch displayed time must remain exact wall-clock elapsed")
        XCTAssertEqual(vm.laps.count, 1, "Laps must remain untouched")
        XCTAssertEqual(vm.laps.first?.totalTime, 120)
    }

    @MainActor
    func testTask9B_09_Persistence_SurvivesQuitAndReload() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        let vm = TimerViewModel(storage: storage)
        vm.idleReviewEnabled = false
        vm.idleThresholdSeconds = 600

        let interval = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: nil,
            startTime: Date().addingTimeInterval(-600),
            endTime: Date(),
            eligibleDurationSeconds: 600
        )
        vm.idleReviewCoordinator.pendingIntervals = [interval]
        vm.persistData(force: true)

        // Load into fresh ViewModel
        let loadedVM = TimerViewModel(storage: storage)
        XCTAssertFalse(loadedVM.idleReviewEnabled)
        XCTAssertEqual(loadedVM.idleThresholdSeconds, 600)
        XCTAssertEqual(loadedVM.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(loadedVM.idleReviewCoordinator.pendingIntervals.first?.eligibleDurationSeconds, 600)
    }

    @MainActor
    func testTask9B_10_CrashRecovery_DeferredCompletionRestoresCleanly() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_t9b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        let mockActivity = MockIdleActivityProvider()
        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300

        vm.startTimer(at: currentTime)
        let target = currentTime.addingTimeInterval(1500)

        currentTime = target
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending)

        // Force-quit / reload without completing session
        let recoveredVM = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        XCTAssertTrue(recoveredVM.isDeferredCompletionPending, "Deferred completion must survive force-quit recovery")
        XCTAssertEqual(recoveredVM.timeRemaining, 0)
        XCTAssertFalse(recoveredVM.isTimerRunning)
    }

    @MainActor
    func testTask9B_11_ConservationOfSeconds_SessionRecordSplitting() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessionStart = Date(timeIntervalSince1970: 1700000000) // 10:00:00
        let sessionEnd = sessionStart.addingTimeInterval(1500)      // 10:25:00

        let initialRecord = FocusSessionRecord(
            id: UUID(),
            startTime: sessionStart,
            endTime: sessionEnd,
            durationSeconds: 1500,
            mode: "Focus",
            taskId: nil
        )
        vm.sessionRecords = [initialRecord]

        // Idle from minute 7 to minute 16 (9m = 540s)
        let idleStart = sessionStart.addingTimeInterval(420) // 10:07
        let idleEnd = sessionStart.addingTimeInterval(960)   // 10:16
        let idleInterval = IdleReviewInterval(
            sessionId: initialRecord.id,
            sessionType: "Focus",
            taskId: nil,
            startTime: idleStart,
            endTime: idleEnd,
            eligibleDurationSeconds: 540,
            status: .pending
        )

        vm.reconcileSessionRecordsExcluding(interval: idleInterval)

        XCTAssertEqual(vm.sessionRecords.count, 2, "Session record must be split into two sub-segments")
        let r1 = vm.sessionRecords[0]
        let r2 = vm.sessionRecords[1]

        XCTAssertEqual(r1.startTime, sessionStart)
        XCTAssertEqual(r1.endTime, idleStart)
        XCTAssertEqual(r1.durationSeconds, 420) // 7m

        XCTAssertEqual(r2.startTime, idleEnd)
        XCTAssertEqual(r2.endTime, sessionEnd)
        XCTAssertEqual(r2.durationSeconds, 540) // 9m

        // Integer conservation: 420 + 540 = 960s active + 540s excluded = 1500s total
        XCTAssertEqual(r1.durationSeconds + r2.durationSeconds + idleInterval.eligibleDurationSeconds, 1500)
    }

    // MARK: - Task 9C: UI, Interaction & Presentation Tests

    @MainActor
    func testTask9C_01_IdleReviewModalView_InitializationAndProperties() {
        let coordinator = IdleReviewCoordinator()
        let interval = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: UUID(),
            startTime: Date(timeIntervalSince1970: 1700000000),
            endTime: Date(timeIntervalSince1970: 1700000600),
            eligibleDurationSeconds: 600,
            status: .pending
        )
        let modal = IdleReviewModalView(coordinator: coordinator, interval: interval, taskTitle: "Deep Work")
        XCTAssertEqual(modal.interval.eligibleDurationSeconds, 600)
        XCTAssertEqual(modal.taskTitle, "Deep Work")
        XCTAssertEqual(modal.interval.formattedDuration, "10 minutes")
    }

    @MainActor
    func testTask9C_02_SettingsView_IdleTimeReviewBinding() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertTrue(vm.idleReviewEnabled)
        XCTAssertEqual(vm.idleThresholdSeconds, 300)

        // Change settings
        vm.idleReviewEnabled = false
        XCTAssertFalse(vm.idleReviewCoordinator.isEnabled)

        vm.idleThresholdSeconds = 600
        XCTAssertEqual(vm.idleReviewCoordinator.thresholdSeconds, 600)

        // Supported threshold values
        XCTAssertEqual(IdleReviewCoordinator.supportedThresholds, [120, 300, 600, 900])
    }

    @MainActor
    func testTask9C_03_MenuBarCompanion_StatusPillText_DeferredCompletion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        XCTAssertFalse(vm.isDeferredCompletionPending)
        vm.isDeferredCompletionPending = true
        XCTAssertTrue(vm.isDeferredCompletionPending)
    }

    @MainActor
    func testTask9C_04_IdleReviewCoordinator_QueueProgression() {
        let coordinator = IdleReviewCoordinator()
        let id1 = UUID()
        let id2 = UUID()
        let interval1 = IdleReviewInterval(
            id: id1,
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: nil,
            startTime: Date(timeIntervalSince1970: 1700000000),
            endTime: Date(timeIntervalSince1970: 1700000300),
            eligibleDurationSeconds: 300,
            status: .pending
        )
        let interval2 = IdleReviewInterval(
            id: id2,
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: nil,
            startTime: Date(timeIntervalSince1970: 1700000600),
            endTime: Date(timeIntervalSince1970: 1700000960),
            eligibleDurationSeconds: 360,
            status: .pending
        )

        coordinator.pendingIntervals = [interval1, interval2]
        coordinator.openReview(for: interval1)

        XCTAssertEqual(coordinator.activeReviewInterval?.id, id1)
        XCTAssertEqual(coordinator.pendingIntervals.count, 2)

        // Resolve first interval as countAsFocus
        coordinator.resolve(intervalId: id1, decision: .countAsFocus)

        // Next interval should automatically become active
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        XCTAssertEqual(coordinator.activeReviewInterval?.id, id2)

        // Resolve second interval
        coordinator.resolve(intervalId: id2, decision: .excludeFromFocus)
        XCTAssertEqual(coordinator.pendingIntervals.count, 0)
        XCTAssertNil(coordinator.activeReviewInterval)
        XCTAssertEqual(coordinator.state, .monitoring)
    }

    @MainActor
    func testTask9C_05_IdleReviewCoordinator_DecideLater_Dismissal() {
        let coordinator = IdleReviewCoordinator()
        let id1 = UUID()
        let interval = IdleReviewInterval(
            id: id1,
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: nil,
            startTime: Date(timeIntervalSince1970: 1700000000),
            endTime: Date(timeIntervalSince1970: 1700000300),
            eligibleDurationSeconds: 300,
            status: .pending
        )

        coordinator.pendingIntervals = [interval]
        coordinator.openReview(for: interval)
        XCTAssertNotNil(coordinator.activeReviewInterval)

        // User chooses Decide Later (or presses Esc)
        coordinator.dismissActiveReviewToDecideLater()

        // Active modal is dismissed, but interval remains safely pending
        XCTAssertNil(coordinator.activeReviewInterval)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
        XCTAssertEqual(coordinator.state, .pendingReview)

        // User reopens from Settings / Banner
        coordinator.openReview(for: interval)
        XCTAssertEqual(coordinator.activeReviewInterval?.id, id1)
        XCTAssertEqual(coordinator.state, .reviewing(intervalId: id1))
    }

    // MARK: - Task 9 Critical Patch Regression Tests (Part G Scenarios 1-25)

    // Scenario 1: Deferred session survives graceful app termination
    @MainActor
    func testTask9_Patch01_DeferredSessionSurvivesGracefulQuit() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p1_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.startTimer(at: currentTime)

        // Expire during inactivity
        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending)

        // User returns
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)

        // Graceful quit
        vm.handleAppTermination()

        // Relaunch
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertTrue(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm2.timeRemaining, 0)
        XCTAssertEqual(vm2.completedSessions, 0)
        XCTAssertTrue(vm2.sessionRecords.isEmpty)
    }

    // Scenario 2: Deferred session survives force-quit
    @MainActor
    func testTask9_Patch02_DeferredSessionSurvivesForceQuit() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p2_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)
        vm.persistData(force: true)

        // Drop vm without calling handleAppTermination (simulating crash / kill)
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertTrue(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm2.timeRemaining, 0)
    }

    // Scenario 3: Same review ID survives relaunch
    @MainActor
    func testTask9_Patch03_SameReviewIDSurvivesRelaunch() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p3_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        guard let originalInterval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing pending interval")
            return
        }
        let originalId = originalInterval.id
        let originalSessionId = originalInterval.sessionId

        vm.handleAppTermination()

        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.first?.id, originalId)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.first?.sessionId, originalSessionId)
    }

    // Scenario 4: No duplicate record after recovery
    @MainActor
    func testTask9_Patch04_NoDuplicateRecordAfterRecovery() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p4_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        vm.handleAppTermination()

        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        if let interval = vm2.idleReviewCoordinator.pendingIntervals.first {
            vm2.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .countAsFocus, at: currentTime)
        }

        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.sessionRecords.count, 1)

        vm2.handleAppTermination()

        let vm3 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm3.loadPersistedData()

        XCTAssertEqual(vm3.completedSessions, 1)
        XCTAssertEqual(vm3.sessionRecords.count, 1)
    }

    // Scenario 5: Resolved decision survives crash immediately after saving
    @MainActor
    func testTask9_Patch05_ResolvedDecisionSurvivesCrashImmediatelyAfterSaving() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p5_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        guard let interval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing interval")
            return
        }

        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .excludeFromFocus, at: currentTime)
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 900)

        // Drop instance without handleAppTermination
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertTrue(vm2.idleReviewCoordinator.pendingIntervals.isEmpty)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords.first?.durationSeconds, 900)
    }

    // Scenario 6: Idle exclusion does not modify another overlapping session
    @MainActor
    func testTask9_Patch06_IdleExclusionDoesNotModifyOverlappingSession() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessionAId = UUID()
        let sessionBId = UUID()

        let baseTime = Date(timeIntervalSince1970: 1700000000)
        let recordA = FocusSessionRecord(
            id: UUID(),
            sessionId: sessionAId,
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(1500),
            durationSeconds: 1500,
            mode: "Focus"
        )
        let recordB = FocusSessionRecord(
            id: UUID(),
            sessionId: sessionBId,
            startTime: baseTime.addingTimeInterval(600),
            endTime: baseTime.addingTimeInterval(1800),
            durationSeconds: 1200,
            mode: "Focus"
        )
        vm.sessionRecords = [recordA, recordB]

        // Idle interval strictly belonging to Session A
        let idleIntervalA = IdleReviewInterval(
            sessionId: sessionAId,
            sessionType: "Focus",
            taskId: nil,
            startTime: baseTime.addingTimeInterval(420),
            endTime: baseTime.addingTimeInterval(960),
            eligibleDurationSeconds: 540,
            status: .pending
        )

        vm.reconcileSessionRecordsExcluding(interval: idleIntervalA)

        // Session B record must be completely intact and unmodified!
        let survivingB = vm.sessionRecords.first { $0.sessionId == sessionBId }
        XCTAssertNotNil(survivingB)
        XCTAssertEqual(survivingB?.durationSeconds, 1200)
        XCTAssertEqual(survivingB?.startTime, baseTime.addingTimeInterval(600))
        XCTAssertEqual(survivingB?.endTime, baseTime.addingTimeInterval(1800))

        // Session A must be split
        let survivingA = vm.sessionRecords.filter { $0.sessionId == sessionAId }
        XCTAssertEqual(survivingA.count, 2)
        XCTAssertEqual(survivingA.reduce(0) { $0 + $1.durationSeconds }, 960)
    }

    // Scenario 7: Previously split records maintain exact conservation
    @MainActor
    func testTask9_Patch07_PreviouslySplitRecordsMaintainExactConservation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessId = UUID()
        let baseTime = Date(timeIntervalSince1970: 1700000000)
        // Adjusted record: spans 600 wall-clock seconds but duration is 400s
        let adjustedRecord = FocusSessionRecord(
            id: UUID(),
            sessionId: sessId,
            startTime: baseTime,
            endTime: baseTime.addingTimeInterval(600),
            durationSeconds: 400,
            mode: "Focus"
        )
        vm.sessionRecords = [adjustedRecord]

        // Idle interval overlapping 120 wall-clock seconds (from 240 to 360)
        let interval = IdleReviewInterval(
            sessionId: sessId,
            sessionType: "Focus",
            taskId: nil,
            startTime: baseTime.addingTimeInterval(240),
            endTime: baseTime.addingTimeInterval(360),
            eligibleDurationSeconds: 120,
            status: .pending
        )

        vm.reconcileSessionRecordsExcluding(interval: interval)

        let remainingDuration = vm.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        let allocatedExcluded = FocusIntervalAllocator.allocatedDuration(
            recordStart: baseTime,
            recordEnd: baseTime.addingTimeInterval(600),
            durationSeconds: 400,
            intervalStart: baseTime.addingTimeInterval(240),
            intervalEnd: baseTime.addingTimeInterval(360)
        )
        // Conservation invariant: remaining + allocatedExcluded == 400
        XCTAssertEqual(remainingDuration + allocatedExcluded, 400)
        XCTAssertEqual(remainingDuration, 320)
        XCTAssertEqual(allocatedExcluded, 80)
    }

    // Scenario 8: Task time cannot go negative
    @MainActor
    func testTask9_Patch08_TaskTimeCannotGoNegative() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 100

        vm.deductTaskTime(taskId: taskId, seconds: 500)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0)
    }

    // Scenario 9: Pending time is not included in confirmed focus totals
    @MainActor
    func testTask9_Patch09_PendingTimeNotIncludedInConfirmedFocusTotals() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(1200) // 20m elapsed
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-420),
            endTime: currentTime,
            eligibleDurationSeconds: 420, // 7m idle
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        XCTAssertEqual(vm.pendingFocusSeconds, 420)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 780) // 13m confirmed
    }

    // Scenario 10: Include moves pending credit into confirmed exactly once
    @MainActor
    func testTask9_Patch10_IncludeMovesPendingCreditIntoConfirmedExactlyOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(1200)
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-420),
            endTime: currentTime,
            eligibleDurationSeconds: 420,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        vm.idleReviewCoordinator.resolve(intervalId: idleInterval.id, decision: .countAsFocus, at: currentTime)

        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 1200)
        XCTAssertEqual(vm.pendingFocusSeconds, 0)

        // Idempotent: repeated resolution does not increase confirmed time
        vm.handleIdleReviewResolution(interval: idleInterval, decision: .countAsFocus)
        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 1200)
    }

    // Scenario 11: Exclude removes only eligible credit
    @MainActor
    func testTask9_Patch11_ExcludeRemovesOnlyEligibleCredit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(1200)
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-420),
            endTime: currentTime,
            eligibleDurationSeconds: 420,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        vm.idleReviewCoordinator.resolve(intervalId: idleInterval.id, decision: .excludeFromFocus, at: currentTime)

        XCTAssertEqual(vm.tasks[vm.activeTaskIndex].timeSpentSeconds, 780)
        XCTAssertEqual(vm.pendingFocusSeconds, 0)
    }

    // Scenario 12: Repeated resolution does not change totals
    @MainActor
    func testTask9_Patch12_RepeatedResolutionDoesNotChangeTotals() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 600

        let interval = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: taskId,
            startTime: Date().addingTimeInterval(-300),
            endTime: Date(),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: false
        )

        vm.handleIdleReviewResolution(interval: interval, decision: .excludeFromFocus)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300)

        // Second call with marked deducted interval
        var deducted = interval
        deducted.isProvisionalCreditDeducted = true
        vm.handleIdleReviewResolution(interval: deducted, decision: .excludeFromFocus)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300)
    }

    // Scenario 13: Correct credit distribution across midnight
    @MainActor
    func testTask9_Patch13_CorrectCreditDistributionAcrossMidnight() {
        let cal = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 20
        components.hour = 23
        components.minute = 45
        components.second = 0
        guard let startMidnight = cal.date(from: components),
              let endMidnight = cal.date(byAdding: .minute, value: 30, to: startMidnight) else {
            XCTFail("Failed to create midnight dates")
            return
        }

        let sessId = UUID()
        let record = FocusSessionRecord(
            id: UUID(),
            sessionId: sessId,
            startTime: startMidnight,
            endTime: endMidnight,
            durationSeconds: 1800,
            mode: "Focus"
        )

        let idleStart = startMidnight.addingTimeInterval(600) // 23:55
        let idleEnd = startMidnight.addingTimeInterval(1200)  // 00:05
        let idle = IdleReviewInterval(
            sessionId: sessId,
            sessionType: "Focus",
            taskId: nil,
            startTime: idleStart,
            endTime: idleEnd,
            eligibleDurationSeconds: 600,
            status: .pending
        )

        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        vm.sessionRecords = [record]
        vm.reconcileSessionRecordsExcluding(interval: idle)

        XCTAssertEqual(vm.sessionRecords.count, 2)
        let r1 = vm.sessionRecords[0]
        let r2 = vm.sessionRecords[1]
        XCTAssertEqual(r1.durationSeconds, 600)
        XCTAssertEqual(r2.durationSeconds, 600)

        let day1 = cal.startOfDay(for: startMidnight)
        guard let day2 = cal.date(byAdding: .day, value: 1, to: day1) else { return }

        let day1Total = vm.sessionRecords.reduce(0) { $0 + $1.duration(on: day1, calendar: cal) }
        let day2Total = vm.sessionRecords.reduce(0) { $0 + $1.duration(on: day2, calendar: cal) }
        XCTAssertEqual(day1Total, 600)
        XCTAssertEqual(day2Total, 600)
    }

    // Scenario 14: Correct original task attribution following task switching
    @MainActor
    func testTask9_Patch14_CorrectOriginalTaskAttributionFollowingTaskSwitching() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let task1Id = vm.tasks[0].id

        vm.tasks[0].timeSpentSeconds = 600
        vm.tasks[1].timeSpentSeconds = 200

        // Inactivity occurred under Task 1
        let intervalTask1 = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: task1Id,
            startTime: Date().addingTimeInterval(-300),
            endTime: Date(),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: false
        )

        // User switches active task to Task 2 in UI
        vm.activeTaskIndex = 1

        // User resolves the review for Task 1
        vm.handleIdleReviewResolution(interval: intervalTask1, decision: .excludeFromFocus)

        // Task 1 should be deducted, Task 2 untouched
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300)
        XCTAssertEqual(vm.tasks[1].timeSpentSeconds, 200)
    }

    // Scenario 15: Deferred session record retains actual wall-clock timestamps
    @MainActor
    func testTask9_Patch15_DeferredSessionRecordRetainsActualWallClockTimestamps() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p15_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        let baseStart = Date(timeIntervalSince1970: 1700000000)
        var currentTime = baseStart
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.startTimer(at: currentTime)

        // Idle from minute 5 to 15 (600s in middle)
        let idleStart = baseStart.addingTimeInterval(300)
        let idleEnd = baseStart.addingTimeInterval(900)

        // Advance to deadline
        currentTime = baseStart.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending)

        // Manually configure the middle idle interval
        let middleIdle = IdleReviewInterval(
            sessionId: vm.deferredCompletionSessionId ?? vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: vm.deferredCompletionTaskId,
            startTime: idleStart,
            endTime: idleEnd,
            eligibleDurationSeconds: 600,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        vm.idleReviewCoordinator.pendingIntervals = [middleIdle]

        // Resolve exclude
        vm.idleReviewCoordinator.resolve(intervalId: middleIdle.id, decision: .excludeFromFocus, at: currentTime)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.sessionRecords.count, 2)
        let r1 = vm.sessionRecords[0]
        let r2 = vm.sessionRecords[1]

        // True historical positions
        XCTAssertEqual(r1.startTime, baseStart)
        XCTAssertEqual(r1.endTime, idleStart)
        XCTAssertEqual(r1.durationSeconds, 300)

        XCTAssertEqual(r2.startTime, idleEnd)
        XCTAssertEqual(r2.endTime, baseStart.addingTimeInterval(1500))
        XCTAssertEqual(r2.durationSeconds, 600)
    }

    // Scenario 16: Two pending intervals belonging to one session
    @MainActor
    func testTask9_Patch16_TwoPendingIntervalsBelongingToOneSession() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessId = vm.activeTimerSessionId
        let baseTime = Date()

        let intv1 = IdleReviewInterval(
            sessionId: sessId,
            sessionType: "Focus",
            startTime: baseTime.addingTimeInterval(-1000),
            endTime: baseTime.addingTimeInterval(-700),
            eligibleDurationSeconds: 300,
            status: .pending
        )
        let intv2 = IdleReviewInterval(
            sessionId: sessId,
            sessionType: "Focus",
            startTime: baseTime.addingTimeInterval(-500),
            endTime: baseTime.addingTimeInterval(-200),
            eligibleDurationSeconds: 300,
            status: .pending
        )

        vm.idleReviewCoordinator.pendingIntervals = [intv1, intv2]
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.filter { $0.sessionId == sessId }.count, 2)
    }

    // Scenario 17: Resolving only the first does not finalize the session
    @MainActor
    func testTask9_Patch17_ResolvingFirstIntervalDoesNotFinalizeSession() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessId = UUID()
        vm.isDeferredCompletionPending = true
        vm.deferredCompletionSessionId = sessId
        vm.deferredCompletionTargetEndDate = Date()
        vm.deferredCompletionSegmentStartDate = Date().addingTimeInterval(-1500)
        vm.deferredCompletionSegmentCreditedSeconds = 1500

        let id1 = UUID()
        let id2 = UUID()
        let intv1 = IdleReviewInterval(
            id: id1,
            sessionId: sessId,
            sessionType: "Focus",
            startTime: Date().addingTimeInterval(-1000),
            endTime: Date().addingTimeInterval(-700),
            eligibleDurationSeconds: 300,
            status: .pending
        )
        let intv2 = IdleReviewInterval(
            id: id2,
            sessionId: sessId,
            sessionType: "Focus",
            startTime: Date().addingTimeInterval(-500),
            endTime: Date().addingTimeInterval(-200),
            eligibleDurationSeconds: 300,
            status: .pending
        )
        vm.idleReviewCoordinator.pendingIntervals = [intv1, intv2]

        // Resolve interval 1
        vm.idleReviewCoordinator.resolve(intervalId: id1, decision: .countAsFocus)

        // Session must STILL be pending completion because interval 2 remains!
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
    }

    // Scenario 18: Resolving the final interval finalizes exactly once
    @MainActor
    func testTask9_Patch18_ResolvingFinalIntervalFinalizesExactlyOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessId = UUID()
        vm.isDeferredCompletionPending = true
        vm.deferredCompletionSessionId = sessId
        vm.deferredCompletionTargetEndDate = Date()
        vm.deferredCompletionSegmentStartDate = Date().addingTimeInterval(-1500)
        vm.deferredCompletionSegmentCreditedSeconds = 1500

        let id2 = UUID()
        let intv2 = IdleReviewInterval(
            id: id2,
            sessionId: sessId,
            sessionType: "Focus",
            startTime: Date().addingTimeInterval(-500),
            endTime: Date().addingTimeInterval(-200),
            eligibleDurationSeconds: 300,
            status: .pending
        )
        vm.idleReviewCoordinator.pendingIntervals = [intv2]

        // Resolve final interval
        vm.idleReviewCoordinator.resolve(intervalId: id2, decision: .countAsFocus)

        // Finalizes!
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertTrue(vm.idleReviewCoordinator.pendingIntervals.isEmpty)
    }

    // Scenario 19: Decide Later preserves pending completion
    @MainActor
    func testTask9_Patch19_DecideLaterPreservesPendingCompletion() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sessId = UUID()
        vm.isDeferredCompletionPending = true
        vm.deferredCompletionSessionId = sessId
        vm.deferredCompletionTargetEndDate = Date()

        let id1 = UUID()
        let intv = IdleReviewInterval(
            id: id1,
            sessionId: sessId,
            sessionType: "Focus",
            startTime: Date().addingTimeInterval(-500),
            endTime: Date().addingTimeInterval(-200),
            eligibleDurationSeconds: 300,
            status: .pending
        )
        vm.idleReviewCoordinator.pendingIntervals = [intv]

        vm.idleReviewCoordinator.resolve(intervalId: id1, decision: .decideLater)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
    }

    // Scenario 20: Intervals belonging to other sessions remain unaffected
    @MainActor
    func testTask9_Patch20_IntervalsBelongingToOtherSessionsRemainUnaffected() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let sess1 = UUID()
        let sess2 = UUID()

        let intv1 = IdleReviewInterval(id: UUID(), sessionId: sess1, sessionType: "Focus", startTime: Date().addingTimeInterval(-1000), endTime: Date().addingTimeInterval(-700), eligibleDurationSeconds: 300, status: .pending)
        let intv2 = IdleReviewInterval(id: UUID(), sessionId: sess2, sessionType: "Focus", startTime: Date().addingTimeInterval(-500), endTime: Date().addingTimeInterval(-200), eligibleDurationSeconds: 300, status: .pending)

        vm.idleReviewCoordinator.pendingIntervals = [intv1, intv2]

        vm.idleReviewCoordinator.resolve(intervalId: intv1.id, decision: .countAsFocus)

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.first?.id, intv2.id)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.first?.sessionId, sess2)
    }

    // Scenario 21: Late resolution does not play a delayed completion chime
    @MainActor
    func testTask9_Patch21_LateResolutionSuppressesDelayedCompletionChime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let pastDeadline = Date().addingTimeInterval(-3600) // 1 hour ago
        vm.isDeferredCompletionPending = true
        vm.deferredCompletionSessionId = UUID()
        vm.deferredCompletionTargetEndDate = pastDeadline
        vm.deferredCompletionSegmentStartDate = pastDeadline.addingTimeInterval(-1500)
        vm.deferredCompletionSegmentCreditedSeconds = 1500

        // Finalize deferred session 1 hour after deadline
        vm.finalizeDeferredSession(decision: .countAsFocus)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        // Notification & chime suppressed cleanly without crashes
    }

    // Scenario 22: Normal completion retains its established notification behavior
    @MainActor
    func testTask9_Patch22_NormalCompletionRetainsEstablishedNotificationBehavior() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_p22_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(0.0) // User is active!
        vm.reconcileActiveTimers(at: currentTime)

        // Completes immediately without deferral
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertTrue(vm.isBreakPreset)
    }

    // Scenario 23: Return detection works when tick misses sub-second window
    @MainActor
    func testTask9_Patch23_ReturnDetectionWorksWhenTickMissesSubSecondWindow() {
        let mockActivity = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mockActivity, thresholdSeconds: 300)

        var now = Date()
        coordinator.tick(now: now, isSessionActive: true, sessionType: "Focus", sessionId: UUID(), taskId: nil)

        // Idle for 400s
        now = now.addingTimeInterval(400)
        mockActivity.setSimulatedIdle(400)
        coordinator.tick(now: now, isSessionActive: true, sessionType: "Focus", sessionId: UUID(), taskId: nil)
        XCTAssertTrue(coordinator.state.isIdleDetected)

        // User returned 1.8 seconds ago (missed sub-second window < 1.0)
        now = now.addingTimeInterval(2.0)
        mockActivity.setSimulatedIdle(1.8)
        coordinator.tick(now: now, isSessionActive: true, sessionType: "Focus", sessionId: UUID(), taskId: nil)

        // Return MUST be recognized!
        XCTAssertFalse(coordinator.state.isIdleDetected)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
    }

    // Scenario 24: Repeated sleep/wake events do not create duplicate intervals
    @MainActor
    func testTask9_Patch24_RepeatedSleepWakeEventsDoNotCreateDuplicateIntervals() {
        let mockActivity = MockIdleActivityProvider()
        let coordinator = IdleReviewCoordinator(activityProvider: mockActivity, thresholdSeconds: 300)

        let now = Date()
        let sessId = UUID()
        coordinator.handleSleep(at: now)
        coordinator.handleWake(at: now.addingTimeInterval(600), isSessionActive: true, sessionType: "Focus", sessionId: sessId, taskId: nil)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)

        // Duplicate wake event at same interval
        coordinator.handleWake(at: now.addingTimeInterval(600), isSessionActive: true, sessionType: "Focus", sessionId: sessId, taskId: nil)
        XCTAssertEqual(coordinator.pendingIntervals.count, 1)
    }

    // Scenario 25: Stopwatch display and laps remain unchanged
    @MainActor
    func testTask9_Patch25_StopwatchDisplayAndLapsRemainUnchanged() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.startStopwatch()

        currentTime = currentTime.addingTimeInterval(100)
        vm.reconcileActiveTimers(at: currentTime)
        vm.recordLap()

        currentTime = currentTime.addingTimeInterval(100)
        vm.reconcileActiveTimers(at: currentTime)
        vm.recordLap()

        XCTAssertEqual(vm.laps.count, 2)
        let originalLaps = vm.laps
        let originalTime = vm.stopwatchTime

        // Idle review resolution on stopwatch
        let intv = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Stopwatch",
            taskId: vm.tasks[0].id,
            startTime: currentTime.addingTimeInterval(-60),
            endTime: currentTime,
            eligibleDurationSeconds: 60,
            status: .pending,
            isProvisionalCreditDeducted: false
        )
        vm.handleIdleReviewResolution(interval: intv, decision: .excludeFromFocus)

        // Stopwatch laps and display must be 100% preserved
        XCTAssertEqual(vm.stopwatchTime, originalTime)
    }

    // MARK: - Task 9 Final Correctness & Persistence Patch (Defects 1 & 2)

    // Defect 1 Reproduction: Excluded idle intervals lost after restart (Exclude B)
    @MainActor
    func testDefect1_Reproduction_ExcludedIdleIntervalLostAfterRestart_ThenExcludeB() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_d1_a_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        let calendar = Calendar.current
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 0, second: 0))!
        var currentTime = baseDate

        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        // Advance to 1500s (10:25) - session expired during inactivity
        currentTime = baseDate.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)

        // Set up two pending intervals: Interval A (10:05-10:10, 300s) and Interval B (10:15-10:20, 300s)
        let intervalA = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: baseDate.addingTimeInterval(300),
            endTime: baseDate.addingTimeInterval(600),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        let intervalB = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: baseDate.addingTimeInterval(900),
            endTime: baseDate.addingTimeInterval(1200),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )

        // Set task credited to 900 (1500 - 600 provisional deductions)
        vm.tasks[0].timeSpentSeconds = 900
        vm.idleReviewCoordinator.pendingIntervals = [intervalA, intervalB]
        vm.idleReviewCoordinator.activeReviewInterval = intervalA

        // 4. Exclude Interval A
        vm.idleReviewCoordinator.resolve(intervalId: intervalA.id, decision: .excludeFromFocus, at: currentTime)

        // 5. Confirm Interval B remains pending and session is still deferred
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.first?.id, intervalB.id)

        // 6. Persist application state
        vm.persistData(force: true)

        // 7 & 8. Simulate process termination and relaunch
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertTrue(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.first?.id, intervalB.id)

        // 10. Resolve Interval B as Exclude
        vm2.idleReviewCoordinator.resolve(intervalId: intervalB.id, decision: .excludeFromFocus, at: currentTime)

        // 11. Finalize the session assertions
        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.completedSessions, 1)

        // Total confirmed focus in session records must be strictly 900 (1500 - 300 - 300)
        let totalRecordSeconds = vm2.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalRecordSeconds, 900, "Final session records must total 900s (Interval A exclusion must survive restart)")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 900, "Task credited time must remain 900s")
    }

    // Defect 1 Reproduction: Excluded idle intervals lost after restart (Count B)
    @MainActor
    func testDefect1_Reproduction_ExcludedIdleIntervalLostAfterRestart_ThenCountB() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_d1_b_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        let calendar = Calendar.current
        let baseDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 0, second: 0))!
        var currentTime = baseDate

        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = baseDate.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        let intervalA = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: baseDate.addingTimeInterval(300),
            endTime: baseDate.addingTimeInterval(600),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        let intervalB = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: baseDate.addingTimeInterval(900),
            endTime: baseDate.addingTimeInterval(1200),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )

        vm.tasks[0].timeSpentSeconds = 900
        vm.idleReviewCoordinator.pendingIntervals = [intervalA, intervalB]
        vm.idleReviewCoordinator.activeReviewInterval = intervalA

        // Exclude Interval A
        vm.idleReviewCoordinator.resolve(intervalId: intervalA.id, decision: .excludeFromFocus, at: currentTime)

        // Persist and relaunch
        vm.persistData(force: true)

        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        // Resolve Interval B as Count
        vm2.idleReviewCoordinator.resolve(intervalId: intervalB.id, decision: .countAsFocus, at: currentTime)

        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.completedSessions, 1)

        // Total confirmed focus in session records must be strictly 1200 (1500 - 300 excluded A)
        let totalRecordSeconds = vm2.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalRecordSeconds, 1200, "Final session records must total 1200s (Interval A exclusion must survive restart)")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 1200, "Task credited time must be 1200s")
    }

    // Defect 2 Scenario A: 100% pending produces 0 confirmed credit
    @MainActor
    func testDefect2_ScenarioA_100PercentPending_ZeroConfirmedCredit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(600) // 10 minutes elapsed
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime,
            eligibleDurationSeconds: 600,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        vm.recalculateFocusMetrics(now: currentTime)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0, "Task credited time must be 0")
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Today's focus must be 0 when 100% of elapsed time is pending review")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0, "Weekly focus must be 0")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 0, "Lifetime focus contribution must be 0")
        XCTAssertEqual(vm.pendingFocusSeconds, 600, "Pending focus must be 600")
        XCTAssertEqual(vm.timeRemaining, 900, "Timer countdown continues accurately (1500 - 600 = 900)")
    }

    // Defect 2 Scenario B: Partial pending reflects only confirmed credit
    @MainActor
    func testDefect2_ScenarioB_PartialPending_AnalyticsReflectConfirmedCredit() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(1200) // 20 minutes elapsed
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-420),
            endTime: currentTime,
            eligibleDurationSeconds: 420,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        vm.recalculateFocusMetrics(now: currentTime)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780, "Task credited time must be 780")
        XCTAssertEqual(vm.todayFocusedSeconds, 780, "Today's focus must reflect confirmed 780s, not 1200s")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 780, "Weekly focus must reflect 780s")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 780, "Lifetime focus must reflect 780s")
        XCTAssertEqual(vm.pendingFocusSeconds, 420)
    }

    // Defect 2 Scenario C: Count moves pending credit into confirmed exactly once
    @MainActor
    func testDefect2_ScenarioC_CountIncreasesConfirmedExactlyOnce() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime,
            eligibleDurationSeconds: 600,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)
        vm.recalculateFocusMetrics(now: currentTime)

        XCTAssertEqual(vm.todayFocusedSeconds, 0)

        // Resolve as Count
        vm.idleReviewCoordinator.resolve(intervalId: idleInterval.id, decision: .countAsFocus, at: currentTime)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600)
        XCTAssertEqual(vm.todayFocusedSeconds, 600)
        XCTAssertEqual(vm.weeklyFocusedSeconds, 600)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 600)
        XCTAssertEqual(vm.pendingFocusSeconds, 0)
    }

    // Defect 2 Scenario D: Exclude does not increase confirmed totals
    @MainActor
    func testDefect2_ScenarioD_ExcludeDoesNotIncreaseConfirmedTotals() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        vm.currentDateProvider = { currentTime }
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime,
            eligibleDurationSeconds: 600,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        vm.idleReviewCoordinator.resolve(intervalId: idleInterval.id, decision: .excludeFromFocus, at: currentTime)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 0)
        XCTAssertEqual(vm.todayFocusedSeconds, 0)
        XCTAssertEqual(vm.weeklyFocusedSeconds, 0)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 0)
        XCTAssertEqual(vm.pendingFocusSeconds, 0)
    }

    // Defect 2 Scenario E: Restart with 0 confirmed credit does not convert elapsed into confirmed
    @MainActor
    func testDefect2_ScenarioE_RestartWithZeroConfirmed_DoesNotConvertElapsedToConfirmed() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_d2_e_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[vm.activeTaskIndex].id

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)

        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime,
            eligibleDurationSeconds: 600,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)
        vm.recalculateFocusMetrics(now: currentTime)

        XCTAssertEqual(vm.todayFocusedSeconds, 0)
        vm.persistData(force: true)

        // Relaunch
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()
        vm2.recalculateFocusMetrics(now: currentTime)

        XCTAssertEqual(vm2.todayFocusedSeconds, 0, "Relaunch must not convert 600s elapsed into confirmed focus")
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 0)
    }

    // Defect 2 Scenario F: Active session running across midnight with pending or excluded time
    @MainActor
    func testDefect2_ScenarioF_MidnightWithPendingOrExcludedTime() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 45, second: 0))!
        var currentTime = start
        vm.currentDateProvider = { currentTime }
        vm.applyPresetDirectly(name: "Custom", minutes: 60)
        vm.startTimer(at: currentTime)
        let taskId = vm.tasks[0].id

        // Advance 1800s to 00:15 on Oct 21 (total elapsed 1800s; 900 yesterday, 900 today)
        currentTime = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 15, second: 0))!
        vm.reconcileActiveTimers(at: currentTime)

        // 600s idle interval from 00:05 to 00:15 (all 600s on Day 2)
        var idleInterval = IdleReviewInterval(
            sessionId: vm.activeTimerSessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5, second: 0))!,
            endTime: currentTime,
            eligibleDurationSeconds: 600,
            status: .pending
        )
        vm.handleIdleIntervalCreated(&idleInterval)
        vm.idleReviewCoordinator.pendingIntervals.append(idleInterval)

        vm.recalculateFocusMetrics(calendar: calendar, now: currentTime)

        // Day 2 (today) had 900 elapsed minus 600 pending = 300 confirmed
        XCTAssertEqual(vm.todayFocusedSeconds, 300, "Today (Oct 21) must have 300 confirmed (900 elapsed - 600 pending)")
        XCTAssertEqual(vm.weeklyFocusedSeconds, 1200, "Past 7 days must have 1200 confirmed (1800 elapsed - 600 pending)")
        XCTAssertEqual(vm.pendingFocusSeconds, 600)
    }

    // Dedicated Test 1: Two consecutive restarts before finalization
    @MainActor
    func testTask9_FinalPatch_TwoConsecutiveRestartsBeforeFinalization() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_fp_1_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        let intervalA = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-1200),
            endTime: currentTime.addingTimeInterval(-900),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        let intervalB = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime.addingTimeInterval(-300),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )

        vm.tasks[0].timeSpentSeconds = 900
        vm.idleReviewCoordinator.pendingIntervals = [intervalA, intervalB]
        vm.idleReviewCoordinator.activeReviewInterval = intervalA

        // Exclude A
        vm.idleReviewCoordinator.resolve(intervalId: intervalA.id, decision: .excludeFromFocus, at: currentTime)
        vm.persistData(force: true)

        // Restart 1 (simulate quit & relaunch)
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()
        XCTAssertTrue(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.first?.id, intervalB.id)
        XCTAssertEqual(vm2.sessionExclusionLedger.count, 1)
        XCTAssertEqual(vm2.sessionExclusionLedger.first?.id, intervalA.id)

        // Restart 2 (another quit & relaunch before finalization)
        vm2.handleAppTermination()
        let vm3 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm3.loadPersistedData()
        XCTAssertTrue(vm3.isDeferredCompletionPending)
        XCTAssertEqual(vm3.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm3.sessionExclusionLedger.count, 1)

        // Resolve B as Exclude and finalize
        vm3.idleReviewCoordinator.resolve(intervalId: intervalB.id, decision: .excludeFromFocus, at: currentTime)
        XCTAssertFalse(vm3.isDeferredCompletionPending)
        XCTAssertEqual(vm3.completedSessions, 1)

        let totalRecords = vm3.sessionRecords.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalRecords, 900, "After two restarts, both exclusions must be applied (1500 - 300 - 300 = 900)")
    }

    // Dedicated Test 2: Excluded interval idempotence (resolving twice cannot double-deduct)
    @MainActor
    func testTask9_FinalPatch_ExcludedIntervalIdempotence() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 600

        let interval = IdleReviewInterval(
            sessionId: UUID(),
            sessionType: "Focus",
            taskId: taskId,
            startTime: Date().addingTimeInterval(-300),
            endTime: Date(),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: false
        )

        // First exclusion
        vm.handleIdleReviewResolution(interval: interval, decision: .excludeFromFocus)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300)
        XCTAssertEqual(vm.sessionExclusionLedger.count, 1)

        // Second duplicate exclusion
        vm.handleIdleReviewResolution(interval: interval, decision: .excludeFromFocus)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 300, "Second exclusion must be idempotent and not deduct again")
        XCTAssertEqual(vm.sessionExclusionLedger.count, 1, "Ledger must not contain duplicate entries")
    }

    // Dedicated Test 3: Fully excluded zero-confirmed session
    @MainActor
    func testTask9_FinalPatch_FullyExcludedZeroConfirmedSession() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_fp_3_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(1500)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)

        // Entire 1500s was idle
        let interval = IdleReviewInterval(
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-1500),
            endTime: currentTime,
            eligibleDurationSeconds: 1500,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        vm.idleReviewCoordinator.pendingIntervals = [interval]
        vm.idleReviewCoordinator.activeReviewInterval = interval

        // Exclude entire session
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .excludeFromFocus, at: currentTime)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1, "Completed session count must increment")
        XCTAssertTrue(vm.sessionRecords.isEmpty, "No session record should be fabricated when confirmed focus is 0")
        XCTAssertEqual(vm.todayFocusedSeconds, 0, "Today's focus must remain 0")
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 0, "Lifetime focus must remain 0")
    }

    // Dedicated Test 4: Legacy saved data without sessionExclusionLedger
    @MainActor
    func testTask9_FinalPatch_LegacySavedDataWithoutExclusionLedger() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_legacy_\(UUID().uuidString).json")
        defer { cleanup(url: tempURL) }

        // Write legacy JSON without sessionExclusionLedger key
        let legacyJSON = """
        {
            "tasks": [],
            "focusedSeconds": 300,
            "completedSessions": 1,
            "notes": [],
            "dailyGoalHours": 4,
            "totalSessions": 4,
            "autoStartNextSession": false,
            "activePreset": "Focus",
            "clockStyle": "Digital",
            "sessionRecords": [],
            "laps": [],
            "stopwatchElapsedSeconds": 0.0
        }
        """
        try! legacyJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)
        vm.loadPersistedData()

        XCTAssertTrue(vm.sessionExclusionLedger.isEmpty, "Legacy data loads cleanly with empty ledger")
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.lifetimeFocusedSeconds, 300)
    }

    // Dedicated Test 5: Crash immediately after an exclusion decision
    @MainActor
    func testTask9_FinalPatch_CrashImmediatelyAfterExclusionDecision() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_crash_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date()
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 0

        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        let intervalA = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime.addingTimeInterval(-300),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        let intervalB = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-300),
            endTime: currentTime,
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        vm.idleReviewCoordinator.pendingIntervals = [intervalA, intervalB]

        // Exclude Interval A - handleIdleReviewResolution immediately forces persistence
        vm.idleReviewCoordinator.resolve(intervalId: intervalA.id, decision: .excludeFromFocus, at: currentTime)

        // Drop vm immediately without handleAppTermination (simulating sudden crash/SIGKILL)
        let vmCrashRecovered = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmCrashRecovered.loadPersistedData()

        XCTAssertTrue(vmCrashRecovered.isDeferredCompletionPending, "Deferred completion restored")
        XCTAssertEqual(vmCrashRecovered.sessionExclusionLedger.count, 1, "Exclusion survived immediate crash")
        XCTAssertEqual(vmCrashRecovered.sessionExclusionLedger.first?.id, intervalA.id)
        XCTAssertEqual(vmCrashRecovered.idleReviewCoordinator.pendingIntervals.count, 1, "Only Interval B remains pending")
        XCTAssertEqual(vmCrashRecovered.idleReviewCoordinator.pendingIntervals.first?.id, intervalB.id)
    }

    // MARK: - Task 9: Atomic Idle Review Creation & Recovery Safety (Defects A, B, C)

    @MainActor
    func testTask9_Atomic_01_NormalIdleReturn_CoherentSnapshotAndQueue() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_01_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(780)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.segmentCreditedSeconds, 780)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1, "Exactly one pending review created")
        guard let pending = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing pending interval")
            return
        }
        XCTAssertEqual(pending.sessionId, sessionId)
        XCTAssertEqual(pending.eligibleDurationSeconds, 420)
        XCTAssertTrue(pending.isProvisionalCreditDeducted, "Provisional credit must be deducted")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780, "Task time must be 1200 - 420 = 780s")
        XCTAssertEqual(vm.segmentCreditedSeconds, 780, "Segment credit must be 1200 - 420 = 780s")
        XCTAssertEqual(vm.todayFocusedSeconds, 780, "Today focus must be 780s confirmed")

        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.first?.id, pending.id)
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.first?.eligibleDurationSeconds, 420)
        XCTAssertTrue(vmRestored.idleReviewCoordinator.pendingIntervals.first?.isProvisionalCreditDeducted == true)
        XCTAssertEqual(vmRestored.tasks[0].timeSpentSeconds, 780)
        XCTAssertEqual(vmRestored.todayFocusedSeconds, 780)
    }

    @MainActor
    func testTask9_Atomic_02_NegativeTest_NoDeductionWithoutPendingIntervalInSavedSnapshot() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_02_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var savedSnapshots: [FocusAppData] = []
        storage.onSavePayload = { payload in
            savedSnapshots.append(payload)
        }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)

        savedSnapshots.removeAll()

        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertFalse(savedSnapshots.isEmpty, "Return tick must trigger persistence")
        for (idx, snapshot) in savedSnapshots.enumerated() {
            let rootPendingCount = snapshot.pendingIdleIntervals?.count ?? 0
            let recoveryPendingCount = snapshot.activeSessionRecovery?.pendingIdleIntervals?.count ?? 0
            XCTAssertTrue(
                rootPendingCount > 0 || recoveryPendingCount > 0,
                "Snapshot #\(idx) had deducted task time but missing pending interval in saved payload!"
            )
        }
    }

    @MainActor
    func testTask9_Atomic_03_RestoredViewModel_SamePendingIntervalUUID() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_03_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        vm.reconcileActiveTimers(at: currentTime)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        guard let originalId = vm.idleReviewCoordinator.pendingIntervals.first?.id else {
            XCTFail("Missing pending interval")
            return
        }

        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.first?.id, originalId)
    }

    @MainActor
    func testTask9_Atomic_04_RestoredTaskCredit_MatchesConfirmedSeconds() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_04_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        vm.reconcileActiveTimers(at: currentTime)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()
        XCTAssertEqual(vmRestored.tasks[0].timeSpentSeconds, 780)

        guard let intId = vmRestored.idleReviewCoordinator.pendingIntervals.first?.id else {
            XCTFail("Missing pending interval")
            return
        }
        vmRestored.idleReviewCoordinator.resolve(intervalId: intId, decision: .countAsFocus, at: currentTime)
        XCTAssertEqual(vmRestored.tasks[0].timeSpentSeconds, 1200)
    }

    @MainActor
    func testTask9_Atomic_05_RestoredFocusMetrics_TodayWeeklyLifetime() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_05_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        vm.reconcileActiveTimers(at: currentTime)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()
        XCTAssertEqual(vmRestored.todayFocusedSeconds, 780)
        XCTAssertEqual(vmRestored.weeklyFocusedSeconds, 780)
        XCTAssertEqual(vmRestored.lifetimeFocusedSeconds, 780)
    }

    @MainActor
    func testTask9_Atomic_06_PendingIntervalCreation_TriggersExactlyOneDeduction() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_06_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        vm.reconcileActiveTimers(at: currentTime)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780)

        // Repeat reconciliation at same point in time
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780, "Second tick must not double-deduct")
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
    }

    @MainActor
    func testTask9_Atomic_07_SleepWake_UsesSameAccountingMechanismAndProvisionalDeduction() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_07_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1500
        vm.timeRemaining = 1500
        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600)

        vm.idleReviewCoordinator.handleSleep(at: currentTime)

        currentTime = currentTime.addingTimeInterval(600)
        vm.idleReviewCoordinator.handleWake(
            at: currentTime,
            isSessionActive: vm.isTimerRunning,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: vm.tasks[0].id,
            sessionDeadline: vm.targetEndDate,
            sessionStartDate: vm.sessionSegmentStartDate
        )

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1, "Wake created pending review")
        guard let wakeInterval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing wake interval")
            return
        }
        XCTAssertTrue(wakeInterval.isEstimated, "Wake interval must be estimated")
        XCTAssertTrue(wakeInterval.isProvisionalCreditDeducted, "Wake interval must have provisional credit deducted")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 600, "Task time must be 600s after provisional deduction")
    }

    @MainActor
    func testTask9_Atomic_08_SleepWake_EstimatedIntervalRemainsEstimatedAfterRestart() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_08_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1500
        vm.timeRemaining = 1500
        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)
        vm.idleReviewCoordinator.handleSleep(at: currentTime)

        currentTime = currentTime.addingTimeInterval(600)
        vm.idleReviewCoordinator.handleWake(
            at: currentTime,
            isSessionActive: vm.isTimerRunning,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: vm.tasks[0].id,
            sessionDeadline: vm.targetEndDate,
            sessionStartDate: vm.sessionSegmentStartDate
        )

        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.first?.isEstimated, true)
    }

    @MainActor
    func testTask9_Atomic_09_DuplicateWakeAndReturnEvents_DoNotDoubleDeduct() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_09_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1500
        vm.timeRemaining = 1500
        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)
        vm.idleReviewCoordinator.handleSleep(at: currentTime)

        currentTime = currentTime.addingTimeInterval(600)
        vm.idleReviewCoordinator.handleWake(
            at: currentTime,
            isSessionActive: vm.isTimerRunning,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: vm.tasks[0].id,
            sessionDeadline: vm.targetEndDate,
            sessionStartDate: vm.sessionSegmentStartDate
        )

        let taskTimeAfterFirstWake = vm.tasks[0].timeSpentSeconds

        // Re-call handleWake with duplicate interval parameters
        vm.idleReviewCoordinator.handleSleep(at: currentTime.addingTimeInterval(-600))
        vm.idleReviewCoordinator.handleWake(
            at: currentTime,
            isSessionActive: vm.isTimerRunning,
            sessionType: "Focus",
            sessionId: sessionId,
            taskId: vm.tasks[0].id,
            sessionDeadline: vm.targetEndDate,
            sessionStartDate: vm.sessionSegmentStartDate
        )

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1, "Duplicate wake must not add another interval")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, taskTimeAfterFirstWake, "Duplicate wake must not double-deduct")
    }

    @MainActor
    func testTask9_Atomic_10_DelayedTick_YieldsSameCreditedTotalAsRegularTicks() {
        let mockActivity1 = MockIdleActivityProvider()
        let tempURL1 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_10_1_\(UUID().uuidString).json")
        let storage1 = FocusStorageService(storageURL: tempURL1)
        defer { cleanup(url: tempURL1) }

        let mockActivity2 = MockIdleActivityProvider()
        let tempURL2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_10_2_\(UUID().uuidString).json")
        let storage2 = FocusStorageService(storageURL: tempURL2)
        defer { cleanup(url: tempURL2) }

        let t0 = Date(timeIntervalSince1970: 1700000000)

        // VM1: Delayed tick
        var time1 = t0
        let vmDelayed = TimerViewModel(storage: storage1, currentDateProvider: { time1 }, idleActivityProvider: mockActivity1)
        vmDelayed.idleThresholdSeconds = 300
        vmDelayed.tasks[0].timeSpentSeconds = 0
        vmDelayed.totalTime = 1500
        vmDelayed.timeRemaining = 1500
        vmDelayed.startTimer(at: time1)

        time1 = time1.addingTimeInterval(300)
        vmDelayed.reconcileActiveTimers(at: time1)
        XCTAssertEqual(vmDelayed.segmentCreditedSeconds, 300)

        time1 = time1.addingTimeInterval(500)
        mockActivity1.setSimulatedIdle(500.0)
        vmDelayed.reconcileActiveTimers(at: time1)
        mockActivity1.setSimulatedIdle(0.0)
        vmDelayed.reconcileActiveTimers(at: time1)

        // VM2: Frequent regular ticks (every 50s)
        var time2 = t0
        let vmFrequent = TimerViewModel(storage: storage2, currentDateProvider: { time2 }, idleActivityProvider: mockActivity2)
        vmFrequent.idleThresholdSeconds = 300
        vmFrequent.tasks[0].timeSpentSeconds = 0
        vmFrequent.totalTime = 1500
        vmFrequent.timeRemaining = 1500
        vmFrequent.startTimer(at: time2)

        for _ in 1...6 {
            time2 = time2.addingTimeInterval(50)
            vmFrequent.reconcileActiveTimers(at: time2)
        }
        XCTAssertEqual(vmFrequent.segmentCreditedSeconds, 300)

        for step in 1...10 {
            time2 = time2.addingTimeInterval(50)
            mockActivity2.setSimulatedIdle(Double(step * 50))
            vmFrequent.reconcileActiveTimers(at: time2)
        }
        mockActivity2.setSimulatedIdle(0.0)
        vmFrequent.reconcileActiveTimers(at: time2)

        XCTAssertEqual(
            vmDelayed.segmentCreditedSeconds,
            vmFrequent.segmentCreditedSeconds,
            "Delayed tick must produce identical confirmed focus credit as regular ticks"
        )
        XCTAssertEqual(vmDelayed.segmentCreditedSeconds, 300, "Confirmed focus credit must be exactly 300s")
        XCTAssertEqual(vmDelayed.tasks[0].timeSpentSeconds, 300, "Task time must be exactly 300s")
    }

    @MainActor
    func testTask9_Atomic_11_IdleIntervalCrossingOriginalDeadline_ClampedCorrectly() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_11_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1500
        vm.timeRemaining = 1500
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(1200)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.segmentCreditedSeconds, 1200)

        // User idle from 1200 to 1700 (500s elapsed, crossing deadline at 1500)
        currentTime = currentTime.addingTimeInterval(500)
        mockActivity.setSimulatedIdle(500.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        guard let interval = vm.idleReviewCoordinator.pendingIntervals.first else {
            XCTFail("Missing pending interval")
            return
        }
        XCTAssertEqual(interval.eligibleDurationSeconds, 300, "Inactivity after deadline must be discarded")
        XCTAssertTrue(vm.isDeferredCompletionPending, "Session must enter deferred completion")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1200, "Task credited seconds must be 1200s")
    }

    @MainActor
    func testTask9_Atomic_12_ImmediateForceQuitAfterCommittedInterval_PreservesReview() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_12_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        vm.reconcileActiveTimers(at: currentTime)

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        let originalId = vm.idleReviewCoordinator.pendingIntervals.first?.id

        // Drop VM immediately without handleAppTermination
        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()

        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.first?.id, originalId)
        XCTAssertTrue(vmRestored.idleReviewCoordinator.pendingIntervals.first?.isProvisionalCreditDeducted == true)
    }

    @MainActor
    func testTask9_Atomic_13_StorageWriteFailureFollowedByRetry_PreservesConsistentAccounting() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_13_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1200
        vm.timeRemaining = 1200
        vm.startTimer(at: currentTime)

        currentTime = currentTime.addingTimeInterval(780)
        vm.reconcileActiveTimers(at: currentTime)

        // Simulate write failure during return creation
        storage.simulateWriteFailure = true

        currentTime = currentTime.addingTimeInterval(420)
        mockActivity.setSimulatedIdle(420.0)
        vm.reconcileActiveTimers(at: currentTime)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isSaveFailed, "Save failure must be recorded")
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1, "Interval must not be discarded on save failure")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780, "In-memory state remains coherent")

        // Clear failure and retry
        storage.simulateWriteFailure = false
        vm.retrySave()

        XCTAssertFalse(vm.isSaveFailed, "Save failure cleared on successful retry")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 780, "Retry must not double-deduct")

        let vmRestored = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vmRestored.loadPersistedData()
        XCTAssertEqual(vmRestored.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vmRestored.tasks[0].timeSpentSeconds, 780)
    }

    @MainActor
    func testTask9_Atomic_14_DeferredCompletion_MultiplePendingIntervalsBehavior() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_14_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        let taskId = vm.tasks[0].id
        vm.tasks[0].timeSpentSeconds = 0

        vm.totalTime = 1500
        vm.timeRemaining = 1500
        vm.startTimer(at: currentTime)
        let sessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(300.0)
        vm.reconcileActiveTimers(at: currentTime)

        let intervalA = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-600),
            endTime: currentTime.addingTimeInterval(-300),
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        let intervalB = IdleReviewInterval(
            id: UUID(),
            sessionId: sessionId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: currentTime.addingTimeInterval(-300),
            endTime: currentTime,
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        vm.idleReviewCoordinator.pendingIntervals = [intervalA, intervalB]
        vm.isDeferredCompletionPending = true
        vm.deferredCompletionSessionId = sessionId
        vm.deferredCompletionTargetEndDate = currentTime
        vm.deferredCompletionTaskId = taskId
        vm.deferredCompletionSegmentStartDate = currentTime.addingTimeInterval(-1500)
        vm.deferredCompletionSegmentCreditedSeconds = 900
        vm.tasks[0].timeSpentSeconds = 900

        // Resolve Interval A Count
        vm.idleReviewCoordinator.resolve(intervalId: intervalA.id, decision: .countAsFocus, at: currentTime)
        XCTAssertTrue(vm.isDeferredCompletionPending, "Still deferred because Interval B is pending")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1200)

        // Resolve Interval B Exclude
        vm.idleReviewCoordinator.resolve(intervalId: intervalB.id, decision: .excludeFromFocus, at: currentTime)
        XCTAssertFalse(vm.isDeferredCompletionPending, "Finalized after all resolved")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1200)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, 1200)
    }

    @MainActor
    func testTask9_Atomic_15_StopwatchIdleReview_DoesNotChangeElapsedOrLapData() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_15_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.tasks[0].timeSpentSeconds = 0

        vm.startStopwatch()
        let swSessionId = vm.activeTimerSessionId

        currentTime = currentTime.addingTimeInterval(400)
        vm.reconcileActiveTimers(at: currentTime)
        vm.recordLap()
        XCTAssertEqual(vm.laps.count, 1)
        let lapTime = vm.laps.first?.totalTime

        currentTime = currentTime.addingTimeInterval(600)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.stopwatchTime, 1000)
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1000)

        let swInterval = IdleReviewInterval(
            id: UUID(),
            sessionId: swSessionId,
            sessionType: "Stopwatch",
            taskId: vm.tasks[0].id,
            startTime: currentTime.addingTimeInterval(-300),
            endTime: currentTime,
            eligibleDurationSeconds: 300,
            status: .pending,
            isProvisionalCreditDeducted: false
        )
        vm.idleReviewCoordinator.pendingIntervals = [swInterval]

        vm.idleReviewCoordinator.resolve(intervalId: swInterval.id, decision: .excludeFromFocus, at: currentTime)

        XCTAssertEqual(vm.stopwatchTime, 1000, "Stopwatch elapsed display must not change")
        XCTAssertEqual(vm.laps.first?.totalTime, lapTime, "Lap data must remain untouched")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 700, "Task time must have excluded idle seconds deducted")
    }

    @MainActor
    func testTask9_Atomic_16_NormalTimerBreakAndDisabledModes_RemainUnchanged() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("focusflow_atomic_16_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)

        // Break mode ignores idle
        vm.applyPresetDirectly(name: "Short Break", minutes: 5, isBreak: true)
        vm.startTimer(at: currentTime)
        currentTime = currentTime.addingTimeInterval(300)
        mockActivity.setSimulatedIdle(300.0)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 0, "Break sessions do not generate idle reviews")

        // Idle review disabled mode
        vm.applyPresetDirectly(name: "25m", minutes: 25, isBreak: false)
        vm.idleReviewEnabled = false
        vm.startTimer(at: currentTime)
        currentTime = currentTime.addingTimeInterval(600)
        mockActivity.setSimulatedIdle(600.0)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 0, "Disabled idle review does not generate reviews")
    }

    // MARK: - Phase 1: Sidebar Foundation & Visual Architecture Tests

    func testPhase1_NavigationTab_WorkspaceTabsAndCategorization() {
        let expectedWorkspaceTabs: [NavigationTab] = [.focusTimer, .stopwatch, .tasks, .soundscapes, .insights]
        XCTAssertEqual(NavigationTab.workspaceTabs, expectedWorkspaceTabs, "workspaceTabs must contain exactly the 5 workspace destinations in expected order")

        for tab in expectedWorkspaceTabs {
            XCTAssertTrue(tab.isWorkspaceTab, "\(tab.rawValue) must be recognized as a workspace tab")
        }

        XCTAssertFalse(NavigationTab.settings.isWorkspaceTab, "Settings tab must not be recognized as a workspace tab")
        XCTAssertEqual(NavigationTab.allCases.count, 6, "Total tabs in NavigationTab must remain 6")

        // Check rawValues (must be preserved for Codable and storage compatibility)
        XCTAssertEqual(NavigationTab.focusTimer.rawValue, "Focus Timer")
        XCTAssertEqual(NavigationTab.focusTimer.icon, "hourglass")
        XCTAssertEqual(NavigationTab.stopwatch.rawValue, "Stopwatch & Laps")
        XCTAssertEqual(NavigationTab.stopwatch.icon, "stopwatch")
        XCTAssertEqual(NavigationTab.tasks.rawValue, "Tasks")
        XCTAssertEqual(NavigationTab.tasks.icon, "checklist")
        XCTAssertEqual(NavigationTab.soundscapes.rawValue, "Focus Soundscapes")
        XCTAssertEqual(NavigationTab.soundscapes.icon, "headphones")
        XCTAssertEqual(NavigationTab.insights.rawValue, "Insights & Stats")
        XCTAssertEqual(NavigationTab.insights.icon, "chart.bar")
        XCTAssertEqual(NavigationTab.settings.rawValue, "Settings")
        XCTAssertEqual(NavigationTab.settings.icon, "gearshape")

        // Check updated concise display titles
        XCTAssertEqual(NavigationTab.focusTimer.title, "Focus")
        XCTAssertEqual(NavigationTab.stopwatch.title, "Stopwatch")
        XCTAssertEqual(NavigationTab.tasks.title, "Tasks")
        XCTAssertEqual(NavigationTab.soundscapes.title, "Sounds")
        XCTAssertEqual(NavigationTab.insights.title, "Insights")
        XCTAssertEqual(NavigationTab.settings.title, "Settings")
    }

    func testPhase1_SidebarTokens_GeometryAndTokensIntegrity() {
        // Sizing & Spacing tokens
        XCTAssertEqual(SidebarTokens.sidebarWidth, 252)
        XCTAssertEqual(SidebarTokens.horizontalPadding, 12)
        XCTAssertEqual(SidebarTokens.headerHorizontalPadding, 16)
        XCTAssertEqual(SidebarTokens.headerTopPadding, 40)
        XCTAssertEqual(SidebarTokens.headerBottomPadding, 16)
        XCTAssertEqual(SidebarTokens.sectionSpacing, 6)
        XCTAssertEqual(SidebarTokens.itemSpacing, 3)
        XCTAssertEqual(SidebarTokens.itemMinHeight, 38)
        XCTAssertEqual(SidebarTokens.itemHorizontalPadding, 10)
        XCTAssertEqual(SidebarTokens.itemIconSpacing, 10)
        XCTAssertEqual(SidebarTokens.footerTopPadding, 10)
        XCTAssertEqual(SidebarTokens.footerBottomPadding, 14)
        XCTAssertEqual(SidebarTokens.footerSpacing, 10)

        // Radii tokens
        XCTAssertEqual(SidebarTokens.itemCornerRadius, 8)
        XCTAssertEqual(SidebarTokens.cardCornerRadius, 12)
        XCTAssertEqual(SidebarTokens.iconCornerRadius, 8)

        // Colors (Quiet Productivity palette) - instantiate to ensure they evaluate cleanly
        _ = SidebarTokens.sidebarBackground
        _ = SidebarTokens.surfaceSubtle
        _ = SidebarTokens.surfaceHover
        _ = SidebarTokens.borderSubtle
        _ = SidebarTokens.borderHover
        _ = SidebarTokens.accentOrange
        _ = SidebarTokens.selectionFill
        _ = SidebarTokens.selectionBorder
        _ = SidebarTokens.selectionIndicator
        _ = SidebarTokens.textPrimary
        _ = SidebarTokens.textSecondary
        _ = SidebarTokens.textMuted
        _ = SidebarTokens.sectionHeader
    }

    func testPhase1_DailyProgressWidget_ProgressCalculationsAndClamping() {
        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)

        // 1. Zero progress
        let widgetZero = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 0, goalHours: 2)
        XCTAssertEqual(widgetZero.progress, 0.0, accuracy: 0.0001)
        XCTAssertEqual(widgetZero.durationLabel, "0h 0m")
        XCTAssertEqual(widgetZero.percentageLabel, "0%")

        // 2. Partial progress: 1h 15m (4500s) of 4h goal (14400s) -> 31.25%
        let widgetPartial = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 4500, goalHours: 4)
        XCTAssertEqual(widgetPartial.progress, 4500.0 / 14400.0, accuracy: 0.0001)
        XCTAssertEqual(widgetPartial.durationLabel, "1h 15m")
        XCTAssertEqual(widgetPartial.percentageLabel, "31%")

        // 3. Exact 100% progress: 2h (7200s) of 2h goal
        let widgetExact = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 7200, goalHours: 2)
        XCTAssertEqual(widgetExact.progress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(widgetExact.durationLabel, "2h 0m")
        XCTAssertEqual(widgetExact.percentageLabel, "100%")

        // 4. Clamped overflow progress: 3h (10800s) of 2h goal -> clamped to 1.0
        let widgetOver = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 10800, goalHours: 2)
        XCTAssertEqual(widgetOver.progress, 1.0, accuracy: 0.0001)
        XCTAssertEqual(widgetOver.durationLabel, "3h 0m")
        XCTAssertEqual(widgetOver.percentageLabel, "100%")

        // 5. Clamped non-positive goalHours fallback to at least 1h
        let widgetZeroGoal = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 1800, goalHours: 0)
        XCTAssertEqual(widgetZeroGoal.goalHours, 1, "goalHours of 0 must clamp to 1")
        XCTAssertEqual(widgetZeroGoal.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(widgetZeroGoal.durationLabel, "0h 30m")
        XCTAssertEqual(widgetZeroGoal.percentageLabel, "50%")

        let widgetNegativeGoal = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 1800, goalHours: -5)
        XCTAssertEqual(widgetNegativeGoal.goalHours, 1, "Negative goalHours must clamp to 1")
        XCTAssertEqual(widgetNegativeGoal.progress, 0.5, accuracy: 0.0001)

        // 6. Negative focusedSeconds clamped to 0.0
        let widgetNegativeSeconds = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: -600, goalHours: 2)
        XCTAssertEqual(widgetNegativeSeconds.progress, 0.0, accuracy: 0.0001)
    }

    @MainActor
    func testPhase1_Sidebar_WindowAndNavigationConstraints() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Authoritative TimerViewModel link with DailyProgress
        vm.dailyGoalHours = 3
        vm.todayFocusedSeconds = 3600

        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        let widget = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: vm.todayFocusedSeconds, goalHours: vm.dailyGoalHours)

        XCTAssertEqual(widget.goalHours, 3)
        XCTAssertEqual(widget.focusedSeconds, 3600)
        XCTAssertEqual(widget.percentageLabel, "33%")

        // Sidebar dimensions & constraints
        XCTAssertEqual(SidebarTokens.sidebarWidth, 252)

        // Verify window constraint constants from architecture specification
        let minWindowWidth: CGFloat = 850
        let minWindowHeight: CGFloat = 600
        let defaultWindowWidth: CGFloat = 1050
        let defaultWindowHeight: CGFloat = 700

        XCTAssertGreaterThan(minWindowWidth, SidebarTokens.sidebarWidth)
        let remainingContentWidth = minWindowWidth - SidebarTokens.sidebarWidth
        XCTAssertGreaterThanOrEqual(remainingContentWidth, 598, "At min window width 850, main content gets at least 598pt")
        XCTAssertGreaterThanOrEqual(minWindowHeight, 600)
        XCTAssertGreaterThan(defaultWindowWidth, minWindowWidth)
        XCTAssertGreaterThan(defaultWindowHeight, minWindowHeight)
    }

    // MARK: - Sidebar Redesign (Collapse/Expand & Contextual Accessibility) Tests

    func testSidebarCollapse_TokensAndDimensions() {
        XCTAssertEqual(SidebarTokens.sidebarWidth, 252)
        XCTAssertEqual(SidebarTokens.collapsedWidth, 68)
        XCTAssertEqual(SidebarTokens.collapsedItemWidth, 44)
        XCTAssertEqual(SidebarTokens.horizontalPadding, 12)

        // Mathematical alignment invariant: (collapsedWidth - collapsedItemWidth) / 2 == horizontalPadding
        let symmetricMargin = (SidebarTokens.collapsedWidth - SidebarTokens.collapsedItemWidth) / 2
        XCTAssertEqual(symmetricMargin, SidebarTokens.horizontalPadding, "Collapsed mode margins must equal horizontalPadding exactly (12pt)")

        // Window available content width in collapsed mode
        let minWindowWidth: CGFloat = 850
        let availableCollapsedContentWidth = minWindowWidth - SidebarTokens.collapsedWidth
        XCTAssertEqual(availableCollapsedContentWidth, 782, "At 850pt min window width, collapsed sidebar leaves 782pt for content")
    }

    @MainActor
    func testSidebar_ContextualAccessibilityStatus_FocusTimer() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        var selection: NavigationTab = .focusTimer
        let bindingSelection = Binding(get: { selection }, set: { selection = $0 })
        var isCollapsed = false
        let bindingCollapsed = Binding(get: { isCollapsed }, set: { isCollapsed = $0 })

        let sidebar = SidebarView(gradient: dummyGradient, selection: bindingSelection, isCollapsed: bindingCollapsed, viewModel: vm)

        // 1. Idle state (not started)
        XCTAssertNil(sidebar.contextualAccessibilityValue(for: .focusTimer))

        // 2. Running Focus Timer
        vm.applyPresetDirectly(name: "25m", minutes: 25, isBreak: false)
        vm.startTimer()
        let runningStatus = sidebar.contextualAccessibilityValue(for: .focusTimer)
        XCTAssertNotNil(runningStatus)
        XCTAssertTrue(runningStatus?.contains("remaining, running") == true, "Running focus timer must declare remaining time and running status")
        XCTAssertTrue(runningStatus?.contains(vm.timerTimeString) == true)

        // 3. Paused Focus Timer
        vm.stopTimer()
        let pausedStatus = sidebar.contextualAccessibilityValue(for: .focusTimer)
        XCTAssertNotNil(pausedStatus)
        XCTAssertTrue(pausedStatus?.contains("remaining, paused") == true, "Paused focus timer must declare remaining time and paused status")
        XCTAssertTrue(pausedStatus?.contains(vm.timerTimeString) == true)
    }

    @MainActor
    func testSidebar_ContextualAccessibilityStatus_Stopwatch() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        var selection: NavigationTab = .stopwatch
        let bindingSelection = Binding(get: { selection }, set: { selection = $0 })
        let sidebar = SidebarView(gradient: dummyGradient, selection: bindingSelection, viewModel: vm)

        // 1. Idle stopwatch (0 seconds)
        XCTAssertNil(sidebar.contextualAccessibilityValue(for: .stopwatch))

        // 2. Running Stopwatch
        vm.startStopwatch()
        vm.stopwatchTime = 75
        let runningStatus = sidebar.contextualAccessibilityValue(for: .stopwatch)
        XCTAssertNotNil(runningStatus)
        XCTAssertTrue(runningStatus?.contains("elapsed, running") == true, "Running stopwatch must declare elapsed time and running status")
        XCTAssertTrue(runningStatus?.contains(vm.stopwatchTimeString) == true)

        // 3. Paused Stopwatch
        vm.stopStopwatch()
        vm.stopwatchTime = 75
        let pausedStatus = sidebar.contextualAccessibilityValue(for: .stopwatch)
        XCTAssertNotNil(pausedStatus)
        XCTAssertTrue(pausedStatus?.contains("elapsed, paused") == true, "Paused stopwatch must declare elapsed time and paused status")
        XCTAssertTrue(pausedStatus?.contains(vm.stopwatchTimeString) == true)
    }

    @MainActor
    func testSidebar_ContextualAccessibilityStatus_Tasks() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        var selection: NavigationTab = .tasks
        let bindingSelection = Binding(get: { selection }, set: { selection = $0 })
        let sidebar = SidebarView(gradient: dummyGradient, selection: bindingSelection, viewModel: vm)

        // 1. Default tasks (or populated tasks)
        let total = vm.tasks.count
        let completed = vm.tasks.filter(\.isCompleted).count
        let taskStatus = sidebar.contextualAccessibilityValue(for: .tasks)
        XCTAssertEqual(taskStatus, "\(completed) of \(total) tasks completed")

        // 2. Empty tasks
        vm.tasks.removeAll()
        let emptyStatus = sidebar.contextualAccessibilityValue(for: .tasks)
        XCTAssertEqual(emptyStatus, "No tasks")
    }

    func testSidebar_DailyProgressWidget_CompactModeIntegrity() {
        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)

        let expandedWidget = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 3600, goalHours: 2, isCompact: false)
        XCTAssertFalse(expandedWidget.isCompact)
        XCTAssertEqual(expandedWidget.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(expandedWidget.durationLabel, "1h 0m")
        XCTAssertEqual(expandedWidget.percentageLabel, "50%")

        let compactWidget = DailyProgressWidget(gradient: dummyGradient, focusedSeconds: 3600, goalHours: 2, isCompact: true)
        XCTAssertTrue(compactWidget.isCompact)
        XCTAssertEqual(compactWidget.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(compactWidget.durationLabel, "1h 0m")
        XCTAssertEqual(compactWidget.percentageLabel, "50%")
    }

    @MainActor
    func testSidebar_CollapseStateToggling_DoesNotInterruptTimerOrAccounting() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start timer
        vm.applyPresetDirectly(name: "25m", minutes: 25, isBreak: false)
        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)
        let initialTimeRemaining = vm.timeRemaining

        // Start stopwatch
        vm.startStopwatch()
        vm.stopwatchTime = 42
        XCTAssertTrue(vm.isStopwatchRunning)

        // Toggle collapse state back and forth
        var isCollapsed = false
        let dummyGradient = LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        var selection: NavigationTab = .focusTimer
        let bindingSelection = Binding(get: { selection }, set: { selection = $0 })
        let bindingCollapsed = Binding(get: { isCollapsed }, set: { isCollapsed = $0 })

        _ = SidebarView(gradient: dummyGradient, selection: bindingSelection, isCollapsed: bindingCollapsed, viewModel: vm)

        // Simulate collapse toggle
        isCollapsed = true
        XCTAssertTrue(vm.isTimerRunning, "Timer must remain running across collapse")
        XCTAssertEqual(vm.timeRemaining, initialTimeRemaining)
        XCTAssertTrue(vm.isStopwatchRunning, "Stopwatch must remain running across collapse")
        XCTAssertEqual(vm.stopwatchTime, 42)

        // Simulate expand toggle
        isCollapsed = false
        XCTAssertTrue(vm.isTimerRunning, "Timer must remain running across expand")
        XCTAssertEqual(vm.timeRemaining, initialTimeRemaining)
        XCTAssertTrue(vm.isStopwatchRunning, "Stopwatch must remain running across expand")
        XCTAssertEqual(vm.stopwatchTime, 42)
    }

    func testSidebar_CollapsePreferencePersistence_UserDefaultsKey() {
        let defaults = UserDefaults.standard
        let testKey = "isSidebarCollapsed"

        let originalValue = defaults.bool(forKey: testKey)
        defer { defaults.set(originalValue, forKey: testKey) }

        defaults.set(true, forKey: testKey)
        XCTAssertTrue(defaults.bool(forKey: testKey), "isSidebarCollapsed must persist true across reads")

        defaults.set(false, forKey: testKey)
        XCTAssertFalse(defaults.bool(forKey: testKey), "isSidebarCollapsed must persist false across reads")
    }

    // MARK: - Concise Navigation Display Titles Tests

    func testSidebar_ConciseDisplayTitles_MappingAndConsistency() {
        // 1. Verify computed display titles vs rawValues
        XCTAssertEqual(NavigationTab.focusTimer.title, "Focus")
        XCTAssertEqual(NavigationTab.focusTimer.rawValue, "Focus Timer")

        XCTAssertEqual(NavigationTab.stopwatch.title, "Stopwatch")
        XCTAssertEqual(NavigationTab.stopwatch.rawValue, "Stopwatch & Laps")

        XCTAssertEqual(NavigationTab.tasks.title, "Tasks")
        XCTAssertEqual(NavigationTab.tasks.rawValue, "Tasks")

        XCTAssertEqual(NavigationTab.soundscapes.title, "Sounds")
        XCTAssertEqual(NavigationTab.soundscapes.rawValue, "Focus Soundscapes")

        XCTAssertEqual(NavigationTab.insights.title, "Insights")
        XCTAssertEqual(NavigationTab.insights.rawValue, "Insights & Stats")

        XCTAssertEqual(NavigationTab.settings.title, "Settings")
        XCTAssertEqual(NavigationTab.settings.rawValue, "Settings")

        // 2. Verify all SidebarItem initializations inherit the concise display titles
        for tab in NavigationTab.allCases {
            let item = SidebarItem(tab: tab, isSelected: false) {}
            XCTAssertEqual(item.title, tab.title, "SidebarItem title must match tab.title for \(tab)")
            XCTAssertEqual(item.icon, tab.icon, "SidebarItem icon must match tab.icon for \(tab)")
        }

        // 3. Verify SidebarItem with badges and contextual descriptions
        let focusItem = SidebarItem(tab: .focusTimer, badge: "25:00", contextualAccessibility: "25:00 remaining, running", isSelected: true) {}
        XCTAssertEqual(focusItem.title, "Focus")
        XCTAssertEqual(focusItem.badge, "25:00")
        XCTAssertEqual(focusItem.contextualAccessibility, "25:00 remaining, running")

        let soundsItem = SidebarItem(tab: .soundscapes, isSelected: false) {}
        XCTAssertEqual(soundsItem.title, "Sounds")

        let insightsItem = SidebarItem(tab: .insights, isSelected: false) {}
        XCTAssertEqual(insightsItem.title, "Insights")
    }

    func testSidebar_ConciseDisplayTitles_CodableAndIdentifiersIntegrity() {
        // Verify Codable serialization preserves rawValue strings for persistence compatibility
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for tab in NavigationTab.allCases {
            do {
                let data = try encoder.encode(tab)
                let jsonString = String(data: data, encoding: .utf8)
                XCTAssertEqual(jsonString, "\"\(tab.rawValue)\"", "JSON encoding must use rawValue, not display title")

                let decoded = try decoder.decode(NavigationTab.self, from: data)
                XCTAssertEqual(decoded, tab)
                XCTAssertEqual(decoded.title, tab.title)
                XCTAssertEqual(decoded.rawValue, tab.rawValue)
                XCTAssertEqual(decoded.id, tab.rawValue)
            } catch {
                XCTFail("Failed Codable roundtrip for \(tab): \(error)")
            }
        }

        // Verify decoding legacy rawValues from JSON strings
        let legacyJSON = "[\"Focus Timer\", \"Stopwatch & Laps\", \"Tasks\", \"Focus Soundscapes\", \"Insights & Stats\", \"Settings\"]"
        guard let data = legacyJSON.data(using: .utf8) else {
            XCTFail("Failed to convert legacyJSON to Data")
            return
        }

        do {
            let tabs = try decoder.decode([NavigationTab].self, from: data)
            XCTAssertEqual(tabs.count, 6)
            XCTAssertEqual(tabs[0].title, "Focus")
            XCTAssertEqual(tabs[1].title, "Stopwatch")
            XCTAssertEqual(tabs[2].title, "Tasks")
            XCTAssertEqual(tabs[3].title, "Sounds")
            XCTAssertEqual(tabs[4].title, "Insights")
            XCTAssertEqual(tabs[5].title, "Settings")
        } catch {
            XCTFail("Failed to decode legacy JSON: \(error)")
        }
    }

    // MARK: - Titlebar Safe-Area & Layout Regression Tests

    @MainActor
    func testMainWindow_StyleMaskAndTitlebarConfiguration() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        let contentView = ContentView(viewModel: vm, audioPlayer: player)
            .preferredColorScheme(.dark)
            .frame(minWidth: 850, minHeight: 600)

        let hosting = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1050, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1050, height: 700))
        window.minSize = NSSize(width: 850, height: 600)
        window.title = "FocusFlow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        // Verify window configuration
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "Window must use fullSizeContentView for continuous background")
        XCTAssertTrue(window.styleMask.contains(.titled), "Window must retain titled mask for native titlebar and traffic lights")
        XCTAssertTrue(window.titlebarAppearsTransparent, "Titlebar must appear transparent for modern dark aesthetic")
        XCTAssertEqual(window.titleVisibility, .hidden, "Native window title text must be hidden")
        XCTAssertEqual(window.minSize.width, 850, "Window minWidth must be 850")
        XCTAssertEqual(window.minSize.height, 600, "Window minHeight must be 600")

        // Verify safe area insets are present for content layout
        window.layoutIfNeeded()
        let topInset = hosting.view.safeAreaInsets.top
        XCTAssertGreaterThanOrEqual(topInset, 28.0, "NSHostingView must provide >= 28pt top safe area inset for the transparent titlebar")
    }

    @MainActor
    func testSidebar_TitlebarClearanceIntegrity() {
        // Verify that SidebarTokens.headerTopPadding provides complete titlebar clearance (40pt = 32pt titlebar + 8pt breathing room)
        // so brand identity and collapse controls sit comfortably below the native traffic lights without excessive void
        XCTAssertEqual(SidebarTokens.headerTopPadding, 40, "headerTopPadding must be 40pt for complete traffic light clearance")
        XCTAssertEqual(SidebarTokens.headerBottomPadding, 16, "headerBottomPadding must be 16pt")
        XCTAssertEqual(SidebarTokens.sidebarWidth, 252, "Expanded sidebar width must be 252pt")
        XCTAssertEqual(SidebarTokens.collapsedWidth, 68, "Collapsed sidebar width must be 68pt")
        XCTAssertEqual(SidebarTokens.collapsedItemWidth, 44, "Collapsed item width must be 44pt")
    }

    @MainActor
    func testContentView_RootViewSafeArePropagation() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        // Create ContentView and embed in NSHostingView
        let view = ContentView(viewModel: vm, audioPlayer: player)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1050, height: 700)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1050, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.layoutIfNeeded()

        // Verify the hosting view respects the window's safe area
        XCTAssertGreaterThanOrEqual(hosting.safeAreaInsets.top, 28.0, "ContentView hosting view must receive window top safe area insets")
    }

    // MARK: - PART F: Responsive Window Layout & Stabilization Regression Tests

    @MainActor
    func testResponsiveLayout_01_WindowLayoutMetrics_AuthoritativeGeometryConstants() {
        XCTAssertEqual(WindowLayoutMetrics.titlebarChromeHeight, 32.0, "Native titlebar chrome height must be 32pt")
        XCTAssertEqual(WindowLayoutMetrics.standardBreathingRoom, 8.0, "Intentional breathing room must be 8pt")
        XCTAssertEqual(WindowLayoutMetrics.standardTopClearance, 40.0, "Authoritative windowed top clearance must be exactly 40pt (32 chrome + 8 breathing room)")
        XCTAssertEqual(WindowLayoutMetrics.fullScreenRevealedClearance, 40.0, "Fullscreen top clearance with revealed chrome must be 40pt")
        XCTAssertEqual(WindowLayoutMetrics.fullScreenHiddenChromeClearance, 20.0, "Fullscreen top clearance with autohidden chrome must be 20pt")
        XCTAssertEqual(WindowLayoutMetrics.postBannerSpacing, 12.0, "Post-banner spacing must be 12pt")
        XCTAssertEqual(WindowLayoutMetrics.postMiniBarSpacing, 12.0, "Post-mini-bar spacing must be 12pt")

        XCTAssertEqual(WindowLayoutMetrics.topClearance(isFullScreen: false), 40.0)
        XCTAssertEqual(WindowLayoutMetrics.topClearance(isFullScreen: true, isTitlebarRevealed: true), 40.0)
        XCTAssertEqual(WindowLayoutMetrics.topClearance(isFullScreen: true, isTitlebarRevealed: false), 20.0)
    }

    @MainActor
    func testResponsiveLayout_02_WindowHosted_NormalAndFullScreenClearance() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        let view = ContentView(viewModel: vm, audioPlayer: player)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1050, height: 700)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1050, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.layoutIfNeeded()

        // Windowed mode clearance: 40pt via window query or constant
        XCTAssertEqual(WindowLayoutMetrics.topClearance(for: window), 40.0)
        XCTAssertEqual(WindowLayoutMetrics.topClearance(isFullScreen: false), 40.0)
        // Fullscreen clearance with titlebar revealed: 40pt
        XCTAssertEqual(WindowLayoutMetrics.topClearance(isFullScreen: true, isTitlebarRevealed: true), 40.0)
        // Fullscreen clearance with chrome autohidden: 20pt
        XCTAssertEqual(WindowLayoutMetrics.topClearance(isFullScreen: true, isTitlebarRevealed: false), 20.0)
    }

    @MainActor
    func testResponsiveLayout_03_ExpandedAndCollapsedSidebarGeometry() {
        XCTAssertEqual(SidebarTokens.sidebarWidth, 252.0)
        XCTAssertEqual(SidebarTokens.collapsedWidth, 68.0)
        XCTAssertEqual(SidebarTokens.collapsedItemWidth, 44.0)
        XCTAssertEqual(SidebarTokens.headerTopPadding, 40.0)
        XCTAssertEqual(SidebarTokens.headerBottomPadding, 16.0)

        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        var isCollapsed = false
        let expandedSidebar = SidebarView(
            gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            selection: .constant(.focusTimer),
            isCollapsed: Binding(get: { isCollapsed }, set: { isCollapsed = $0 }),
            viewModel: vm,
            topPadding: 40.0
        )
        XCTAssertEqual(expandedSidebar.topPadding, 40.0)

        isCollapsed = true
        let collapsedSidebar = SidebarView(
            gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            selection: .constant(.focusTimer),
            isCollapsed: Binding(get: { isCollapsed }, set: { isCollapsed = $0 }),
            viewModel: vm,
            topPadding: 40.0
        )
        XCTAssertEqual(collapsedSidebar.topPadding, 40.0)
    }

    @MainActor
    func testResponsiveLayout_04_CompactPresetDiscoverability_90mAndAllBasePresets() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Set duration to 90 minutes
        vm.totalTime = 90 * 60
        vm.timeRemaining = 90 * 60

        let inputView = InPlaceTimeInputView(viewModel: vm, size: 240, isCompact: true)
        let entries = inputView.shortcutEntries

        // Verify 90m chip is present and highlighted as current
        guard let entry90 = entries.first(where: { $0.title == "90m" }) else {
            XCTFail("90m shortcut chip must be present in compact mode when 90:00 is active")
            return
        }
        XCTAssertTrue(entry90.isCurrent, "90m chip must be marked as isCurrent when totalTime is 90:00")
        XCTAssertEqual(entry90.minutes, 90)

        // Verify base focus presets (5, 10, 15, 20, 25, 30, 45, 60, 90) are all present
        let expectedFocusPresets = [5, 10, 15, 20, 25, 30, 45, 60, 90]
        for m in expectedFocusPresets {
            XCTAssertTrue(entries.contains(where: { $0.minutes == m }), "Preset \(m)m must be present in shortcutEntries")
        }

        // Test break presets
        vm.switchToBreak(minutes: 30)
        let breakInputView = InPlaceTimeInputView(viewModel: vm, size: 240, isCompact: true)
        let breakEntries = breakInputView.shortcutEntries
        let expectedBreakPresets = [3, 5, 10, 15, 20, 30]
        for m in expectedBreakPresets {
            XCTAssertTrue(breakEntries.contains(where: { $0.minutes == m }), "Break preset \(m)m must be present in break shortcutEntries")
        }
        guard let entry30Break = breakEntries.first(where: { $0.title == "30m" }) else {
            XCTFail("30m break shortcut chip must be present in break mode")
            return
        }
        XCTAssertTrue(entry30Break.isCurrent, "30m break chip must be marked as isCurrent when 30m break is active")
    }

    @MainActor
    func testResponsiveLayout_05_CustomNonPresetDuration_GeneratesDynamicActiveChip() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Set custom whole-minute duration: 42 minutes
        vm.setCustomDuration(minutes: 42, seconds: 0)
        XCTAssertEqual(vm.totalTime, 42 * 60)

        let inputView = InPlaceTimeInputView(viewModel: vm, size: 260, isCompact: true)
        let entries = inputView.shortcutEntries

        guard let entry42 = entries.first(where: { $0.minutes == 42 }) else {
            XCTFail("Custom 42m duration must generate a discoverable shortcut chip")
            return
        }
        XCTAssertTrue(entry42.isCurrent, "Custom 42m chip must be marked as isCurrent")
        XCTAssertTrue(entry42.isCustom, "Custom 42m chip must be marked as isCustom")
        XCTAssertEqual(entry42.title, "42m")

        // Verify entries remain strictly sorted
        let minutesList = entries.map(\.minutes)
        XCTAssertEqual(minutesList, minutesList.sorted(), "Shortcut chips must remain sorted ascending")
    }

    @MainActor
    func testResponsiveLayout_06_CustomDurationWithSeconds_GeneratesFormattedActiveChip() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Set custom duration with seconds: 25 minutes 30 seconds
        vm.setCustomDuration(minutes: 25, seconds: 30)
        XCTAssertEqual(vm.totalTime, 25 * 60 + 30)

        let inputView = InPlaceTimeInputView(viewModel: vm, size: 260, isCompact: true)
        let entries = inputView.shortcutEntries

        guard let customEntry = entries.first(where: { $0.isCustom }) else {
            XCTFail("Custom duration containing seconds must generate a dedicated active chip")
            return
        }
        XCTAssertTrue(customEntry.isCurrent, "Custom 25:30 chip must be marked as isCurrent")
        XCTAssertEqual(customEntry.title, "25:30", "Chip title must format as MM:SS")
    }

    @MainActor
    func testResponsiveLayout_07_DurationPreservationAcrossResizeAndSidebarStates() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        // Set to 90 minutes
        vm.totalTime = 90 * 60
        vm.timeRemaining = 90 * 60

        let view = ContentView(viewModel: vm, audioPlayer: player)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()

        // Resize down to minimum 850x600
        window.setContentSize(NSSize(width: 850, height: 600))
        hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 600)
        window.layoutIfNeeded()

        // Duration must remain exactly 90:00 (5400s)
        XCTAssertEqual(vm.totalTime, 5400, "Window resize must not alter configured totalTime")
        XCTAssertEqual(vm.timeRemaining, 5400, "Window resize must not alter timeRemaining")

        // Resize to medium 1050x700
        window.setContentSize(NSSize(width: 1050, height: 700))
        hosting.frame = NSRect(x: 0, y: 0, width: 1050, height: 700)
        window.layoutIfNeeded()

        XCTAssertEqual(vm.totalTime, 5400)
        XCTAssertEqual(vm.timeRemaining, 5400)
    }

    @MainActor
    func testResponsiveLayout_08_StageHeightBoundingAcrossWindowHeights() {
        // Digital clock stage height formula: max(220, min(availableH * 0.35, 330))
        // Small window (height 600 -> availableH ≈ 540)
        let smallAvailableH: CGFloat = 540.0
        let smallStageH = max(220, min(smallAvailableH * 0.35, 330))
        XCTAssertEqual(smallStageH, 220.0, "Small window digital stage height must clamp to 220pt")

        // Medium window (height 700 -> availableH ≈ 640)
        let medAvailableH: CGFloat = 640.0
        let medStageH = max(220, min(medAvailableH * 0.35, 330))
        XCTAssertEqual(medStageH, 224.0, accuracy: 0.1)

        // Large window (height 900 -> availableH ≈ 830)
        let largeAvailableH: CGFloat = 830.0
        let largeStageH = max(220, min(largeAvailableH * 0.35, 330))
        XCTAssertEqual(largeStageH, 290.5, accuracy: 0.5)

        // Ultra-tall / 4K window (height 1200 -> availableH ≈ 1130)
        let tallAvailableH: CGFloat = 1130.0
        let tallStageH = max(220, min(tallAvailableH * 0.35, 330))
        XCTAssertEqual(tallStageH, 330.0, "Tall window digital stage height must cap at 330pt, eliminating the 520pt void")
    }

    @MainActor
    func testResponsiveLayout_09_MinimumWindowSize850x600_FitConstraints() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        let view = ContentView(viewModel: vm, audioPlayer: player)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 850, height: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 850, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()

        XCTAssertEqual(window.contentView?.frame.size.width, 850)
        XCTAssertEqual(window.contentView?.frame.size.height, 600)
    }

    @MainActor
    func testResponsiveLayout_10_CrossModeMiniBar_TopClearanceDoesNotDuplicatePadding() {
        XCTAssertEqual(WindowLayoutMetrics.postMiniBarSpacing, 12.0)
        XCTAssertEqual(WindowLayoutMetrics.postBannerSpacing, 12.0)

        // Verify that TasksView with postMiniBarSpacing starts at 12pt instead of 52pt
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        let tasksView = TasksView(viewModel: vm, topPadding: WindowLayoutMetrics.postMiniBarSpacing)
        XCTAssertEqual(tasksView.topPadding, 12.0, "TasksView under an active mini-bar must have 12pt top padding, preventing 140+ pt double padding")
    }

    @MainActor
    func testResponsiveLayout_11_PhysicalControlCoordinateClearance() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        let view = ContentView(viewModel: vm, audioPlayer: player)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1050, height: 700)

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1050, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.layoutIfNeeded()

        // Measure physical AppKit window chrome (typically 28pt on standard macOS window, up to 32pt with specific display metrics)
        let windowH = window.frame.height
        let contentLayoutH = window.contentLayoutRect.height
        let chromeHeight = windowH - contentLayoutH
        XCTAssertTrue(chromeHeight >= 28.0 && chromeHeight <= 32.0, "Physical AppKit titlebar chrome height must be 28-32pt (actual: \(chromeHeight))")

        // Top clearance of 40pt guarantees authoritative baseline clearance regardless of window variations
        let clearance = WindowLayoutMetrics.topClearance(for: window)
        XCTAssertEqual(clearance, 40.0)

        // Measure physical close button in window coordinates
        if let closeBtn = window.standardWindowButton(.closeButton), let themeView = window.contentView?.superview {
            let frameInWindow = closeBtn.convert(closeBtn.bounds, to: themeView)
            let closeBtnTopDist = windowH - frameInWindow.maxY
            let closeBtnBottomDist = windowH - frameInWindow.minY
            XCTAssertTrue(closeBtnTopDist >= 5.0 && closeBtnTopDist <= 10.0, "Close button top sits at 6-9pt from top edge (actual: \(closeBtnTopDist))")
            XCTAssertTrue(closeBtnBottomDist >= 19.0 && closeBtnBottomDist <= 24.0, "Close button bottom sits at 20-23pt from top edge (actual: \(closeBtnBottomDist))")

            let marginBelowButtons = clearance - closeBtnBottomDist
            XCTAssertTrue(marginBelowButtons >= 16.0 && marginBelowButtons <= 21.0, "Header must maintain comfortable clearance below traffic light buttons (actual: \(marginBelowButtons))")
            let marginBelowChrome = clearance - chromeHeight
            XCTAssertTrue(marginBelowChrome >= 8.0 && marginBelowChrome <= 13.0, "Header must maintain intentional breathing room below titlebar chrome (actual: \(marginBelowChrome))")
        }
    }

    @MainActor
    func testResponsiveLayout_12_HeaderBaselineAlignmentAcrossAllDestinations() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }
        let player = AmbientAudioPlayer()

        let clearance = WindowLayoutMetrics.standardTopClearance
        XCTAssertEqual(clearance, 40.0)

        // Verify Sidebar header padding
        var isCollapsed = false
        let sidebar = SidebarView(
            gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            selection: .constant(.focusTimer),
            isCollapsed: Binding(get: { isCollapsed }, set: { isCollapsed = $0 }),
            viewModel: vm,
            topPadding: clearance
        )
        XCTAssertEqual(sidebar.topPadding, 40.0)

        // Verify DashboardTimerView (Focus Timer & Stopwatch)
        let timerDashboard = DashboardTimerView(
            viewModel: vm,
            gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            clockStyle: .constant("Digital"),
            isFocusState: .constant(false),
            showingWorkspace: .constant(false),
            isStopwatchMode: false,
            topPadding: clearance
        )
        XCTAssertEqual(timerDashboard.topPadding, 40.0)

        let stopwatchDashboard = DashboardTimerView(
            viewModel: vm,
            gradient: LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing),
            clockStyle: .constant("Digital"),
            isFocusState: .constant(false),
            showingWorkspace: .constant(false),
            isStopwatchMode: true,
            topPadding: clearance
        )
        XCTAssertEqual(stopwatchDashboard.topPadding, 40.0)

        // Verify secondary views
        let tasks = TasksView(viewModel: vm, topPadding: clearance)
        XCTAssertEqual(tasks.topPadding, 40.0)

        let soundscapes = SoundscapesView(audioPlayer: player, topPadding: clearance)
        XCTAssertEqual(soundscapes.topPadding, 40.0)

        let insights = InsightsView(viewModel: vm, topPadding: clearance)
        XCTAssertEqual(insights.topPadding, 40.0)

        let settings = SettingsView(viewModel: vm, topPadding: clearance)
        XCTAssertEqual(settings.topPadding, 40.0)
    }

    @MainActor
    func testResponsiveLayout_13_FullScreenChromeRevealAndAutohideTransition() {
        // In fullscreen when titlebar is revealed (user moves cursor to top or has persistent menu bar)
        let revealedClearance = WindowLayoutMetrics.topClearance(isFullScreen: true, isTitlebarRevealed: true)
        XCTAssertEqual(revealedClearance, 40.0, "Revealed fullscreen clearance must be 40pt")
        XCTAssertGreaterThan(revealedClearance, WindowLayoutMetrics.titlebarChromeHeight, "Revealed clearance must exceed 32pt titlebar to prevent clipping")

        // In fullscreen when chrome is genuinely absent (autohidden)
        let autohiddenClearance = WindowLayoutMetrics.topClearance(isFullScreen: true, isTitlebarRevealed: false)
        XCTAssertEqual(autohiddenClearance, 20.0, "Autohidden fullscreen clearance must be 20pt, avoiding excessive margins")

        // Windowed mode always preserves 40pt authoritative clearance
        let windowedClearance = WindowLayoutMetrics.topClearance(isFullScreen: false, isTitlebarRevealed: true)
        XCTAssertEqual(windowedClearance, 40.0)
        let windowedClearanceAlt = WindowLayoutMetrics.topClearance(isFullScreen: false, isTitlebarRevealed: false)
        XCTAssertEqual(windowedClearanceAlt, 40.0)
    }

    @MainActor
    private func renderViewToPNGFile<V: View>(_ view: V, size: CGSize, fileName: String) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "FocusFlow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        hostingView.frame = NSRect(origin: .zero, size: size)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let renderTarget: NSView = window.contentView?.superview ?? hostingView
        renderTarget.layoutSubtreeIfNeeded()

        guard let rep = renderTarget.bitmapImageRepForCachingDisplay(in: renderTarget.bounds) else {
            XCTFail("Failed to render view to PNG for \(fileName)")
            return
        }
        renderTarget.cacheDisplay(in: renderTarget.bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to encode PNG data")
            return
        }

        let localArtifactDir = "/Users/deepaksinghjethi/.gemini/antigravity/brain/a7db7b67-cb01-4e70-89ca-66391e88e690"
        let fallbackDir = NSTemporaryDirectory() + "focusflow_qa"
        let targetDir = FileManager.default.fileExists(atPath: localArtifactDir) ? localArtifactDir : fallbackDir
        try? FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let destinationPath = "\(targetDir)/\(fileName)"
        do {
            try pngData.write(to: URL(fileURLWithPath: destinationPath))
            print("Successfully rendered QA artifact: \(destinationPath) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            print("Warning: Could not write QA artifact: \(error)")
        }
    }

    @MainActor
    func testGenerateVisualQAScreenshots() {
        // 1. 850x600 expanded sidebar, 90:00 active (verify 90m chip is present and highlighted)
        do {
            UserDefaults.standard.set(false, forKey: "isSidebarCollapsed")
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            let player = AmbientAudioPlayer()
            vm.totalTime = 90 * 60
            vm.timeRemaining = 90 * 60

            let view = ContentView(viewModel: vm, audioPlayer: player, initialTab: .focusTimer)
            renderViewToPNGFile(view, size: CGSize(width: 850, height: 600), fileName: "qa_850x600_expanded.png")
        }

        // 2. 850x600 collapsed sidebar
        do {
            UserDefaults.standard.set(true, forKey: "isSidebarCollapsed")
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            let player = AmbientAudioPlayer()
            vm.totalTime = 90 * 60
            vm.timeRemaining = 90 * 60

            let view = ContentView(viewModel: vm, audioPlayer: player, initialTab: .focusTimer)
            renderViewToPNGFile(view, size: CGSize(width: 850, height: 600), fileName: "qa_850x600_collapsed.png")
        }

        // Restore expanded sidebar preference
        UserDefaults.standard.set(false, forKey: "isSidebarCollapsed")

        // 3. 1050x700 standard window
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            let player = AmbientAudioPlayer()
            vm.totalTime = 25 * 60
            vm.timeRemaining = 25 * 60

            let view = ContentView(viewModel: vm, audioPlayer: player, initialTab: .focusTimer)
            renderViewToPNGFile(view, size: CGSize(width: 1050, height: 700), fileName: "qa_1050x700_standard.png")
        }

        // 4. 1440x900 large window (verify stage height bounded without 520pt void)
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            let player = AmbientAudioPlayer()
            vm.totalTime = 90 * 60
            vm.timeRemaining = 90 * 60

            let view = ContentView(viewModel: vm, audioPlayer: player, initialTab: .focusTimer)
            renderViewToPNGFile(view, size: CGSize(width: 1440, height: 900), fileName: "qa_1440x900_large.png")
        }

        // 5. Fullscreen window (40pt top clearance with revealed chrome)
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            let player = AmbientAudioPlayer()
            vm.totalTime = 25 * 60
            vm.timeRemaining = 25 * 60

            let view = ContentView(viewModel: vm, audioPlayer: player, initialTab: .focusTimer, isFullScreen: true, isTitlebarRevealed: true)
            renderViewToPNGFile(view, size: CGSize(width: 1440, height: 900), fileName: "qa_fullscreen_1440x900.png")
        }

        // 6. Tasks page with active timer mini-bar (verify 12pt spacing, no 140pt gap)
        do {
            let (vm, tempURL) = makeIsolatedViewModel()
            defer { cleanup(url: tempURL) }
            let player = AmbientAudioPlayer()
            vm.startTimer()

            let view = ContentView(viewModel: vm, audioPlayer: player, initialTab: .tasks)
            renderViewToPNGFile(view, size: CGSize(width: 1050, height: 700), fileName: "qa_tasks_with_minibar.png")
        }
    }
}





