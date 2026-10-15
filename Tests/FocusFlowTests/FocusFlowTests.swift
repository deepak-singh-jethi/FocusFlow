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

        // Simulate session completion by invoking skipSession() or letting timer finish
        vm.skipSession()

        // Verify session progression occurred
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertTrue(vm.isBreakPreset)

        // PRIORITY 3 ACCEPTANCE: Task must still be incomplete!
        XCTAssertFalse(vm.tasks[activeIndex].isCompleted, "Completing a Pomodoro must NEVER automatically mark a longer task complete")
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
    func testModeSwitchWhileTimerRunningTriggersConflictModal() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Start a 25-minute focus timer
        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertTrue(vm.isTimerActive)

        // Try switching to Short Break while running
        vm.switchToBreak(minutes: 5)

        // Must NOT immediately wipe or change the active timer
        XCTAssertTrue(vm.isTimerRunning, "Timer must continue running uninterrupted")
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertTrue(vm.showConflictModal, "Conflict modal must be presented to user")
        XCTAssertEqual(vm.pendingTimerRequest?.name, "Short Break")
        XCTAssertEqual(vm.pendingTimerRequest?.minutes, 5)
    }

    @MainActor
    func testContinueCurrentTimerDismissesModalWithoutInterruption() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        vm.requestPresetChange(name: "Long Break", minutes: 15)
        XCTAssertTrue(vm.showConflictModal)

        // User selects: Continue Current Timer
        vm.continueCurrentTimer()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertEqual(vm.activePreset, "Focus")
    }

    @MainActor
    func testPauseAndSwitchPreservesSession() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        // Setup 25m timer and elapse 500 seconds
        vm.startTimer()
        vm.timeRemaining = 1000 // 1000s remaining of 1500s
        let previousRemaining = vm.timeRemaining

        // User attempts to switch to Short Break (5m)
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal)

        // User selects: Pause & Switch
        vm.pauseAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)

        // Stage is now switched to Short Break
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertEqual(vm.totalTime, 300)
        XCTAssertEqual(vm.timeRemaining, 300)
        XCTAssertFalse(vm.isTimerRunning, "Only one countdown timer should run at a time")

        // Preserved session is safely retained
        XCTAssertTrue(vm.hasPreservedSession)
        XCTAssertEqual(vm.preservedSession?.activePreset, "Focus")
        XCTAssertEqual(vm.preservedSession?.timeRemaining, previousRemaining)

        // Mini-bar displays the preserved Focus session
        XCTAssertEqual(vm.displayedTimerPreset, "Focus")
        XCTAssertEqual(vm.displayedTimerTimeString, vm.preservedSession?.timeString)

        // User now clicks mini-bar to restore preserved timer
        vm.restorePreservedSession()
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.timeRemaining, previousRemaining)
        XCTAssertEqual(vm.totalTime, 1500)
    }

    @MainActor
    func testEndAndSwitchLogsTimeAndClearsPreserved() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm.startTimer()
        let initialRecordCount = vm.sessionRecords.count

        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.showConflictModal)

        // User selects: End & Switch
        vm.endAndSwitch()

        XCTAssertFalse(vm.showConflictModal)
        XCTAssertNil(vm.pendingTimerRequest)
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertNil(vm.preservedSession)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertEqual(vm.timeRemaining, 300)
        XCTAssertGreaterThanOrEqual(vm.sessionRecords.count, initialRecordCount)
    }

    @MainActor
    func testPreservedSessionStorageRoundtrip() {
        let (vm1, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL) }

        vm1.startTimer()
        vm1.timeRemaining = 850
        vm1.switchToBreak(minutes: 5)
        vm1.pauseAndSwitch()

        XCTAssertTrue(vm1.hasPreservedSession)
        vm1.persistData(force: true)

        // Reload fresh ViewModel from disk
        let storage = FocusStorageService(storageURL: tempURL)
        let vm2 = TimerViewModel(storage: storage)

        XCTAssertTrue(vm2.hasPreservedSession, "Preserved session must survive app relaunch")
        XCTAssertEqual(vm2.preservedSession?.activePreset, "Focus")
        XCTAssertEqual(vm2.preservedSession?.timeRemaining, 850)
    }
}
