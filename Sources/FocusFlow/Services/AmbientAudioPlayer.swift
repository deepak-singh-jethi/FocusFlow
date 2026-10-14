import SwiftUI
import AVFoundation

// MARK: - Ambient Audio Service
@MainActor
public final class AmbientAudioPlayer: ObservableObject {
    @Published public private(set) var selectedSound = "Rain"
    @Published public private(set) var isPlaying = false
    @Published public private(set) var playbackError: String?
    @Published public var volume: Double = 0.32 {
        didSet { player?.volume = Float(volume) }
    }
    private var player: AVAudioPlayer?

    public init() {}

    public func toggle(_ sound: String) {
        if isPlaying && selectedSound == sound {
            stop()
            return
        }
        guard ["Rain", "Ocean", "Forest"].contains(sound) else { return }
        playbackError = nil
        guard let url = Bundle.main.url(forResource: sound, withExtension: "mp3", subdirectory: "Soundscapes") else {
            playbackError = "The \(sound) recording is missing from this app build."
            return
        }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.numberOfLoops = -1
            audio.volume = 0
            audio.prepareToPlay()
            guard audio.play() else {
                playbackError = "Could not play the \(sound) recording."
                return
            }
            let outgoing = player
            player = audio
            selectedSound = sound
            audio.setVolume(Float(volume), fadeDuration: 0.8)
            outgoing?.setVolume(0, fadeDuration: 0.8)
            if let outgoing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { outgoing.stop() }
            }
            isPlaying = true
        } catch {
            playbackError = "Could not open the \(sound) recording."
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
