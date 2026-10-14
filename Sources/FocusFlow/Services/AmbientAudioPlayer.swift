import SwiftUI
import AVFoundation

// MARK: - Ambient Audio Service (Multi-Environment Resource Locator)
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

    private func resolveSoundURL(named sound: String) -> URL? {
        let fileManager = FileManager.default

        // 1. App Bundle Resource Subdirectory
        if let url = Bundle.main.url(forResource: sound, withExtension: "mp3", subdirectory: "Soundscapes"),
           fileManager.fileExists(atPath: url.path) {
            return url
        }

        // 2. Direct App Bundle Resource
        if let url = Bundle.main.url(forResource: sound, withExtension: "mp3"),
           fileManager.fileExists(atPath: url.path) {
            return url
        }

        // 3. Contents/Resources/Soundscapes path
        let appBundleSoundscapes = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Soundscapes/\(sound).mp3")
        if fileManager.fileExists(atPath: appBundleSoundscapes.path) {
            return appBundleSoundscapes
        }

        // 4. Working Directory Assets fallback (for `swift run` or SPM development)
        let cwdSoundscapes = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/Soundscapes/\(sound).mp3")
        if fileManager.fileExists(atPath: cwdSoundscapes.path) {
            return cwdSoundscapes
        }

        return nil
    }

    public func toggle(_ sound: String) {
        if isPlaying && selectedSound == sound {
            stop()
            return
        }
        guard ["Rain", "Ocean", "Forest"].contains(sound) else { return }
        playbackError = nil
        guard let url = resolveSoundURL(named: sound) else {
            playbackError = "The \(sound) recording could not be located in the application bundle."
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
            playbackError = "Could not open the \(sound) recording: \(error.localizedDescription)"
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}
