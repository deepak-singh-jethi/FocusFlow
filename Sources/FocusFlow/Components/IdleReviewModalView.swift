import SwiftUI
import AppKit

// MARK: - Modern macOS Obsidian HUD Idle Time Review Modal
public struct IdleReviewModalView: View {
    @ObservedObject public var coordinator: IdleReviewCoordinator
    public let interval: IdleReviewInterval
    public let taskTitle: String?

    @State private var isPrimaryHovered = false
    @State private var isSecondaryHovered = false
    @State private var isTertiaryHovered = false
    @State private var isCloseHovered = false

    public init(
        coordinator: IdleReviewCoordinator,
        interval: IdleReviewInterval,
        taskTitle: String? = nil
    ) {
        self.coordinator = coordinator
        self.interval = interval
        self.taskTitle = taskTitle
    }

    public var body: some View {
        let accentColor = Color.orange
        let totalPending = coordinator.pendingIntervals.count
        let currentIndex: Int = (coordinator.pendingIntervals.firstIndex(where: { $0.id == interval.id }) ?? 0) + 1

        ZStack {
            // High-contrast frosted backdrop scrim
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture {
                    coordinator.dismissActiveReviewToDecideLater()
                }

            // Compact, widescreen macOS Obsidian HUD Card
            VStack(alignment: .leading, spacing: 18) {
                // 1. Header Row: Luminous Inline Squircle Badge + Title + Queue Badge + Close Button
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

                        Image(systemName: "moon.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Review Inactive Time")
                                .font(.system(size: 16.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            if totalPending > 1 {
                                Text("\(currentIndex) of \(totalPending)")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(accentColor.opacity(0.15), in: Capsule())
                            }
                        }

                        Text("FocusFlow detected no keyboard or mouse activity")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.55))
                    }

                    Spacer()

                    // Subtle close button (Decide Later / Esc)
                    Button {
                        coordinator.dismissActiveReviewToDecideLater()
                    } label: {
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
                    .help("Decide Later (Esc)")
                }

                // 2. Hero Inactive Time Interval Capsule
                VStack(spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(interval.sessionType == "Stopwatch" ? "Stopwatch Session" : "\(interval.sessionType) Session")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.70))

                            if let title = taskTitle, !title.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.teal)
                                    Text(title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                }
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 3) {
                            Text(interval.formattedDuration)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(accentColor)

                            Text(interval.formattedTimeRange())
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.55))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )

                // 3. Clear Reassurance Copy
                Text("Did you spend this time focusing away from the computer, or should this interval be excluded from your focus time?")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.68))
                    .lineSpacing(2)

                // 4. Horizontal Action Buttons
                HStack(spacing: 10) {
                    // Tertiary Action: Decide Later
                    Button {
                        coordinator.resolve(intervalId: interval.id, decision: .decideLater)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Decide Later")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.white.opacity(isTertiaryHovered ? 0.90 : 0.60))

                            Text("esc")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.white.opacity(0.35))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .frame(minHeight: 34)
                        .padding(.horizontal, 10)
                        .background(
                            Color.white.opacity(isTertiaryHovered ? 0.08 : 0.03),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .onHover { h in
                        isTertiaryHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }

                    Spacer()

                    // Secondary Action: Exclude from Focus
                    Button {
                        coordinator.resolve(intervalId: interval.id, decision: .excludeFromFocus)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 11, weight: .bold))
                            Text("Exclude")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(Color.white.opacity(isSecondaryHovered ? 0.95 : 0.80))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(
                            Color.red.opacity(isSecondaryHovered ? 0.22 : 0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.red.opacity(isSecondaryHovered ? 0.45 : 0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { h in
                        isSecondaryHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }

                    // Primary Action: Count as Focus (Return ↵)
                    Button {
                        coordinator.resolve(intervalId: interval.id, decision: .countAsFocus)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))

                            Text("Count as Focus")
                                .font(.system(size: 12, weight: .bold))

                            Text("↵")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .foregroundColor(Color(red: 0.02, green: 0.18, blue: 0.08))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.20, green: 0.85, blue: 0.45), Color(red: 0.15, green: 0.75, blue: 0.38)],
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
                            color: Color.green.opacity(isPrimaryHovered ? 0.40 : 0.20),
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
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isTertiaryHovered)
        .animation(.easeInOut(duration: 0.15), value: isCloseHovered)
    }
}
