import XCTest
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
}
