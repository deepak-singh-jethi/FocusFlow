import XCTest
import SwiftUI
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

    private func cleanup(url: URL) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

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
                XCTAssertGreaterThan(pngData.count, 1000)
            }
        }
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
}
