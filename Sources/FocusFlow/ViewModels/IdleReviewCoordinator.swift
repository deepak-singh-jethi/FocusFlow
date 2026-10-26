import Foundation
import Combine
import SwiftUI

// MARK: - Idle Coordinator State
public enum IdleCoordinatorState: Equatable, Sendable {
    case inactive
    case monitoring
    case idleCandidate(since: Date)
    case idleDetected(startedAt: Date)
    case pendingReview
    case reviewing(intervalId: UUID)

    public var isIdleDetected: Bool {
        if case .idleDetected = self { return true }
        return false
    }

    public var isIdleCandidate: Bool {
        if case .idleCandidate = self { return true }
        return false
    }

    public var isReviewing: Bool {
        if case .reviewing = self { return true }
        return false
    }
}

// MARK: - Idle Review Coordinator
@MainActor
public class IdleReviewCoordinator: ObservableObject {
    // Configuration
    @Published public var isEnabled: Bool = true
    @Published public var thresholdSeconds: Int = 300 // Default 5 minutes
    public static let supportedThresholds: [Int] = [120, 300, 600, 900] // 2m, 5m, 10m, 15m

    // Observable State
    @Published public private(set) var state: IdleCoordinatorState = .monitoring
    @Published public var pendingIntervals: [IdleReviewInterval] = [] {
        didSet {
            onPendingCountChange?(pendingIntervals.count)
            if activeReviewInterval == nil, let first = pendingIntervals.first {
                activeReviewInterval = first
                state = .reviewing(intervalId: first.id)
            } else if pendingIntervals.isEmpty {
                activeReviewInterval = nil
                if case .reviewing = state {
                    state = .monitoring
                }
            }
        }
    }
    @Published public var activeReviewInterval: IdleReviewInterval? = nil

    public var isCurrentlyIdleDetected: Bool {
        return isCurrentlyIdle || state.isIdleDetected
    }

    // Injected Dependencies
    public let activityProvider: IdleActivityProvider
    public var currentDateProvider: () -> Date

    // Tracking state
    private var currentCandidateStart: Date? = nil
    private var isCurrentlyIdle: Bool = false
    private var sleepStartDate: Date? = nil
    private var lockStartDate: Date? = nil

    // Callbacks
    public var onResolution: ((_ interval: IdleReviewInterval, _ decision: IdleReviewDecision) -> Void)? = nil
    public var onPendingCountChange: ((_ count: Int) -> Void)? = nil
    public var onIntervalCreated: ((_ interval: inout IdleReviewInterval) -> Void)? = nil

    public init(
        activityProvider: IdleActivityProvider = MacOSNativeIdleActivityProvider(),
        currentDateProvider: @escaping () -> Date = Date.init,
        isEnabled: Bool = true,
        thresholdSeconds: Int = 300
    ) {
        self.activityProvider = activityProvider
        self.currentDateProvider = currentDateProvider
        self.isEnabled = isEnabled
        self.thresholdSeconds = thresholdSeconds
    }

