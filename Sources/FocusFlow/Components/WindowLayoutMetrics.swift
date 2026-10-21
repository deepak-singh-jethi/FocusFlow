import SwiftUI
import AppKit

// MARK: - Window Layout Metrics (Authoritative macOS Window Geometry)
/// Centralizes window-aware layout metrics, chrome clearances, and responsive boundaries.
/// Guarantees that Sidebar branding and Dashboard/Page headers align to the same baseline,
/// clears the native traffic-light titlebar in windowed mode, and adapts smoothly in fullscreen.
public enum WindowLayoutMetrics {
    /// Native titlebar chrome height in standard windowed mode (standard macOS titlebar: 28pt)
    public static let titlebarChromeHeight: CGFloat = 28.0

    /// Intentional breathing room below titlebar chrome in standard windowed mode (0.0pt for native titlebar alignment)
    public static let standardBreathingRoom: CGFloat = 0.0

    /// Legacy alias for compatibility
    public static var windowedBreathingRoom: CGFloat { standardBreathingRoom }

    /// Authoritative total top clearance in standard windowed mode (28.0pt, native macOS titlebar height).
    /// Places interactive content cleanly below traffic lights while eliminating unnecessary top voids.
    public static let standardTopClearance: CGFloat = 28.0

    /// Authoritative total top clearance in Full Screen mode when native titlebar/traffic lights are revealed or present (40pt).
    /// Guarantees that FocusFlow branding, Custom Timer heading, and collapse button are NEVER clipped beneath the 32pt titlebar.
    public static let fullScreenRevealedClearance: CGFloat = 40.0

    /// Authoritative top clearance in Full Screen mode when native titlebar chrome is genuinely absent (20pt).
    /// Avoids large unnecessary margins when titlebar is autohidden.
    public static let fullScreenHiddenChromeClearance: CGFloat = 20.0

    /// Authoritative total top clearance in native macOS Full Screen mode (defaults to revealed chrome clearance for safety)
    public static var fullScreenTopClearance: CGFloat { fullScreenRevealedClearance }

    /// Breathing room between a banner (storage error / recovery) and page content
    public static let postBannerSpacing: CGFloat = 12.0

    /// Breathing room between a persistent cross-mode mini-bar and page content
    public static let postMiniBarSpacing: CGFloat = 12.0

    /// Authoritative top clearance dynamically adapted based on fullscreen state and titlebar reveal.
    public static func topClearance(isFullScreen: Bool, isTitlebarRevealed: Bool = true) -> CGFloat {
        if isFullScreen {
            return isTitlebarRevealed ? fullScreenRevealedClearance : fullScreenHiddenChromeClearance
        } else {
            return standardTopClearance
        }
    }

    /// AppKit-derived authoritative clearance dynamically computed from an actual NSWindow instance.
    public static func topClearance(for window: NSWindow?) -> CGFloat {
        guard let window = window else {
            return standardTopClearance
        }
        let frameHeight = window.frame.height
        let contentHeight = window.contentLayoutRect.height
        let chromeHeight = max(0, frameHeight - contentHeight)

        if window.styleMask.contains(.fullScreen) {
            let isChromeVisible: Bool = {
                if chromeHeight >= 24.0 { return true }
                if let closeBtn = window.standardWindowButton(.closeButton),
                   !closeBtn.isHidden, closeBtn.alphaValue > 0.1, closeBtn.window != nil {
                    return true
                }
                return false
            }()
            return isChromeVisible ? fullScreenRevealedClearance : fullScreenHiddenChromeClearance
        } else {
            return standardTopClearance
        }
    }
}
