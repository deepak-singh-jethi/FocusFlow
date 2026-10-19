import SwiftUI
import Combine
import AppKit

// MARK: - Time Input Field Identifier
public enum TimeInputField: Hashable, Sendable {
    case minutes
    case seconds
}

// MARK: - Time Input Validation Error
public enum TimeInputValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case belowMinimum(seconds: Int, minimum: Int)
    case exceedsMaximum(seconds: Int, maximum: Int)
    case invalidSeconds(seconds: Int)
    case invalidMinutes(minutes: Int)
    case nonNumeric

    public var description: String {
        switch self {
        case .empty:
            return "Please enter a time (min 00:05)"
        case .belowMinimum:
            return "Minimum timer duration is 00:05"
        case .exceedsMaximum, .invalidMinutes:
            return "Maximum timer duration is 360:59"
        case .invalidSeconds:
            return "Seconds must be between 00 and 59"
        case .nonNumeric:
            return "Please enter valid numeric digits"
        }
    }

    public var localizedDescription: String {
        description
    }
}

// MARK: - Time Input Controller & State Machine
/// Reusable, deterministic state machine for timer duration editing.
/// Enforces a strict Draft -> Validate -> Commit transaction model.
/// Typing never mutates authoritative timer duration until explicit successful commit.
@MainActor
public class TimeInputController: ObservableObject {
    // Current field actively being edited (nil = display mode)
    @Published public var activeEditingField: TimeInputField? = nil

    // Draft or formatted display strings
    @Published public var inputMinutes: String = "25"
    @Published public var inputSeconds: String = "00"

    // Validation state
    @Published public var validationError: TimeInputValidationError? = nil
    @Published public var hasInvalidDraft: Bool = false

    // Authoritative committed snapshot
    public private(set) var committedMinutes: Int = 25
    public private(set) var committedSeconds: Int = 0
    public var committedTotalSeconds: Int {
        committedMinutes * 60 + committedSeconds
    }

    public var isEditing: Bool {
        activeEditingField != nil
    }

    // Snapshot taken when editing starts; restored on cancel/Escape
    private var snapshotMinutes: Int = 25
    private var snapshotSeconds: Int = 0

    // Duration limits from TimerViewModel
    public static let minDurationSeconds: Int = TimerViewModel.minSupportedTimerDuration // 5s
    public static let maxDurationSeconds: Int = TimerViewModel.maxSupportedTimerDuration // 360m 59s
    public static let maxMinutes: Int = 360
    public static let maxSeconds: Int = 59

    // Callbacks
    public var onCommit: ((_ minutes: Int, _ seconds: Int) -> Void)? = nil
    public var onCancel: (() -> Void)? = nil

    public init(totalTime: Int = 25 * 60) {
        let m = totalTime >= 60 ? totalTime / 60 : 0
        let s = totalTime % 60
        self.committedMinutes = m
        self.committedSeconds = s
        self.snapshotMinutes = m
        self.snapshotSeconds = s
        self.inputMinutes = Self.formatMinutes(m)
        self.inputSeconds = Self.formatSeconds(s)
    }

    // MARK: - Display Formatting
    public static func formatMinutes(_ minutes: Int) -> String {
        if minutes < 10 {
            return String(format: "%02d", max(0, minutes))
        } else {
            return "\(minutes)"
        }
    }

    public static func formatSeconds(_ seconds: Int) -> String {
        return String(format: "%02d", max(0, min(59, seconds)))
    }

    // MARK: - Synchronize from External ViewModel
    /// Synchronizes committed duration snapshot from external totalTime.
    /// Never clobbers an active user draft while editing.
    public func sync(from totalSeconds: Int) {
        guard activeEditingField == nil && !hasInvalidDraft else { return }
        let m = totalSeconds >= 60 ? totalSeconds / 60 : 0
        let s = totalSeconds % 60
        committedMinutes = m
        committedSeconds = s
        snapshotMinutes = m
        snapshotSeconds = s
        inputMinutes = Self.formatMinutes(m)
        inputSeconds = Self.formatSeconds(s)
        validationError = nil
        hasInvalidDraft = false
    }

    // MARK: - Editing Lifecycle
    public func startEditing(_ field: TimeInputField) {
        if activeEditingField == nil && !hasInvalidDraft {
            snapshotMinutes = committedMinutes
            snapshotSeconds = committedSeconds
            // Initialize draft with plain unpadded minutes if >= 10, or 2-digit
            inputMinutes = "\(committedMinutes)"
            inputSeconds = String(format: "%02d", committedSeconds)
        }
        activeEditingField = field
        validationError = nil
        hasInvalidDraft = false
    }

