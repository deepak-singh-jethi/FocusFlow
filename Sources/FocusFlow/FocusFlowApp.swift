import SwiftUI
import AppKit

// MARK: - App Delegate: Native Window Lifecycle & Menu Bar Bridge
@MainActor
public final class FocusFlowAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    public static var shared: FocusFlowAppDelegate?

    public let viewModel: TimerViewModel
    public let audioPlayer = AmbientAudioPlayer()
    public var mainWindow: NSWindow?

    /// Tracks whether the main window is currently in native macOS Full Screen mode
    @Published public var isFullScreen: Bool = false

    /// Tracks whether a close request was received while the window was in native macOS Full Screen mode
    public private(set) var isPendingCloseAfterFullScreenExit: Bool = false

    /// Counter for native fullscreen exit requests triggered by close actions
    public private(set) var fullScreenExitInitiatedCount: Int = 0

    /// Injectable hook to intercept or override fullscreen exit during tests. Defaults to nil (calls `sender.toggleFullScreen(nil)`).
    public var fullScreenExitAction: ((NSWindow) -> Void)? = nil

    public override init() {
        self.viewModel = TimerViewModel()
        super.init()
        Self.shared = self
    }

    public init(viewModel: TimerViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.styleMask.contains(.fullScreen) {
            guard !isPendingCloseAfterFullScreenExit else {
                return false
            }
            isPendingCloseAfterFullScreenExit = true
            fullScreenExitInitiatedCount += 1

            if let customAction = fullScreenExitAction {
                customAction(sender)
            } else {
                if sender.contentViewController == nil {
                    let fallbackVC = NSViewController()
                    fallbackVC.view = NSView()
                    sender.contentViewController = fallbackVC
                }
                sender.toggleFullScreen(nil)
            }
            return false
        }

        isPendingCloseAfterFullScreenExit = false
        sender.orderOut(nil)
        return false
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let main = mainWindow {
            guard window === main else { return }
        }
        isFullScreen = true
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let main = mainWindow {
            guard window === main else { return }
        }
        isFullScreen = false
        guard let window = (notification.object as? NSWindow) ?? mainWindow else { return }
        if isPendingCloseAfterFullScreenExit {
            isPendingCloseAfterFullScreenExit = false
            window.orderOut(nil)
        }
    }

    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard isPendingCloseAfterFullScreenExit else {
            return
        }

        isPendingCloseAfterFullScreenExit = false
        // Exit failed: leave the window visible and usable.
        // Never call orderOut(nil) on a window that may still occupy a native fullscreen Space.
    }

    public func applicationWillTerminate(_ notification: Notification) {
        viewModel.handleAppTermination()
    }

    public func showMainWindow() {
        isPendingCloseAfterFullScreenExit = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            window.deminiaturize(nil)
            return
        }

        let contentView = ContentView(viewModel: viewModel, audioPlayer: audioPlayer)
            .preferredColorScheme(.dark)
            .frame(minWidth: 850, minHeight: 600)

        let hosting = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1050, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1050, height: 700))
        window.minSize = NSSize(width: 850, height: 600)
        window.title = "FocusFlow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - App Entry Point
@main
public struct FocusFlowApp: App {
    @NSApplicationDelegateAdaptor(FocusFlowAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarCompanionView(viewModel: appDelegate.viewModel, audioPlayer: appDelegate.audioPlayer)
        } label: {
            MenuBarLabelView(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
