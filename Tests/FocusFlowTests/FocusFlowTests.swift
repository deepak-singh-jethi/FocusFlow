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

        // Reopen two hours later
        let reopenTime = now.addingTimeInterval(7200)
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
}