    // MARK: - Periodic Engine Tick
    /// Evaluates system idle state against the active timer/stopwatch session.
    public func tick(
        now: Date,
        isSessionActive: Bool,
        sessionType: String,
        sessionId: UUID,
        taskId: UUID?,
        sessionDeadline: Date? = nil,
        sessionStartDate: Date? = nil
    ) {
        // If feature disabled, break preset, or session not running:
        guard isEnabled && isSessionActive && sessionType != "Break" else {
            if isCurrentlyIdle, let candidateStart = currentCandidateStart {
                // Session expired or stopped while user was away
                recordCompletedIdleInterval(
                    candidateStart: candidateStart,
                    now: now,
                    sessionId: sessionId,
                    sessionType: sessionType,
                    taskId: taskId,
                    sessionDeadline: sessionDeadline,
                    sessionStartDate: sessionStartDate
                )
                isCurrentlyIdle = false
                currentCandidateStart = nil
            }
            if activeReviewInterval != nil {
                state = .reviewing(intervalId: activeReviewInterval!.id)
            } else if !pendingIntervals.isEmpty {
                state = .pendingReview
            } else {
                state = .inactive
            }
            return
        }

        // Determine current idle duration from provider or screen lock
        let isLocked = activityProvider.isScreenLocked()
        let rawIdleSeconds = activityProvider.systemIdleDuration(at: now)

        if isLocked {
            if lockStartDate == nil {
                lockStartDate = rawIdleSeconds > 0 ? now.addingTimeInterval(-rawIdleSeconds) : now
                if currentCandidateStart == nil {
                    currentCandidateStart = lockStartDate
                }
            }
            let lockedDuration = now.timeIntervalSince(lockStartDate!)
            if lockedDuration >= Double(thresholdSeconds) {
                isCurrentlyIdle = true
                state = .idleDetected(startedAt: currentCandidateStart ?? lockStartDate ?? now)
            } else {
                state = .idleCandidate(since: currentCandidateStart ?? lockStartDate ?? now)
            }
            return
        }

        // Screen is not locked. Check if user just unlocked after an idle lock period:
        if let lockStart = lockStartDate {
            let lockedDuration = now.timeIntervalSince(lockStart)
            lockStartDate = nil
            if lockedDuration >= Double(thresholdSeconds) || isCurrentlyIdle {
                // User unlocked and returned after being locked/idle!
                let candidateStart = currentCandidateStart ?? lockStart
                recordCompletedIdleInterval(
                    candidateStart: candidateStart,
                    now: now,
                    sessionId: sessionId,
                    sessionType: sessionType,
                    taskId: taskId,
                    sessionDeadline: sessionDeadline,
                    sessionStartDate: sessionStartDate
                )
                isCurrentlyIdle = false
                currentCandidateStart = nil

                if let active = activeReviewInterval {
                    state = .reviewing(intervalId: active.id)
                } else if !pendingIntervals.isEmpty {
                    state = .pendingReview
                } else {
                    state = .monitoring
                }
                return
            }
        }

        // Normal unlocked activity monitoring
        if rawIdleSeconds >= Double(thresholdSeconds) {
            // Threshold reached or exceeded
            if currentCandidateStart == nil {
                // Anchor to exact last activity date
                let lastActivity = now.addingTimeInterval(-rawIdleSeconds)
                let boundedStart: Date
                if let sessionStart = sessionStartDate {
                    boundedStart = max(lastActivity, sessionStart)
                } else {
                    boundedStart = lastActivity
                }
                currentCandidateStart = boundedStart
            }
            isCurrentlyIdle = true
            state = .idleDetected(startedAt: currentCandidateStart ?? now)

        } else if isCurrentlyIdle {
            // Fix 6 & Part F.1: User was idle and has now returned (rawIdleSeconds < thresholdSeconds)!
            // Do not require rawIdleSeconds < 1.0; detect return even if polling tick missed sub-second window.
            let returnTime = now.addingTimeInterval(-max(0, rawIdleSeconds))
            if let candidateStart = currentCandidateStart {
                recordCompletedIdleInterval(
                    candidateStart: candidateStart,
                    now: returnTime,
                    sessionId: sessionId,
                    sessionType: sessionType,
                    taskId: taskId,
                    sessionDeadline: sessionDeadline,
                    sessionStartDate: sessionStartDate
                )
            }
            isCurrentlyIdle = false
            currentCandidateStart = nil

            // Update UI state
            if let active = activeReviewInterval {
                state = .reviewing(intervalId: active.id)
            } else if !pendingIntervals.isEmpty {
                state = .pendingReview
            } else {
                state = .monitoring
            }

        } else if rawIdleSeconds > 0 {
            // Idle candidate (inactivity begun, but threshold not yet reached)
            let candidateStart = now.addingTimeInterval(-rawIdleSeconds)
            currentCandidateStart = candidateStart
            state = .idleCandidate(since: candidateStart)

        } else {
            // Fully active
            currentCandidateStart = nil

            // Update UI state
            if let active = activeReviewInterval {
                state = .reviewing(intervalId: active.id)
            } else if !pendingIntervals.isEmpty {
                state = .pendingReview
            } else {
                state = .monitoring
            }
        }
    }

    // MARK: - Interval Creation & Authoritative Registration
    @discardableResult
    private func registerIdleInterval(
        boundedStart: Date,
        boundedEnd: Date,
        durationSecs: Int,
        sessionId: UUID,
        sessionType: String,
        taskId: UUID?,
        isEstimated: Bool = false
    ) -> IdleReviewInterval? {
        guard durationSecs >= thresholdSeconds else { return nil }

        // Deduplicate against existing intervals
        let isDuplicate = pendingIntervals.contains { existing in
            existing.sessionId == sessionId &&
            abs(existing.startTime.timeIntervalSince(boundedStart)) < 2.0 &&
            abs(existing.endTime.timeIntervalSince(boundedEnd)) < 2.0
        }
        guard !isDuplicate else { return nil }

        let interval = IdleReviewInterval(
            sessionId: sessionId,
            sessionType: sessionType,
            taskId: taskId,
            startTime: boundedStart,
            endTime: boundedEnd,
            eligibleDurationSeconds: durationSecs,
            status: .pending,
            isEstimated: isEstimated,
            isProvisionalCreditDeducted: false
        )

        // 1. Authoritative pending queue insertion FIRST
        pendingIntervals.append(interval)

        // 2. Auto-surface oldest pending review if none active
        if activeReviewInterval == nil {
            activeReviewInterval = pendingIntervals.first
            if let active = activeReviewInterval {
                state = .reviewing(intervalId: active.id)
            } else {
                state = .pendingReview
            }
        } else {
            state = .reviewing(intervalId: activeReviewInterval!.id)
        }

        // 3. Atomically perform provisional accounting adjustment and forced snapshot persistence
        let registeredIndex = pendingIntervals.count - 1
        onIntervalCreated?(&pendingIntervals[registeredIndex])

        return pendingIntervals[registeredIndex]
    }