    public func updateDraft(field: TimeInputField, text: String) {
        let digits = text.filter { $0.isNumber }
        switch field {
        case .minutes:
            let capped = String(digits.prefix(3))
            inputMinutes = capped
        case .seconds:
            let capped = String(digits.prefix(2))
            inputSeconds = capped
        }
        validationError = nil
        hasInvalidDraft = false
        // CRITICAL: Do NOT mutate committed duration or call onCommit here!
    }

    public func commitAndSwitchField(to nextField: TimeInputField) {
        let cleanMStr = inputMinutes.filter { $0.isNumber }
        let cleanSStr = inputSeconds.filter { $0.isNumber }

        inputMinutes = cleanMStr.isEmpty ? "\(snapshotMinutes)" : cleanMStr
        inputSeconds = cleanSStr.isEmpty ? String(format: "%02d", snapshotSeconds) : cleanSStr

        activeEditingField = nextField
        validationError = nil
        hasInvalidDraft = false
    }

    public func validateDraft() -> Result<(minutes: Int, seconds: Int), TimeInputValidationError> {
        let cleanMStr = inputMinutes.filter { $0.isNumber }
        let cleanSStr = inputSeconds.filter { $0.isNumber }

        guard !cleanMStr.isEmpty || !cleanSStr.isEmpty else {
            return .failure(.empty)
        }

        let m = cleanMStr.isEmpty ? 0 : (Int(cleanMStr) ?? 0)
        let s = cleanSStr.isEmpty ? 0 : (Int(cleanSStr) ?? 0)

        if s > Self.maxSeconds {
            return .failure(.invalidSeconds(seconds: s))
        }
        if m > Self.maxMinutes {
            return .failure(.invalidMinutes(minutes: m))
        }

        let total = m * 60 + s
        if total < Self.minDurationSeconds {
            return .failure(.belowMinimum(seconds: total, minimum: Self.minDurationSeconds))
        }
        if total > Self.maxDurationSeconds {
            return .failure(.exceedsMaximum(seconds: total, maximum: Self.maxDurationSeconds))
        }

        return .success((minutes: m, seconds: s))
    }

    @discardableResult
    public func commitEditing() -> Bool {
        guard activeEditingField != nil || hasInvalidDraft else {
            return true
        }
        switch validateDraft() {
        case .success(let duration):
            committedMinutes = duration.minutes
            committedSeconds = duration.seconds
            snapshotMinutes = duration.minutes
            snapshotSeconds = duration.seconds
            inputMinutes = Self.formatMinutes(duration.minutes)
            inputSeconds = Self.formatSeconds(duration.seconds)
            activeEditingField = nil
            validationError = nil
            hasInvalidDraft = false
            onCommit?(duration.minutes, duration.seconds)
            return true

        case .failure(let error):
            validationError = error
            hasInvalidDraft = true
            // Keep draft visible with validation error feedback so user can see and fix the error.
            // committedMinutes and committedSeconds remain safely preserved at the previous valid snapshot.
            return false
        }
    }

    public func stopEditing() {
        commitEditing()
    }

    public func cancelEditing() {
        inputMinutes = Self.formatMinutes(snapshotMinutes)
        inputSeconds = Self.formatSeconds(snapshotSeconds)
        committedMinutes = snapshotMinutes
        committedSeconds = snapshotSeconds
        activeEditingField = nil
        validationError = nil
        hasInvalidDraft = false
        onCancel?()
    }

    // MARK: - Stepper Adjustments (Seconds-Preserving)
    public func adjustMinutes(by delta: Int) {
        if activeEditingField != nil || hasInvalidDraft {
            cancelEditing()
        }
        let currentM = committedMinutes
        let currentS = committedSeconds // Preserve existing seconds!
        let newM = min(max(currentM + delta, 0), Self.maxMinutes)
        let newTotal = newM * 60 + currentS

        guard newTotal >= Self.minDurationSeconds else {
            return
        }

        committedMinutes = newM
        committedSeconds = currentS
        snapshotMinutes = newM
        snapshotSeconds = currentS
        inputMinutes = Self.formatMinutes(newM)
        inputSeconds = Self.formatSeconds(currentS)

        onCommit?(newM, currentS)
    }

    // MARK: - Preset Selection
    public func selectPreset(minutes: Int, seconds: Int = 0) {
        if activeEditingField != nil || hasInvalidDraft {
            cancelEditing()
        }
        let safeM = min(max(minutes, 0), Self.maxMinutes)
        let safeS = min(max(seconds, 0), Self.maxSeconds)
        committedMinutes = safeM
        committedSeconds = safeS
        snapshotMinutes = safeM
        snapshotSeconds = safeS
        inputMinutes = Self.formatMinutes(safeM)
        inputSeconds = Self.formatSeconds(safeS)

        onCommit?(safeM, safeS)
    }
}
