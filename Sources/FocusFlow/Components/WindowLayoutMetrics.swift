import SwiftUI
import AppKit

// MARK: - Window Layout Metrics (Authoritative macOS Window Geometry)
/// Centralizes window-aware layout metrics, chrome clearances, and responsive boundaries.
/// Guarantees that Sidebar branding and Dashboard/Page headers align to the same baseline,
/// clears the native traffic-light titlebar in windowed mode, and adapts smoothly in fullscreen.
public enum WindowLayoutMetrics {
    /// Native titlebar chrome height in standard windowed mode (traffic lights region: ~28-32pt)
    public static let titlebarChromeHeight: CGFloat = 32.0

    /// Intentional breathing room below titlebar chrome in standard windowed mode (8.0pt)
    /// Traffic lights sit at y = 9pt..23pt. Chrome ends at 32pt.
    /// 8pt breathing room places interactive content at 40pt (17pt below traffic lights, 8pt below chrome).
    public static let standardBreathingRoom: CGFloat = 8.0

    /// Legacy alias for compatibility
    public static var windowedBreathingRoom: CGFloat { standardBreathingRoom }

    /// Authoritative total top clearance in standard windowed mode (32 + 8 = 40pt).
    /// Eliminates the 29pt empty void while preserving comfortable breathing room below traffic lights.
    public static let standardTopClearance: CGFloat = titlebarChromeHeight + standardBreathingRoom

    /// Authoritative total top clearance in Full Screen mode when native titlebar/traffic lights are revealed or present (40pt).
    /// Guarantees that FocusFlow branding, Custom Timer heading, and collapse button are NEVER clipped beneath the 32pt titlebar.
    public static let fullScreenRevealedClearance: CGFloat = titlebarChromeHeight + standardBreathingRoom

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
    /// Distinguishes system chrome clearance from intentional visual breathing room.
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
            return isChromeVisible ? standardTopClearance : fullScreenHiddenChromeClearance
        } else {
            let effectiveChrome = chromeHeight > 0 ? chromeHeight : titlebarChromeHeight
            return effectiveChrome + standardBreathingRoom
        }
    }
}
