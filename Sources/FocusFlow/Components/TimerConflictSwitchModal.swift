import SwiftUI
import AppKit

// MARK: - Modern macOS Obsidian HUD Mode Switch Confirmation Dialog
public struct TimerConflictSwitchModal: View {
    public let currentPresetName: String
    public let currentRemainingTime: String
    public let currentElapsedMinutes: Int
    public let targetPresetName: String
    public let targetDurationString: String
    public let onContinue: () -> Void
    public let onEndAndSwitch: () -> Void

    @State private var isPrimaryHovered = false
    @State private var isSecondaryHovered = false
    @State private var isCloseHovered = false

    public init(
        currentPresetName: String,
        currentRemainingTime: String,
        currentElapsedMinutes: Int = 1,
        targetPresetName: String,
        targetDurationString: String,
        onContinue: @escaping () -> Void,
        onPauseAndSwitch: (() -> Void)? = nil,
        onEndAndSwitch: @escaping () -> Void
    ) {
        self.currentPresetName = currentPresetName
        self.currentRemainingTime = currentRemainingTime
        self.currentElapsedMinutes = max(1, currentElapsedMinutes)
        self.targetPresetName = targetPresetName
        self.targetDurationString = targetDurationString
        self.onContinue = onContinue
        self.onEndAndSwitch = onEndAndSwitch
    }

    public var body: some View {
        let isTargetBreak = targetPresetName.contains("Break")
        let accentColor = isTargetBreak ? Color.teal : Color.orange
        let sourceIcon = isTargetBreak ? "flame.fill" : "cup.and.saucer.fill"
        let targetIcon = isTargetBreak ? "cup.and.saucer.fill" : "flame.fill"

        ZStack {
            // High-contrast frosted backdrop scrim
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture {
                    onContinue()
                }

            // Compact, widescreen macOS Obsidian HUD Card
            VStack(alignment: .leading, spacing: 18) {
                // 1. Header Row: Luminous Inline Squircle Badge + Title + Close Button
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColor.opacity(0.16))
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(accentColor.opacity(0.38), lineWidth: 1)
                            )
                            .shadow(color: accentColor.opacity(0.35), radius: 8)

                        Image(systemName: targetIcon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isTargetBreak ? "Take a Break?" : "Start Focus Session?")
                            .font(.system(size: 16.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text(isTargetBreak ? "Step away from the screen and recharge" : "Resume your deep work zone")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.55))
                    }

                    Spacer()

                    // Subtle close button (Esc)
                    Button(action: onContinue) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(Color.white.opacity(isCloseHovered ? 0.90 : 0.45))
                            .frame(width: 24, height: 24)
                            .background(
                                Color.white.opacity(isCloseHovered ? 0.10 : 0.03),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        isCloseHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .help("Cancel (Esc)")
                }

                // 2. Visual Session Transition Capsule (Hero Information Architecture)
                HStack(spacing: 0) {
                    // Left: Source Session (Active/Paused)
                    HStack(spacing: 8) {
                        Image(systemName: sourceIcon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(isTargetBreak ? .orange : .teal)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(currentPresetName) (\(currentRemainingTime) left)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(isTargetBreak ? "\(currentElapsedMinutes)m focus logged" : "Break ended early")
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundColor(Color.white.opacity(0.52))
                        }
                    }

                    Spacer()

                    // Center: Direction Indicator
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.35))
                        .padding(.horizontal, 10)

                    Spacer()

                    // Right: Target Session (Ready to Launch)
                    HStack(spacing: 8) {
                        Image(systemName: targetIcon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(accentColor)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(targetPresetName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text("\(targetDurationString) countdown")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(accentColor.opacity(0.90))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )

                // 3. Clear Reassurance Copy
                Text(isTargetBreak
                    ? "Your focus time worked so far will be safely logged to today's stats."
                    : "Ending break early will immediately start your scheduled focus countdown."
                )
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Color.white.opacity(0.68))
                .lineSpacing(2)

                // 4. Horizontal Desktop Action Bar (Standard macOS HIG)
                HStack(spacing: 10) {
                    // Secondary Action: Keep Current Session (Esc)
                    Button(action: onContinue) {
                        HStack(spacing: 6) {
                            Text(isTargetBreak ? "Keep Focusing" : "Continue Break")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(Color.white.opacity(isSecondaryHovered ? 0.95 : 0.80))

                            Text("esc")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.white.opacity(0.38))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            Color.white.opacity(isSecondaryHovered ? 0.08 : 0.04),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSecondaryHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.09), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .onHover { h in
                        isSecondaryHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }

                    // Primary Action: End & Switch to Target (Return ↵)
                    Button(action: onEndAndSwitch) {
                        HStack(spacing: 6) {
                            Image(systemName: targetIcon)
                                .font(.system(size: 11, weight: .bold))

                            Text(isTargetBreak ? "Start Break (\(targetDurationString))" : "Start Focus")
                                .font(.system(size: 12.5, weight: .bold))

                            Text("↵")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .foregroundColor(isTargetBreak ? Color(red: 0.02, green: 0.16, blue: 0.16) : Color(red: 0.22, green: 0.05, blue: 0.02))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(
                            LinearGradient(
                                colors: isTargetBreak
                                    ? [Color(red: 0.02, green: 0.78, blue: 0.82), Color(red: 0.0, green: 0.88, blue: 0.86)]
                                    : [Color(red: 0.98, green: 0.44, blue: 0.18), Color(red: 1.0, green: 0.58, blue: 0.28)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(isPrimaryHovered ? 0.40 : 0.20), lineWidth: 1)
                        )
                        .shadow(
                            color: accentColor.opacity(isPrimaryHovered ? 0.45 : 0.25),
                            radius: isPrimaryHovered ? 10 : 5,
                            y: 2
                        )
                        .scaleEffect(isPrimaryHovered ? 1.012 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .onHover { h in
                        isPrimaryHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(width: 440)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.11, green: 0.12, blue: 0.16))

                    // Ambient luminous background glow from accent color
                    RadialGradient(
                        colors: [accentColor.opacity(0.10), Color.clear],
                        center: .topLeading,
                        startRadius: 10,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.70), radius: 36, y: 16)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isPrimaryHovered)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isSecondaryHovered)
        .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
    }
}