    private func recordCompletedIdleInterval(
        candidateStart: Date,
        now: Date,
        sessionId: UUID,
        sessionType: String,
        taskId: UUID?,
        sessionDeadline: Date?,
        sessionStartDate: Date?
    ) {
        // Bound interval strictly by session start and session deadline (Scenario B)
        let boundedStart: Date
        if let sessionStart = sessionStartDate {
            boundedStart = max(candidateStart, sessionStart)
        } else {
            boundedStart = candidateStart
        }

        let boundedEnd: Date
        if let deadline = sessionDeadline {
            // Discard any inactivity elapsed after timer deadline
            boundedEnd = min(now, deadline)
        } else {
            boundedEnd = now
        }

        guard boundedEnd > boundedStart else { return }
        let durationSecs = Int(boundedEnd.timeIntervalSince(boundedStart))

        registerIdleInterval(
            boundedStart: boundedStart,
            boundedEnd: boundedEnd,
            durationSecs: durationSecs,
            sessionId: sessionId,
            sessionType: sessionType,
            taskId: taskId,
            isEstimated: false
        )
    }

    // MARK: - Sleep, Wake & Screen Lock Handling
    public func handleSleep(at now: Date) {
        sleepStartDate = now
    }

    public func handleScreenLock(at now: Date) {
        lockStartDate = now
        if currentCandidateStart == nil {
            currentCandidateStart = now
        }
    }

    public func handleScreenUnlock(at now: Date) {
        // State will resolve on next tick when user input is processed
    }

    public func handleWake(
        at now: Date,
        isSessionActive: Bool,
        sessionType: String,
        sessionId: UUID,
        taskId: UUID?,
        sessionDeadline: Date? = nil,
        sessionStartDate: Date? = nil
    ) {
        guard let sleepStart = sleepStartDate else {
            currentCandidateStart = nil
            isCurrentlyIdle = false
            return
        }
        sleepStartDate = nil

        guard isEnabled && isSessionActive && sessionType != "Break" else {
            isCurrentlyIdle = false
            currentCandidateStart = nil
            return
        }

        let boundedStart: Date
        if let sessionStart = sessionStartDate {
            boundedStart = max(sleepStart, sessionStart)
        } else {
            boundedStart = sleepStart
        }

        let boundedEnd: Date
        if let deadline = sessionDeadline {
            boundedEnd = min(now, deadline)
        } else {
            boundedEnd = now
        }

        guard boundedEnd > boundedStart else {
            isCurrentlyIdle = false
            currentCandidateStart = nil
            return
        }
        let durationSecs = Int(boundedEnd.timeIntervalSince(boundedStart))

        registerIdleInterval(
            boundedStart: boundedStart,
            boundedEnd: boundedEnd,
            durationSecs: durationSecs,
            sessionId: sessionId,
            sessionType: sessionType,
            taskId: taskId,
            isEstimated: true
        )

        isCurrentlyIdle = false
        currentCandidateStart = nil
    }

    // MARK: - Resolution & Review Management
    public func resolve(intervalId: UUID, decision: IdleReviewDecision, at now: Date = Date()) {
        guard let index = pendingIntervals.firstIndex(where: { $0.id == intervalId }) else {
            return
        }

        var interval = pendingIntervals[index]

        switch decision {
        case .countAsFocus:
            interval.status = .included
            interval.decisionDate = now
            pendingIntervals.remove(at: index)
            if activeReviewInterval?.id == intervalId {
                activeReviewInterval = pendingIntervals.first
            }
            onResolution?(interval, .countAsFocus)

        case .excludeFromFocus:
            interval.status = .excluded
            interval.decisionDate = now
            pendingIntervals.remove(at: index)
            if activeReviewInterval?.id == intervalId {
                activeReviewInterval = pendingIntervals.first
            }
            onResolution?(interval, .excludeFromFocus)

        case .decideLater:
            // Stays in pendingIntervals
            if activeReviewInterval?.id == intervalId {
                activeReviewInterval = nil
            }
            onResolution?(interval, .decideLater)
        }

        if let nextActive = activeReviewInterval {
            state = .reviewing(intervalId: nextActive.id)
        } else if !pendingIntervals.isEmpty {
            state = .pendingReview
        } else {
            state = .monitoring
        }
    }

    public func openReview(for interval: IdleReviewInterval) {
        activeReviewInterval = interval
        state = .reviewing(intervalId: interval.id)
    }

    public func dismissActiveReviewToDecideLater() {
        activeReviewInterval = nil
        if !pendingIntervals.isEmpty {
            state = .pendingReview
        } else {
            state = .monitoring
        }
    }

    public func setThreshold(minutes: Int) {
        let seconds = minutes * 60
        guard Self.supportedThresholds.contains(seconds) else { return }
        thresholdSeconds = seconds
    }
}
