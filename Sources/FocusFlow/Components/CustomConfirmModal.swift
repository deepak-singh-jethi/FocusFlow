import SwiftUI
import AppKit

// MARK: - Custom High-Contrast Confirmation Modal
public struct CustomConfirmModal: View {
    public let title: String
    public let message: String
    public let icon: String
    public let iconColor: Color
    public let confirmTitle: String
    public let isDestructive: Bool
    public let onConfirm: () -> Void
    public let onCancel: () -> Void

    @State private var isConfirmHovered = false
    @State private var isCancelHovered = false

    public init(
        title: String,
        message: String,
        icon: String,
        iconColor: Color,
        confirmTitle: String,
        isDestructive: Bool,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.iconColor = iconColor
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private var confirmGradient: LinearGradient {
        if isDestructive {
            return LinearGradient(colors: [Color.red.opacity(0.85), Color(red: 0.85, green: 0.15, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            return LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.4, blue: 0.28)], startPoint: .leading, endPoint: .trailing)
        }
    }

    public var body: some View {
        ZStack {
            // Full-screen high-contrast dark scrim that completely blocks out the glowing background digits!
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Opaque Obsidian Modal Card
            VStack(spacing: 20) {
                // Header Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.16))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(iconColor)
                }

                // Title & Message with Crisp Silver/White Typography
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)

                // Action Buttons
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.white.opacity(isCancelHovered ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(isCancelHovered ? 0.25 : 0.12), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onHover { h in
                        isCancelHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(isDestructive ? .white : Color(red: 0.1, green: 0.05, blue: 0.05))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(confirmGradient, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(isConfirmHovered ? 0.35 : 0.15), lineWidth: 1))
                            .shadow(color: isDestructive ? Color.red.opacity(isConfirmHovered ? 0.45 : 0.25) : Color.orange.opacity(isConfirmHovered ? 0.45 : 0.25), radius: 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onHover { h in
                        isConfirmHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(26)
            .frame(width: 380)
            .background(
                Color(red: 0.14, green: 0.15, blue: 0.20),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.60), radius: 30, y: 12)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isConfirmHovered)
    }
}
