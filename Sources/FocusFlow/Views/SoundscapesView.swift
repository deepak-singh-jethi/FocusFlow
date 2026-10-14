import SwiftUI
import AppKit

// MARK: - Soundscapes View
public struct SoundscapesView: View {
    @ObservedObject public var audioPlayer: AmbientAudioPlayer
    private let sounds: [(String, String, String)] = [
        ("Rain", "cloud.rain.fill", "Steady rainfall with gentle drops"),
        ("Ocean", "water.waves", "Slow surf and rolling swells"),
        ("Forest", "leaf.fill", "Breeze and distant birdsong")
    ]

    public init(audioPlayer: AmbientAudioPlayer) {
        self.audioPlayer = audioPlayer
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Focus Soundscapes")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Choose a scene and set a comfortable volume.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.top, 30)

                HStack(spacing: 12) {
                    ForEach(sounds, id: \.0) { sound, icon, detail in
                        SoundscapeCard(
                            sound: sound,
                            icon: icon,
                            detail: detail,
                            isPlaying: audioPlayer.isPlaying && audioPlayer.selectedSound == sound
                        ) {
                            audioPlayer.toggle(sound)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.orange)
                        Text(audioPlayer.isPlaying ? "Playing \(audioPlayer.selectedSound)" : "Choose a soundscape to begin")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                        Spacer()
                        if audioPlayer.isPlaying {
                            Button("Stop") { audioPlayer.stop() }
                                .buttonStyle(DashboardButtonStyle())
                        }
                    }
                    if let playbackError = audioPlayer.playbackError {
                        Text(playbackError)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: audioPlayer.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(.gray)
                            .frame(width: 20)
                        Slider(value: $audioPlayer.volume, in: 0...1)
                            .tint(.orange)
                            .accessibilityLabel("Soundscape volume")
                        Text("\(Int(audioPlayer.volume * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                .padding(17)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Soundscape Card
public struct SoundscapeCard: View {
    public let sound: String
    public let icon: String
    public let detail: String
    public let isPlaying: Bool
    public let action: () -> Void

    @State private var isHovered = false

    public init(sound: String, icon: String, detail: String, isPlaying: Bool, action: @escaping () -> Void) {
        self.sound = sound
        self.icon = icon
        self.detail = detail
        self.isPlaying = isPlaying
        self.action = action
    }

    private var strokeColor: Color {
        if isPlaying { return Color.orange.opacity(0.55) }
        return isHovered ? Color.white.opacity(0.2) : Color.white.opacity(0.06)
    }

    private var cardBackground: Color {
        isHovered ? Color.white.opacity(0.075) : Color.white.opacity(0.035)
    }

    private var statusColor: Color {
        if isPlaying { return .orange }
        return isHovered ? .white : .gray
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(sound)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    Text(isPlaying ? "Playing" : "Play")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusColor)
            }
            .frame(maxWidth: .infinity, minHeight: 165, alignment: .leading)
            .padding(17)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(strokeColor, lineWidth: 1))
            .shadow(color: isHovered ? (isPlaying ? Color.orange.opacity(0.25) : Color.white.opacity(0.06)) : Color.clear, radius: 8)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}
