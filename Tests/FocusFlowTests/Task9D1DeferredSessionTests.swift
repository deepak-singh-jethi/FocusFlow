import XCTest
import SwiftUI
import Combine
@testable import FocusFlow

final class Task9D1DeferredSessionTests: XCTestCase {

    @MainActor
    private func createGenuineDeferredSession(
        initialMinutes: Int = 25,
        idleDuration: Double = 600,
        taskTitle: String = "Design Spec",
        expectedMinutes: Int = 25
    ) -> (
        vm: TimerViewModel,
        tempURL: URL,
        mockActivity: MockIdleActivityProvider,
        originalSessionId: UUID,
        originalTaskId: UUID,
        deadline: Date,
        startTime: Date
    ) {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        // Set up task
        vm.tasks = [FocusTask(title: taskTitle, estimatedMinutes: expectedMinutes)]
        vm.activeTaskIndex = 0
        let taskId = vm.tasks[0].id

        let totalSeconds = initialMinutes * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds

        let startTime = currentTime
        let deadline = startTime.addingTimeInterval(Double(totalSeconds))
        vm.startTimer(at: currentTime)
        let originalSessionId = vm.activeTimerSessionId

        // Accrue active focus time before going idle (e.g. 15 minutes of work)
        currentTime = startTime.addingTimeInterval(Double(totalSeconds) - idleDuration)
        vm.reconcileActiveTimers(at: currentTime)

        // Reach deadline while idle for idleDuration (e.g. 600s = 10m)
        currentTime = deadline
        mockActivity.setSimulatedIdle(idleDuration)
        vm.reconcileActiveTimers(at: currentTime)

        // User returns to computer (registers pending review interval into queue)
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending, "Precondition: Genuine deferred completion must be pending")
        XCTAssertEqual(vm.timeRemaining, 0, "Precondition: Remaining time must be 0")
        XCTAssertFalse(vm.isTimerRunning, "Precondition: Timer is not running")

        return (vm, tempURL, mockActivity, originalSessionId, taskId, deadline, startTime)
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

    // MARK: - Test Group D1-A: Deferred State Transition Protection

    @MainActor
    func testD1_A01_DirectStartTimer_IsRejected() {
        let (vm, tempURL, _, origSessionId, origTaskId, origDeadline, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.startTimer()

        XCTAssertFalse(vm.isTimerRunning, "New countdown must not start while completion is deferred")
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
        XCTAssertEqual(vm.deferredCompletionTargetEndDate, origDeadline)
        XCTAssertEqual(vm.timeRemaining, 0)
    }

    @MainActor
    func testD1_A02_ToggleTimer_IsRejected() {
        let (vm, tempURL, _, origSessionId, origTaskId, origDeadline, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.toggleTimer()

        XCTAssertFalse(vm.isTimerRunning, "Toggle must not start a new countdown while completion is deferred")
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
        XCTAssertEqual(vm.deferredCompletionTargetEndDate, origDeadline)
        XCTAssertEqual(vm.timeRemaining, 0)
    }

    @MainActor
    func testD1_A03_ResetFocusTimer_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.resetFocusTimer()

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.timeRemaining, 0, "Reset must not alter timeRemaining when completion is deferred")
        XCTAssertEqual(vm.preciseProgress, 0.0)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A04_ResetTimer_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.resetTimer()

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.timeRemaining, 0)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A05_SkipSession_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        let currentSession = vm.currentSession
        vm.skipSession()

