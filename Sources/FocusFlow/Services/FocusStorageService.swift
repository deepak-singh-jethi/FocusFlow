import Foundation

// MARK: - Persistent App State Payload
public struct FocusAppData: Codable {
    public var tasks: [FocusTask]
    public var focusedSeconds: Int
    public var completedSessions: Int
    public var notes: [String]
    public var dailyGoalHours: Int
    public var totalSessions: Int
    public var autoStartNextSession: Bool
    public var activePreset: String
    public var clockStyle: String

    public init(
        tasks: [FocusTask] = [],
        focusedSeconds: Int = 0,
        completedSessions: Int = 0,
        notes: [String] = [],
        dailyGoalHours: Int = 4,
        totalSessions: Int = 4,
        autoStartNextSession: Bool = false,
        activePreset: String = "Focus",
        clockStyle: String = "Digital"
    ) {
        self.tasks = tasks
        self.focusedSeconds = focusedSeconds
        self.completedSessions = completedSessions
        self.notes = notes
        self.dailyGoalHours = dailyGoalHours
        self.totalSessions = totalSessions
        self.autoStartNextSession = autoStartNextSession
        self.activePreset = activePreset
        self.clockStyle = clockStyle
    }
}

// MARK: - Focus Storage Service (Atomic File Storage)
public final class FocusStorageService {
    public static let shared = FocusStorageService()
    private let fileManager = FileManager.default

    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let focusFlowDir = appSupport.appendingPathComponent("FocusFlow", isDirectory: true)
        if !fileManager.fileExists(atPath: focusFlowDir.path) {
            try? fileManager.createDirectory(at: focusFlowDir, withIntermediateDirectories: true)
        }
        return focusFlowDir.appendingPathComponent("focusflow_data.json")
    }

    public init() {}

    public func load() -> FocusAppData? {
        guard fileManager.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(FocusAppData.self, from: data)
    }

    public func save(_ data: FocusAppData) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let encoded = try? encoder.encode(data) {
            try? encoded.write(to: storageURL, options: [.atomic])
        }
    }
}
