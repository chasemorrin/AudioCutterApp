import AVFoundation
import Combine

/// Plays the recording straight from disk with AVPlayer. AVPlayer streams the
/// file, so playback memory stays small even for a very long recording.
@MainActor
final class PlayerController: ObservableObject {

    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isScrubbing = false
    private var stopAt: Double?          // set while previewing a section
    private var duration: Double = 0

    // MARK: - Loading

    func load(url: URL, duration: Double) {
        unload()
        configureAudioSession()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        self.duration = duration
        currentTime = 0
        isPlaying = false

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, seconds.isFinite, !self.isScrubbing else { return }

                // End of a section preview: stop right there.
                if let stop = self.stopAt, seconds >= stop {
                    self.stopAt = nil
                    self.player?.pause()
                    self.isPlaying = false
                    self.currentTime = stop
                    return
                }
                self.currentTime = seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    private func unload() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        timeObserver = nil
        endObserver = nil
        player = nil
        stopAt = nil
        isPlaying = false
    }

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)   // plays even with the silent switch on
        try? session.setActive(true)
        #endif
    }

    // MARK: - Controls

    func togglePlay() {
        guard let player else { return }
        stopAt = nil
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                currentTime = 0
                seek(to: 0, precise: true)
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        stopAt = nil
        player?.pause()
        isPlaying = false
    }

    /// Jump to a time and start playing from there.
    func play(from time: Double) {
        guard let player else { return }
        let target = min(max(0, time), duration)
        stopAt = nil
        isScrubbing = false
        currentTime = target
        seek(to: target, precise: true)
        player.play()
        isPlaying = true
    }

    /// Play one section and stop at its end.
    func preview(from start: Double, to end: Double) {
        guard let player else { return }
        let target = min(max(0, start), duration)
        stopAt = nil
        isScrubbing = true            // ignore stale time updates until the seek lands
        currentTime = target
        player.pause()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isScrubbing = false
                self.stopAt = end
                self.player?.play()
                self.isPlaying = true
            }
        }
    }

    /// Jump forward or back by a number of seconds.
    func skip(by delta: Double) {
        let target = min(max(0, currentTime + delta), duration)
        stopAt = nil
        currentTime = target
        seek(to: target, precise: true)
    }

    /// Called while a finger is on the waveform. Moves quickly during the drag
    /// (loose accuracy), then lands exactly where the finger lifts.
    func scrub(to time: Double, final: Bool) {
        let target = min(max(0, time), duration)
        stopAt = nil
        isScrubbing = !final
        currentTime = target
        seek(to: target, precise: final)
    }

    private func seek(to seconds: Double, precise: Bool) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        if precise {
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player?.seek(to: target)
        }
    }
}
