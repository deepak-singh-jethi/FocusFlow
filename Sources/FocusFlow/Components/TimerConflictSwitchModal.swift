import SwiftUI
import AppKit

// MARK: - Intentional Mode Switch Confirmation Modal
public struct TimerConflictSwitchModal: View {
    public let currentPresetName: String
    public let currentRemainingTime: String
    public let targetPresetName: String
    public let targetDurationString: String
    public let onContinue: () -> Void
    public let onEndAndSwitch: () -> Void

    @State private var isContinueHovered = false
    @State private var isEndHovered = false

    public init(
        currentPresetName: String,
        currentRemainingTime: String,
        targetPresetName: String,
        targetDurationString: String,
        onContinue: @escaping () -> Void,
        onPauseAndSwitch: (() -> Void)? = nil,
        onEndAndSwitch: @escaping () -> Void
    ) {
        self.currentPresetName = currentPresetName
        self.currentRemainingTime = currentRemainingTime
        self.targetPresetName = targetPresetName
        self.targetDurationString = targetDurationString
        self.onContinue = onContinue
        self.onEndAndSwitch = onEndAndSwitch
    }

    public var body: some View {
        let isTargetBreak = targetPresetName.contains("Break")

        ZStack {
            // High-contrast dark backdrop scrim
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    onContinue()
                }

            // Spacious obsidian dialog card
            VStack(spacing: 20) {
                // 1. Hero Luminous Squircle Icon
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    (isTargetBreak ? Color.teal : Color.orange).opacity(0.28),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 38
                            )
                        )
                        .frame(width: 76, height: 76)

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    (isTargetBreak ? Color.teal : Color.orange).opacity(0.22),
                                    (isTargetBreak ? Color.cyan : Color.orange).opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke((isTargetBreak ? Color.teal : Color.orange).opacity(0.42), lineWidth: 1)
                        )

                    Image(systemName: isTargetBreak ? "cup.and.saucer.fill" : "flame.fill")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundColor(isTargetBreak ? .teal : .orange)
                        .shadow(color: (isTargetBreak ? Color.teal : Color.orange).opacity(0.60), radius: 6)
                }

                // 2. Title & Status
                VStack(spacing: 12) {
                    Text(isTargetBreak ? "Take a Break?" : "Start Focus Session?")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    // Current Session Status Pill
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isTargetBreak ? Color.orange : Color.teal)
                            .frame(width: 7, height: 7)
                        Text("\(currentPresetName) session active ·")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.65))
                        Text(currentRemainingTime)
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white)
                        Text("remaining")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.65))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.045), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))

                    Text("Ending this session will safely record the focus time you've completed into your daily stats and immediately transition to **\(targetPresetName)**.")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3.5)
                        .padding(.horizontal, 8)
                }

                // 3. Two Clear Intentional Actions
                VStack(spacing: 11) {
                    // Action 1: Intentional Switch & Start (Vibrant Action Card)
                    Button(action: onEndAndSwitch) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.18))
                                    .frame(width: 36, height: 36)
                                Image(systemName: isTargetBreak ? "cup.and.saucer.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(isTargetBreak ? Color(red: 0.02, green: 0.20, blue: 0.20) : Color(red: 0.25, green: 0.08, blue: 0.02))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isTargetBreak ? "End Session & Start Break" : "End Break & Start Focus")
                                    .font(.system(size: 13.5, weight: .bold))
                                    .foregroundColor(isTargetBreak ? Color(red: 0.02, green: 0.18, blue: 0.18) : Color(red: 0.22, green: 0.06, blue: 0.02))
                                Text("Log completed time and begin \(targetPresetName) (\(targetDurationString))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(isTargetBreak ? Color(red: 0.06, green: 0.26, blue: 0.26) : Color(red: 0.35, green: 0.12, blue: 0.05))
                            }

                            Spacer()

                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(isTargetBreak ? Color(red: 0.02, green: 0.20, blue: 0.20) : Color(red: 0.25, green: 0.08, blue: 0.02))
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            LinearGradient(
                                colors: isTargetBreak
                                    ? [Color(red: 0.08, green: 0.78, blue: 0.82), Color(red: 0.02, green: 0.86, blue: 0.88)]
                                    : [Color(red: 0.98, green: 0.45, blue: 0.20), Color(red: 1.0, green: 0.56, blue: 0.28)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.white.opacity(isEndHovered ? 0.40 : 0.22), lineWidth: 1)
                        )
                        .shadow(
                            color: (isTargetBreak ? Color.teal : Color.orange).opacity(isEndHovered ? 0.45 : 0.25),
                            radius: isEndHovered ? 12 : 7,
                            y: 3
                        )
                        .scaleEffect(isEndHovered ? 1.01 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onHover { h in
                        isEndHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }

                    // Action 2: Continue Session (Primary Safe Action)
                    Button(action: onContinue) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isTargetBreak ? "Continue Focusing" : "Continue Break")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Keep your current session running without interruption")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(Color.white.opacity(0.55))
                            }

                            Spacer()

                            Text("↵")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.40))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.10), lineWidth: 1))
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            Color.white.opacity(isContinueHovered ? 0.08 : 0.04),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(isContinueHovered ? Color.white.opacity(0.24) : Color.white.opacity(0.09), lineWidth: 1)
                        )
                        .scaleEffect(isContinueHovered ? 1.008 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onHover { h in
                        isContinueHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

                // 4. Keyboard Shortcuts Micro-Hint
                HStack(spacing: 8) {
                    Text("↵ Enter to continue")
                    Text("•")
                    Text("Esc to cancel")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.40))
                .padding(.top, 2)

                // Invisible Escape key handler
                Button(action: onContinue) {
                    EmptyView()
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(width: 480)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(red: 0.105, green: 0.115, blue: 0.155))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.68), radius: 36, y: 16)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isContinueHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isEndHovered)
    }
}