        XCTAssertEqual(vm.currentSession, currentSession, "Skip must not advance session when completion is deferred")
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
        XCTAssertFalse(vm.isTimerRunning)
    }

    @MainActor
    func testD1_A06_SwitchToBreak_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.switchToBreak(minutes: 5)

        XCTAssertFalse(vm.isBreakPreset, "switchToBreak must be rejected while deferred completion is pending")
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A07_SwitchToCustomTimer_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.changeMode(to: "Custom Timer")
        vm.setCustomDuration(minutes: 45, seconds: 0)

        XCTAssertEqual(vm.activeMode, "Pomodoro", "Mode change must be rejected while deferred completion is pending")
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A08_DirectApplyPresetDirectly_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.applyPresetDirectly(name: "Long Break", minutes: 15, mode: "Pomodoro", isBreak: true)

        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertFalse(vm.isBreakPreset)
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A09_EndAndSwitch_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.pendingTimerRequest = (name: "Short Break", minutes: 5, seconds: 0, mode: "Pomodoro", isBreak: true)
        vm.endAndSwitch(autoStart: true)

        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A10_RestorePreservedSession_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.preservedSession = PreservedTimerSession(
            activePreset: "Short Break",
            activeMode: "Pomodoro",
            isBreakSession: true,
            totalTime: 300,
            timeRemaining: 150,
            preciseProgress: 0.5,
            customMinutes: 5,
            customSeconds: 0,
            currentSession: 2,
            activeTaskIndex: 0
        )

        vm.restorePreservedSession()
        vm.restorePreservedSessionIfNeeded()

        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A11_CustomDurationCommitPath_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.adjustCustomDuration(by: 10)
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.activePreset, "Focus")

        vm.customTimeInputController.onCommit?(50, 0)
        XCTAssertEqual(vm.totalTime, 1500)
        XCTAssertEqual(vm.activePreset, "Focus")
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_A12_StartStopwatch_IsRejected() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.startStopwatch()
        XCTAssertFalse(vm.isStopwatchRunning, "Starting stopwatch must be rejected while deferred completion is pending")

        vm.toggleStopwatch()
        XCTAssertFalse(vm.isStopwatchRunning)
        XCTAssertEqual(vm.stopwatchTime, 0)
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    // MARK: - Test Group D1-B: Task Ownership Protection

    @MainActor
    func testD1_B01_AttemptSelectOtherTask_PreservesAttribution() {
        let (vm, tempURL, _, origSessionId, origTaskId, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.addTask(title: "Second Task", expectedMinutes: 30)
        XCTAssertEqual(vm.tasks.count, 2)

        vm.selectTask(at: 1)

        XCTAssertEqual(vm.activeTaskIndex, 0, "Active task index must not switch away while completion is deferred")
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId, "Deferred task ID must remain unchanged")
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
        XCTAssertEqual(vm.sessionRecords.count, 0, "No premature session record should be created")
    }

    @MainActor
    func testD1_B02_AttemptCompleteOriginalTask_IsRejected() {
        let (vm, tempURL, _, origSessionId, origTaskId, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.toggleTaskCompletion(at: 0)

        XCTAssertFalse(vm.tasks[0].isCompleted, "Original task must not be marked complete while deferred completion is pending")
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_B03_AttemptDeleteOriginalTask_IsRejected() {
        let (vm, tempURL, _, origSessionId, origTaskId, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.removeTask(at: 0)

        XCTAssertEqual(vm.tasks.count, 1, "Original task must not be deleted while deferred completion is pending")
        if !vm.tasks.isEmpty {
            XCTAssertEqual(vm.tasks[0].id, origTaskId)
        }
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_B04_AttemptResetTaskTime_IsRejected() {
        let (vm, tempURL, _, origSessionId, origTaskId, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        let originalCredited = vm.tasks[0].timeSpentSeconds
        XCTAssertGreaterThan(originalCredited, 0, "Task should have accrued focus time")

        vm.resetTaskTime(at: 0)

        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, originalCredited, "Task time must not be reset while deferred completion is pending")
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    @MainActor
    func testD1_B05_HarmlessTaskAddition_DoesNotMutateDeferredAttribution() {
        let (vm, tempURL, _, origSessionId, origTaskId, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.addTask(title: "Harmless New Task", expectedMinutes: 15)

        XCTAssertEqual(vm.tasks.count, 2, "Harmless task addition is permitted")
        XCTAssertEqual(vm.activeTaskIndex, 0, "Active task index remains with original deferred task")
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
    }

    // MARK: - Test Group D1-C: Pending Review Behavior

    @MainActor
    func testD1_C01_TwoPendingIntervals_FirstResolutionDoesNotFinalize_SecondFinalizes() {
        let (vm, tempURL, _, sessId, taskId, deadline, startTime) = createGenuineDeferredSession(initialMinutes: 50, idleDuration: 600)
        defer { cleanup(url: tempURL, vm: vm) }

        let interval1 = IdleReviewInterval(
            id: UUID(),
            sessionId: sessId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: startTime.addingTimeInterval(600),
            endTime: startTime.addingTimeInterval(1200),
            eligibleDurationSeconds: 600,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        let interval2 = IdleReviewInterval(
            id: UUID(),
            sessionId: sessId,
            sessionType: "Focus",
            taskId: taskId,
            startTime: deadline.addingTimeInterval(-600),
            endTime: deadline,
            eligibleDurationSeconds: 600,
            status: .pending,
            isProvisionalCreditDeducted: true
        )
        vm.idleReviewCoordinator.pendingIntervals = [interval1, interval2]

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 2, "Must have two pending intervals for this session")

        // Resolve interval 1: Count as Focus
        vm.idleReviewCoordinator.resolve(intervalId: interval1.id, decision: .countAsFocus, at: deadline)

        // Invariant: Resolving first interval must NOT finalize the session!
        XCTAssertTrue(vm.isDeferredCompletionPending, "Session completion must remain deferred with 1 interval remaining")
        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.sessionRecords.count, 0)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)

        // Prohibited actions remain blocked while 1 interval remains
        vm.startTimer()
        XCTAssertFalse(vm.isTimerRunning)

        // Resolve interval 2: Exclude from Focus
        vm.idleReviewCoordinator.resolve(intervalId: interval2.id, decision: .excludeFromFocus, at: deadline)

        // Invariant: Resolving final interval must finalize session exactly once!
        XCTAssertFalse(vm.isDeferredCompletionPending, "Session must finalize once all intervals are resolved")
        XCTAssertEqual(vm.completedSessions, 1, "completedSessions must increment exactly once")
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 0)

        // Verify session records reflect accurate conservation of seconds:
        // Total session: 3000s (50m). Interval 1 (600s) counted. Interval 2 (600s) excluded.
        // Credited focus time should be 2400s (40m).
        let totalRecordSeconds = vm.sessionRecords.filter { $0.sessionId == sessId }.reduce(0) { $0 + $1.durationSeconds }
        XCTAssertEqual(totalRecordSeconds, 2400, "Exact conservation of seconds: 3000 - 600 = 2400s")
        XCTAssertEqual(vm.tasks[0].id, taskId)
    }

    @MainActor
    func testD1_C02_DecideLater_PreservesPendingCompletionAndAllowsReopen() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
        let interval = vm.idleReviewCoordinator.pendingIntervals[0]

        // Select Decide Later
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .decideLater)

        // Verification: Completion remains pending, interval stays in queue
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertNil(vm.idleReviewCoordinator.activeReviewInterval)

        // Prohibited actions remain blocked after Decide Later
        vm.startTimer()
        XCTAssertFalse(vm.isTimerRunning)
        vm.resetFocusTimer()
        XCTAssertEqual(vm.timeRemaining, 0)

        // Reopen review
        vm.idleReviewCoordinator.openReview(for: interval)
        XCTAssertEqual(vm.idleReviewCoordinator.activeReviewInterval?.id, interval.id)

        // Resolve now
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .countAsFocus)
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.deferredCompletionSessionId, nil)
        _ = origSessionId
    }

    // MARK: - Test Group D1-D: Post-Finalization Recovery

    @MainActor
    func testD1_D01_LegitimateFinalization_ClearsDeferredAndEnablesControls_AutoStartOff() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.autoStartNextSession = false
        let interval = vm.idleReviewCoordinator.pendingIntervals[0]
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .countAsFocus)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertFalse(vm.isCountdownMutationBlocked)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertFalse(vm.isTimerRunning, "Auto-start is OFF; timer should not start automatically")

        // Normal controls work again
        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning, "Normal controls must work again after legitimate finalization")
        _ = origSessionId
    }

    @MainActor
    func testD1_D02_LegitimateFinalization_AutoStartOn_StartsNextBreak() {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        vm.autoStartNextSession = true
        let interval = vm.idleReviewCoordinator.pendingIntervals[0]
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .countAsFocus)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertFalse(vm.isCountdownMutationBlocked)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
        XCTAssertTrue(vm.isTimerRunning, "Auto-start is ON; next break should start automatically")
        _ = origSessionId
    }

    // MARK: - Test Group D1-E: Restart Safety

    @MainActor
    func testD1_E01_DeferredSessionSurvivesRestart_RejectsProhibitedMutations_ResolvesCleanly() throws {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        vm.addTask(title: "Restart Task", expectedMinutes: 25)
        let taskId = vm.tasks[0].id
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // Idle to deadline
        currentTime = currentTime.addingTimeInterval(1500)
        mockActivity.setSimulatedIdle(600)
        vm.reconcileActiveTimers(at: currentTime)

        // Return from idle so interval is registered into pending queue
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        let pendingReviewId = try XCTUnwrap(vm.idleReviewCoordinator.pendingIntervals.first?.id)

        // Save is flushed to disk
        vm.persistData(force: true)

        // Reconstruct fresh TimerViewModel from persisted state
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertTrue(vm2.isDeferredCompletionPending, "Deferred completion pending flag must survive restart")
        XCTAssertEqual(vm2.deferredCompletionSessionId, origSessionId, "Same session ID must be restored")
        XCTAssertEqual(vm2.deferredCompletionTaskId, taskId, "Same task ID must be restored")
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.first?.id, pendingReviewId)

        // Prohibited actions must be rejected on the restored instance
        vm2.startTimer()
        XCTAssertFalse(vm2.isTimerRunning)
        vm2.resetFocusTimer()
        XCTAssertEqual(vm2.timeRemaining, 0)
        vm2.skipSession()
        XCTAssertEqual(vm2.completedSessions, 0)
        vm2.switchToBreak()
        XCTAssertEqual(vm2.activePreset, "Focus")

        // Resolve review on restored instance
        vm2.idleReviewCoordinator.resolve(intervalId: pendingReviewId, decision: .countAsFocus, at: currentTime)

        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.activePreset, "Short Break")

        // Flush and construct 3rd instance to verify no double completion
        vm2.persistData(force: true)
        let vm3 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm3.loadPersistedData()

        XCTAssertFalse(vm3.isDeferredCompletionPending)
        XCTAssertEqual(vm3.completedSessions, 1, "Completed sessions count must remain exactly 1 after second reload")
        XCTAssertEqual(vm3.idleReviewCoordinator.pendingIntervals.count, 0)
    }

    // MARK: - Test Group D1-F: Non-Regression

    @MainActor
    func testD1_F01_RunningFocusTimer_NormalControlsUnaffected() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertFalse(vm.isCountdownMutationBlocked)
        vm.startTimer()
        XCTAssertTrue(vm.isTimerRunning)
        XCTAssertFalse(vm.isCountdownMutationBlocked)

        vm.stopTimer()
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertFalse(vm.isCountdownMutationBlocked)
    }

    @MainActor
    func testD1_F02_IdleTimer_PresetSwitchingUnaffected() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertFalse(vm.isCountdownMutationBlocked)
        vm.switchToBreak(minutes: 5)
        XCTAssertTrue(vm.isBreakPreset)
        XCTAssertEqual(vm.totalTime, 300)

        vm.switchToFocus(minutes: 25)
        XCTAssertFalse(vm.isBreakPreset)
        XCTAssertEqual(vm.totalTime, 1500)
    }

    @MainActor
    func testD1_F03_Stopwatch_UnaffectedWhenNoDeferredSession() {
        let (vm, tempURL) = makeIsolatedViewModel()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertFalse(vm.isCountdownMutationBlocked)
        vm.startStopwatch()
        XCTAssertTrue(vm.isStopwatchRunning)

        vm.recordLap()
        XCTAssertEqual(vm.laps.count, 1)

        vm.stopStopwatch()
        XCTAssertFalse(vm.isStopwatchRunning)

        vm.resetStopwatch()
        XCTAssertEqual(vm.laps.count, 0)
    }

    // MARK: - Test Group D1-R: Review Findings Deterministic Verification

    @MainActor
    func testD1_Review_01_ShortScreenLock_NoDeadlock_LegitimateCompletion() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_lock_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        let startTime = currentTime
        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // Run until 50 seconds before deadline
        currentTime = startTime.addingTimeInterval(Double(totalSeconds) - 50)
        vm.reconcileActiveTimers(at: currentTime)

        // Lock screen 50 seconds before deadline (short lock: will last 60 seconds total < 300s threshold)
        mockActivity.setScreenLocked(true)
        vm.reconcileActiveTimers(at: currentTime)

        // Reach deadline while locked
        currentTime = startTime.addingTimeInterval(Double(totalSeconds))
        vm.reconcileActiveTimers(at: currentTime)

        // Timer reached deadline while locked -> enters deferred state
        XCTAssertTrue(vm.isDeferredCompletionPending, "Timer must be deferred when deadline reached while screen is locked")
        XCTAssertFalse(vm.isTimerRunning)

        // User unlocks 10 seconds after deadline (total locked time = 60s < 300s threshold)
        currentTime = startTime.addingTimeInterval(Double(totalSeconds) + 10)
        mockActivity.setScreenLocked(false)
        vm.reconcileActiveTimers(at: currentTime)

        // Assert: No deadlock, no fabricated review, exactly one legitimate completion!
        XCTAssertTrue(vm.idleReviewCoordinator.pendingIntervals.isEmpty, "Short lock (< threshold) must not fabricate an idle review interval")
        XCTAssertFalse(vm.isDeferredCompletionPending, "Session must not remain permanently deferred after return with no pending reviews")
        XCTAssertEqual(vm.completedSessions, 1, "Completed sessions count must be exactly 1")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Exactly one session record must be created")
        XCTAssertEqual(vm.sessionRecords.first?.sessionId, origSessionId)
        XCTAssertEqual(vm.sessionRecords.first?.durationSeconds, totalSeconds)
        XCTAssertEqual(vm.activePreset, "Short Break", "Preset must advance to Short Break")
    }

    @MainActor
    func testD1_Review_02_DeadlineReconciliationRace_ResetFocusTimer_Blocked() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_race_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        let startTime = currentTime
        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // Advance to deadline while user is idle (600s)
        currentTime = startTime.addingTimeInterval(Double(totalSeconds))
        mockActivity.setSimulatedIdle(600.0)

        // Call resetFocusTimer() at the exact instant of expiration
        // At method entry: isTimerRunning == true, isCountdownMutationBlocked == false.
        // During reconciliation in stopTimer/reconcileIfExpired: transitions to deferred completion!
        vm.resetFocusTimer()

        // Post-reconciliation guard must prevent resetFocusTimer from resetting timeRemaining to totalTime
        XCTAssertTrue(vm.isDeferredCompletionPending, "Must transition to deferred completion")
        XCTAssertEqual(vm.timeRemaining, 0, "timeRemaining must remain 0, not overwritten by totalTime")
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId, "Deferred session ID must be preserved")
    }

    @MainActor
    func testD1_Review_02_DeadlineReconciliationRace_TaskMutation_Blocked() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_race_task_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.tasks = [FocusTask(title: "Critical Task", estimatedMinutes: 25)]
        vm.activeTaskIndex = 0
        let targetTaskId = vm.tasks[0].id

        let startTime = currentTime
        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        vm.startTimer(at: currentTime)

        // Advance to deadline while user is idle
        currentTime = startTime.addingTimeInterval(Double(totalSeconds))
        mockActivity.setSimulatedIdle(600.0)

        // Remove task at exact expiration moment
        vm.removeTask(at: 0)

        // Task must not be removed during deferred expiration reconciliation
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionTaskId, targetTaskId)
        XCTAssertFalse(vm.tasks.isEmpty, "Task tied to deferred completion must not be removed during expiration race")
        XCTAssertEqual(vm.tasks[0].id, targetTaskId)
    }

    @MainActor
    func testD1_Review_03_IdleMonitoringDisabled_WithoutPendingIntervals_LegitimatelyFinalizes() {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_dis_nopending_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        let startTime = currentTime
        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        vm.startTimer(at: currentTime)

        // Reach deadline while locked
        currentTime = startTime.addingTimeInterval(Double(totalSeconds))
        mockActivity.setScreenLocked(true)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertTrue(vm.idleReviewCoordinator.pendingIntervals.isEmpty)

        // User turns off idle review while deferred session has NO pending intervals
        vm.idleReviewEnabled = false

        // Must finalize legitimately and not remain permanently unresolvable
        XCTAssertFalse(vm.isDeferredCompletionPending, "Deferred session without pending intervals must finalize when idle review is disabled")
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
    }

    @MainActor
    func testD1_Review_03_IdleMonitoringDisabled_WithPendingIntervals_PreservesReview() {
        let (vm, tempURL, _, _, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)

        // Disabling idle review when genuine pending reviews exist must NOT silently confirm disputed inactivity
        vm.idleReviewEnabled = false

        XCTAssertTrue(vm.isDeferredCompletionPending, "Session with genuine pending review must remain deferred")
        XCTAssertEqual(vm.completedSessions, 0, "Must not silently confirm session without resolution")
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1, "Pending review must be preserved")

        // Resolving the review works even with idle review disabled
        let intervalId = vm.idleReviewCoordinator.pendingIntervals[0].id
        vm.idleReviewCoordinator.resolve(intervalId: intervalId, decision: .countAsFocus)

        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.activePreset, "Short Break")
    }

    @MainActor
    func testD1_Review_04_DeferredSnapshotIntegrity_Exclude_SurvivesRestart() throws {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_snapshot_exc_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        vm.tasks = [FocusTask(title: "Architecture Spec", estimatedMinutes: 25)]
        vm.activeTaskIndex = 0
        let taskId = vm.tasks[0].id

        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        let startTime = currentTime
        let deadline = startTime.addingTimeInterval(Double(totalSeconds))
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // Accrue 15m (900s) of active work
        currentTime = startTime.addingTimeInterval(900)
        vm.reconcileActiveTimers(at: currentTime)

        // Timer reaches deadline while idle -> enters deferred state
        currentTime = deadline
        mockActivity.setSimulatedIdle(600.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertNil(vm.sessionSegmentStartDate, "sessionSegmentStartDate must be cleared at deferral")
        XCTAssertEqual(vm.segmentCreditedSeconds, 0, "segmentCreditedSeconds must be cleared at deferral")

        // User returns -> idle interval recorded with provisional credit deduction
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSegmentCreditedSeconds, 900)
        XCTAssertEqual(vm.segmentCreditedSeconds, 900)

        let intervalId = try XCTUnwrap(vm.idleReviewCoordinator.pendingIntervals.first?.id)

        // Force flush and crash restart
        vm.persistData(force: true)

        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertTrue(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.deferredCompletionSessionId, origSessionId)
        XCTAssertEqual(vm2.deferredCompletionTaskId, taskId)
        XCTAssertEqual(vm2.deferredCompletionSegmentStartDate, startTime)
        XCTAssertEqual(vm2.deferredCompletionSegmentCreditedSeconds, 900, "Provisional deduction of 600s applied upon return")
        XCTAssertNil(vm2.sessionSegmentStartDate)
        XCTAssertEqual(vm2.segmentCreditedSeconds, 0)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)

        // User excludes the 10m idle interval on the restored instance
        vm2.idleReviewCoordinator.resolve(intervalId: intervalId, decision: .excludeFromFocus, at: currentTime)

        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.activePreset, "Short Break")
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 900, "15m of work credited; 10m idle excluded")
        XCTAssertEqual(vm2.sessionRecords[0].taskId, taskId)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 900, "Task time spent must reflect deduction of excluded interval")
        XCTAssertEqual(vm2.sessionExclusionLedger.count, 1)
        XCTAssertTrue(vm2.sessionExclusionLedger[0].isAppliedToHistory)
    }

    @MainActor
    func testD1_Review_04_DeferredSnapshotIntegrity_CountAsFocus_SurvivesRestart() throws {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_snapshot_cnt_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        vm.tasks = [FocusTask(title: "Architecture Spec", estimatedMinutes: 25)]
        vm.activeTaskIndex = 0
        let taskId = vm.tasks[0].id

        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        let startTime = currentTime
        let deadline = startTime.addingTimeInterval(Double(totalSeconds))
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // Accrue 15m (900s) of active work
        currentTime = startTime.addingTimeInterval(900)
        vm.reconcileActiveTimers(at: currentTime)

        // Timer reaches deadline while idle -> enters deferred state
        currentTime = deadline
        mockActivity.setSimulatedIdle(600.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertNil(vm.sessionSegmentStartDate, "sessionSegmentStartDate must be cleared at deferral")
        XCTAssertEqual(vm.segmentCreditedSeconds, 0, "segmentCreditedSeconds must be cleared at deferral")

        // User returns -> idle interval recorded with provisional credit deduction
        mockActivity.setSimulatedIdle(0.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSegmentCreditedSeconds, 900)
        XCTAssertEqual(vm.segmentCreditedSeconds, 900)

        let intervalId = try XCTUnwrap(vm.idleReviewCoordinator.pendingIntervals.first?.id)

        // Force flush and crash restart
        vm.persistData(force: true)

        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm2.loadPersistedData()

        XCTAssertTrue(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.deferredCompletionSessionId, origSessionId)
        XCTAssertEqual(vm2.deferredCompletionTaskId, taskId)
        XCTAssertEqual(vm2.deferredCompletionSegmentStartDate, startTime)
        XCTAssertEqual(vm2.deferredCompletionSegmentCreditedSeconds, 900)
        XCTAssertNil(vm2.sessionSegmentStartDate)
        XCTAssertEqual(vm2.segmentCreditedSeconds, 0)
        XCTAssertEqual(vm2.idleReviewCoordinator.pendingIntervals.count, 1)

        // User counts as focus on the restored instance
        vm2.idleReviewCoordinator.resolve(intervalId: intervalId, decision: .countAsFocus, at: currentTime)

        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.activePreset, "Short Break")
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].durationSeconds, 1500, "Full 25m credited when user chooses Count as Focus")
        XCTAssertEqual(vm2.sessionRecords[0].taskId, taskId)
        XCTAssertEqual(vm2.tasks[0].timeSpentSeconds, 1500, "Full 25m credited to task time spent")
        XCTAssertTrue(vm2.sessionExclusionLedger.isEmpty)
    }

    @MainActor
    func testD1_Review_05_AllEntryPoints_GuardsAndDisplayConsistency() {
        let (vm, tempURL, _, origSessionId, origTaskId, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertTrue(vm.isCountdownMutationBlocked)

        // 1. Toggle Timer
        vm.toggleTimer()
        XCTAssertFalse(vm.isTimerRunning)
        XCTAssertEqual(vm.timeRemaining, 0)

        // 2. Request Reset
        vm.requestReset(isStopwatch: false)
        XCTAssertFalse(vm.showResetAlert)
        XCTAssertEqual(vm.timeRemaining, 0)

        // 3. Skip Session
        vm.skipSession()
        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertEqual(vm.activePreset, "Focus")

        // 4. Change Mode
        vm.changeMode(to: "Custom Timer")
        XCTAssertEqual(vm.activeMode, "Pomodoro")

        // 5. Presets
        vm.switchToBreak()
        XCTAssertEqual(vm.activePreset, "Focus")
        vm.switchToFocus(minutes: 50)
        XCTAssertEqual(vm.totalTime, 25 * 60)

        // 6. In-place duration adjustments
        vm.adjustCustomDuration(by: 5)
        XCTAssertEqual(vm.totalTime, 25 * 60)
        vm.setCustomDuration(minutes: 45, seconds: 0)
        XCTAssertEqual(vm.totalTime, 25 * 60)

        // 7. Preserved session restore
        vm.restorePreservedSessionIfNeeded()
        XCTAssertFalse(vm.isTimerRunning)

        // State remains locked down until review resolution
        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.deferredCompletionSessionId, origSessionId)
        XCTAssertEqual(vm.deferredCompletionTaskId, origTaskId)
    }

    // MARK: - Test Group D1-Approval: Unregistered Idle Candidate & Review Gate Verification

    @MainActor
    func testD1_Review_06_UnregisteredIdleCandidate_DisablingIdleReview_DoesNotSilentlyConfirmFocus() throws {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_unreg_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        vm.tasks = [FocusTask(title: "Audit Candidate Protection", estimatedMinutes: 25)]
        vm.activeTaskIndex = 0
        let _ = vm.tasks[0].id

        let startTime = currentTime
        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // 1. Accrue 20 minutes (1200s) of active focus
        currentTime = startTime.addingTimeInterval(1200)
        vm.reconcileActiveTimers(at: currentTime)

        // 2. User goes idle at t=1200. At countdown deadline (t=1500), inactivity reaches 300s (>= threshold)
        currentTime = startTime.addingTimeInterval(Double(totalSeconds))
        mockActivity.setSimulatedIdle(300.0)
        vm.reconcileActiveTimers(at: currentTime)

        // 3. Reached countdown deadline and entered deferred completion
        XCTAssertTrue(vm.isDeferredCompletionPending, "Timer must enter deferred completion upon expiring while user is idle")
        XCTAssertFalse(vm.isTimerRunning)

        // 4. User is still away: idle candidate exists in memory, but pendingIntervals is empty
        XCTAssertTrue(vm.idleReviewCoordinator.pendingIntervals.isEmpty, "pendingIntervals must remain empty while idle candidate is unresolved")
        XCTAssertTrue(vm.idleReviewCoordinator.isCurrentlyIdleDetected, "Coordinator must have detected idle candidate exceeding threshold")

        // 5. User toggles idleReviewEnabled OFF before the next activity reconciliation
        vm.idleReviewEnabled = false

        // 6. Verify that disputed inactive time is NOT silently converted into confirmed focus time!
        XCTAssertTrue(vm.isDeferredCompletionPending, "Session must NOT silently finalize when idle candidate is active/disputed")
        XCTAssertEqual(vm.completedSessions, 0, "Disputed inactive time must not increment completedSessions")
        XCTAssertTrue(vm.sessionRecords.isEmpty, "No confirmed session record must be created for disputed inactivity")

        // 7. On disabling or subsequent tick, coordinator flushes the completed idle interval into pending queue
        currentTime = currentTime.addingTimeInterval(1)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1, "Completed idle interval must be registered into pending queue")
        let interval = try XCTUnwrap(vm.idleReviewCoordinator.pendingIntervals.first)
        XCTAssertEqual(interval.sessionId, origSessionId)
        XCTAssertEqual(interval.eligibleDurationSeconds, 300, "Interval duration must match the 300s disputed candidate")
        XCTAssertTrue(vm.isDeferredCompletionPending, "Session must remain deferred pending review decision")

        // 8. User resolves review with .excludeFromFocus
        vm.idleReviewCoordinator.resolve(intervalId: interval.id, decision: .excludeFromFocus, at: currentTime)

        // Verify session is now legitimately finalized with the disputed time excluded
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].durationSeconds, 1200, "Exactly 20m (1200s) credited; 5m (300s) disputed idle time excluded")
        XCTAssertEqual(vm.tasks[0].timeSpentSeconds, 1200)
    }

    @MainActor
    func testD1_Review_07_CrashRelaunch_VolatileCandidateLimitation_SafeStateRestoration() throws {
        let mockActivity = MockIdleActivityProvider()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_t9d1_crash_cand_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        defer { cleanup(url: tempURL) }

        var currentTime = Date(timeIntervalSince1970: 1700000000)
        let vm = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: mockActivity)
        vm.idleThresholdSeconds = 300
        vm.idleReviewCoordinator.thresholdSeconds = 300

        let startTime = currentTime
        let totalSeconds = 25 * 60
        vm.totalTime = totalSeconds
        vm.timeRemaining = totalSeconds
        vm.startTimer(at: currentTime)
        let origSessionId = vm.activeTimerSessionId

        // Run to deadline while idle
        currentTime = startTime.addingTimeInterval(Double(totalSeconds))
        mockActivity.setSimulatedIdle(300.0)
        vm.reconcileActiveTimers(at: currentTime)

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertTrue(vm.idleReviewCoordinator.pendingIntervals.isEmpty)

        // Force save checkpoint to disk while session is deferred and candidate is volatile
        vm.persistData(force: true)

        // Simulate crash and relaunch with a fresh activity provider (user present, clean state)
        let freshActivity = MockIdleActivityProvider()
        freshActivity.setSimulatedIdle(0.0)
        freshActivity.setScreenLocked(false)
        let vm2 = TimerViewModel(storage: storage, currentDateProvider: { currentTime }, idleActivityProvider: freshActivity)
        vm2.loadPersistedData()

        // Verify deferred session state was safely restored across restart
        XCTAssertTrue(vm2.isDeferredCompletionPending, "isDeferredCompletionPending must survive crash/relaunch")
        XCTAssertEqual(vm2.deferredCompletionSessionId, origSessionId)
        XCTAssertNil(vm2.sessionSegmentStartDate, "Volatile running segment must not be revived across crash")

        // Document Task 9 architecture limitation:
        // In Task 9, candidate start is volatile in memory and not journaled to disk until materialized into pendingIntervals.
        // Task 9-D2 addresses mid-idle crash durability with candidate persistence journaling.
        // In Task 9-D1, when the restored app reconciles while the user is active with 0 pending reviews,
        // it gracefully finalizes without deadlock, memory corruption, or crash.
        vm2.reconcileActiveTimers(at: currentTime)
        XCTAssertFalse(vm2.isDeferredCompletionPending)
        XCTAssertEqual(vm2.completedSessions, 1)
        XCTAssertEqual(vm2.sessionRecords.count, 1)
        XCTAssertEqual(vm2.sessionRecords[0].sessionId, origSessionId)
    }

    @MainActor
    func testD1_Review_08_NoDoubleFinalization_WhenLastReviewDecisionResolved() throws {
        let (vm, tempURL, _, origSessionId, _, _, _) = createGenuineDeferredSession()
        defer { cleanup(url: tempURL, vm: vm) }

        XCTAssertTrue(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 0)
        XCTAssertTrue(vm.sessionRecords.isEmpty)
        XCTAssertEqual(vm.idleReviewCoordinator.pendingIntervals.count, 1)

        let intervalId = try XCTUnwrap(vm.idleReviewCoordinator.pendingIntervals.first?.id)

        // Resolve the last pending review decision
        let now = Date(timeIntervalSince1970: 1700001500)
        vm.idleReviewCoordinator.resolve(intervalId: intervalId, decision: .countAsFocus, at: now)

        // Verify single, legitimate finalization occurred
        XCTAssertFalse(vm.isDeferredCompletionPending)
        XCTAssertEqual(vm.completedSessions, 1)
        XCTAssertEqual(vm.sessionRecords.count, 1)
        XCTAssertEqual(vm.sessionRecords[0].sessionId, origSessionId)
        XCTAssertEqual(vm.activePreset, "Short Break")

        // Immediately invoke reconcileActiveTimers at subsequent timestamps
        vm.reconcileActiveTimers(at: now.addingTimeInterval(1))
        vm.reconcileActiveTimers(at: now.addingTimeInterval(5))

        // Directly invoke finalizeDeferredSession again to simulate concurrent invocation
        vm.finalizeDeferredSession(decision: .countAsFocus)
        vm.finalizeDeferredSession(decision: .excludeFromFocus)

        // Assert: completedSessions is strictly 1, sessionRecords count is strictly 1, no duplicate finalization!
        XCTAssertEqual(vm.completedSessions, 1, "Completed sessions must not be double-incremented")
        XCTAssertEqual(vm.sessionRecords.count, 1, "Duplicate session record must never be created")
        XCTAssertEqual(vm.activePreset, "Short Break", "Preset must not advance beyond next break")
    }

    @MainActor
    private func makeIsolatedViewModel() -> (TimerViewModel, URL) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow_test_\(UUID().uuidString).json")
        let storage = FocusStorageService(storageURL: tempURL)
        let vm = TimerViewModel(storage: storage)
        return (vm, tempURL)
    }
}
