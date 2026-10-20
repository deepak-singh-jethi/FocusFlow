import SwiftUI
import AppKit

// MARK: - Window Layout Metrics (Authoritative macOS Window Geometry)
/// Centralizes window-aware layout metrics, chrome clearances, and responsive boundaries.
/// Guarantees that Sidebar branding and Dashboard/Page headers align to the same baseline,
/// clears the native traffic-light titlebar in windowed mode, and adapts smoothly in fullscreen.
public enum WindowLayoutMetrics {
    /// Native titlebar chrome height in standard windowed mode (traffic lights region: ~28-32pt)
    public static let titlebarChromeHeight: CGFloat = 32.0

    /// Intentional breathing room below titlebar chrome in standard windowed mode
    public static let windowedBreathingRoom: CGFloat = 20.0

    /// Authoritative total top clearance in standard windowed mode (32 + 20 = 52pt)
    public static let standardTopClearance: CGFloat = titlebarChromeHeight + windowedBreathingRoom

    /// Authoritative total top clearance in native macOS Full Screen mode (no traffic lights visible)
    public static let fullScreenTopClearance: CGFloat = 16.0

    /// Breathing room between a banner (storage error / recovery) and page content
    public static let postBannerSpacing: CGFloat = 12.0

    /// Breathing room between a persistent cross-mode mini-bar and page content
    public static let postMiniBarSpacing: CGFloat = 12.0

    /// Authoritative top clearance dynamically adapted based on fullscreen state
    public static func topClearance(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? fullScreenTopClearance : standardTopClearance
    }
}
