import SwiftUI

// MARK: - App Entry Point
@main
public struct FocusFlowApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 850, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
