import Foundation
import UserNotifications

// MARK: - Native macOS Notification Service
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    /// Verifies if running inside an actual app bundle and not inside a test runner / CLI tool
    public static var isAvailable: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        if NSClassFromString("XCTestCase") != nil {
            return false
        }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    private override init() {
        super.init()
        if Self.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public func requestAuthorization() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func sendSessionCompleteNotification(presetName: String, isBreak: Bool) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        if isBreak {
            content.title = "Break Finished"
            content.body = "Your \(presetName.lowercased()) is complete. Ready to resume focus?"
        } else {
            content.title = "Focus Session Complete"
            content.body = "Great work! Take a well-deserved break."
        }
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // Deliver notification banner even if app is foreground
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
