import Foundation
import CoreGraphics
import AppKit

// MARK: - Idle Activity Provider Protocol
public protocol IdleActivityProvider: AnyObject, Sendable {
    func systemIdleDuration(at date: Date) -> TimeInterval
    func isScreenLocked() -> Bool
}

// MARK: - Production macOS Native Idle Activity Provider
public final class MacOSNativeIdleActivityProvider: IdleActivityProvider, @unchecked Sendable {
    private static let anyInputEventType = CGEventType(rawValue: ~0)!
    private let lock = NSLock()
    private var screenLocked: Bool = false

    public init() {
        // Observe screen lock / unlock distributed notifications
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func screenDidLock() {
        lock.lock()
        screenLocked = true
        lock.unlock()
    }

    @objc private func screenDidUnlock() {
        lock.lock()
        screenLocked = false
        lock.unlock()
    }

    public func systemIdleDuration(at date: Date) -> TimeInterval {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
        return max(0.0, idle)
    }

    public func isScreenLocked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return screenLocked
    }
}

// MARK: - Deterministic Mock Idle Activity Provider for Unit Testing
public final class MockIdleActivityProvider: IdleActivityProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var simulatedIdle: TimeInterval = 0.0
    private var screenLocked: Bool = false

    public init(simulatedIdle: TimeInterval = 0.0, screenLocked: Bool = false) {
        self.simulatedIdle = simulatedIdle
        self.screenLocked = screenLocked
    }

    public func setSimulatedIdle(_ seconds: TimeInterval) {
        lock.lock()
        simulatedIdle = max(0.0, seconds)
        lock.unlock()
    }

    public func setScreenLocked(_ locked: Bool) {
        lock.lock()
        screenLocked = locked
        lock.unlock()
    }

    public func systemIdleDuration(at date: Date) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return simulatedIdle
    }

    public func isScreenLocked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return screenLocked
    }
}
