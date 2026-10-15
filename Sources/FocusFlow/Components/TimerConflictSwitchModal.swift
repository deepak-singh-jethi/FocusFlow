import SwiftUI
import AppKit

// MARK: - Timer Conflict Resolution Modal
public struct TimerConflictSwitchModal: View {
    public let currentPresetName: String
    public let currentRemainingTime: String
    public let targetPresetName: String
    public let targetDurationString: String
    public let onContinue: () -> Void
    public let onPauseAndSwitch: () -> Void
    public let onEndAndSwitch: () -> Void

    @State private var isContinueHovered = false
    @State private var isPauseHovered = false
    @State private var isEndHovered = false

    public init(
        currentPresetName: String,
        currentRemainingTime: String,
        targetPresetName: String,
        targetDurationString: String,
        onContinue: @escaping () -> Void,
        onPauseAndSwitch: @escaping () -> Void,
        onEndAndSwitch: @escaping () -> Void
    ) {
        self.currentPresetName = currentPresetName
        self.currentRemainingTime = currentRemainingTime
        self.targetPresetName = targetPresetName
        self.targetDurationString = targetDurationString
        self.onContinue = onContinue
        self.onPauseAndSwitch = onPauseAndSwitch
        self.onEndAndSwitch = onEndAndSwitch
    }

    public var body: some View {
        ZStack {
            // High-contrast dark backdrop scrim
            Color.black.opacity(0.76)
                .ignoresSafeArea()
                .onTapGesture {
                    onContinue()
                }

            // Opaque obsidian card
            VStack(spacing: 20) {
                // Header Glowing Icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: 54, height: 54)
                    Image(systemName: "timer")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.orange)
                }

                // Title & Context
                VStack(spacing: 6) {
                    Text("Timer In Progress")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Your **\(currentPresetName)** timer has **\(currentRemainingTime)** remaining.\nYou are switching to **\(targetPresetName)** (\(targetDurationString)).")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(white: 0.82))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)

                // 3 Clear Actions
                VStack(spacing: 10) {
                    // 1. Continue Current Timer (Safe / Recommended)
                    Button(action: onContinue) {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color(red: 0.1, green: 0.05, blue: 0.05))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Continue Current Timer")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Color(red: 0.1, green: 0.05, blue: 0.05))
                                Text("Keep your \(currentPresetName) timer running without interruption")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(red: 0.25, green: 0.12, blue: 0.08))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            LinearGradient(
                                colors: [.orange, Color(red: 1.0, green: 0.42, blue: 0.28)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(isContinueHovered ? 0.45 : 0.20), lineWidth: 1))
                        .shadow(color: Color.orange.opacity(isContinueHovered ? 0.45 : 0.22), radius: 8, y: 2)
                        .scaleEffect(isContinueHovered ? 1.01 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onHover { h in
                        isContinueHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .keyboardShortcut(.defaultAction)

                    // 2. Pause & Switch (Preserve current in mini-bar)
                    Button(action: onPauseAndSwitch) {
                        HStack(spacing: 12) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.cyan)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pause & Switch")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                Text("Pause \(currentPresetName) in the mini-bar and switch to \(targetPresetName)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.white.opacity(isPauseHovered ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isPauseHovered ? Color.cyan.opacity(0.40) : Color.white.opacity(0.12), lineWidth: 1))
                        .scaleEffect(isPauseHovered ? 1.01 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onHover { h in
                        isPauseHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }

                    // 3. End & Switch (Save progress so far and switch)
                    Button(action: onEndAndSwitch) {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(Color.red.opacity(0.85))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("End & Switch")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Color.white.opacity(0.92))
                                Text("Save logged time, end current session, and load \(targetPresetName)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.red.opacity(isEndHovered ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(isEndHovered ? 0.38 : 0.20), lineWidth: 1))
                        .scaleEffect(isEndHovered ? 1.01 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onHover { h in
                        isEndHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)
            .background(Color(red: 0.11, green: 0.12, blue: 0.16), in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.55), radius: 36, y: 14)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isContinueHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPauseHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isEndHovered)
    }
}
