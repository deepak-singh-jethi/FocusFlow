import SwiftUI
import AppKit

// MARK: - App Delegate: Native Window Lifecycle & Menu Bar Bridge
@MainActor
public final class FocusFlowAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    public static var shared: FocusFlowAppDelegate?

    public let viewModel: TimerViewModel
    public let audioPlayer = AmbientAudioPlayer()
    public var mainWindow: NSWindow?

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
        sender.orderOut(nil)
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        viewModel.handleAppTermination()
    }

    public func showMainWindow() {
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
