#if os(iOS)
import AVFAudio

/// Keeps timeline audio ambient and holds playback audio while a detail player owns it.
@MainActor
public final class AudioSessionManager {
    public static let shared = AudioSessionManager()

    private var playbackRequestCount = 0

    private init() {}

    public func activateAmbient() {
        applyCategory(.ambient)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    /// Called when a surface starts audible playback. Reference counted so
    /// overlapping players (detail video, Instagram video) do not fight over
    /// the category; the session stays active with the category set at launch.
    public func beginPlayback() {
        playbackRequestCount += 1
        if playbackRequestCount == 1 {
            applyCategory(.playback)
        }
    }

    /// Releases one playback hold and restores `.ambient` when nobody else
    /// needs the audio route.
    public func endPlayback() {
        guard playbackRequestCount > 0 else { return }
        playbackRequestCount -= 1
        if playbackRequestCount == 0 {
            applyCategory(.ambient)
        }
    }

    private func applyCategory(_ category: AVAudioSession.Category) {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                category, mode: .default, policy: .default, options: [.mixWithOthers]
            )
        } catch {
            print("Audio session error: \(error)")
        }
    }
}
#endif
