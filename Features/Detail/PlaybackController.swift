import AVFoundation
import Observation
import AudioKit
import CoreModels

/// 详情页播放控制：双轨同步播放（mic.caf + system.caf）
@MainActor
@Observable
final class PlaybackController {
    private var micPlayer: AVAudioPlayer?
    private var systemPlayer: AVAudioPlayer?
    private var timer: Timer?

    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var micEnabled = true { didSet { micPlayer?.volume = micEnabled ? 1 : 0 } }
    var systemEnabled = true { didSet { systemPlayer?.volume = systemEnabled ? 1 : 0 } }

    func load(recording: Recording) {
        stop()
        let micURL = RecordingStore.micFileURL(for: recording.id)
        let sysURL = RecordingStore.systemFileURL(for: recording.id)

        if recording.hasMicTrack {
            micPlayer = try? AVAudioPlayer(contentsOf: micURL)
            micPlayer?.prepareToPlay()
            micPlayer?.volume = micEnabled ? 1 : 0
        }
        if recording.hasSystemTrack {
            systemPlayer = try? AVAudioPlayer(contentsOf: sysURL)
            systemPlayer?.prepareToPlay()
            systemPlayer?.volume = systemEnabled ? 1 : 0
        }
        duration = max(micPlayer?.duration ?? 0, systemPlayer?.duration ?? 0)
    }

    func play() {
        guard !isPlaying, micPlayer != nil || systemPlayer != nil else { return }
        micPlayer?.play()
        systemPlayer?.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    func pause() {
        micPlayer?.pause()
        systemPlayer?.pause()
        timer?.invalidate(); timer = nil
        isPlaying = false
    }

    func stop() {
        pause()
        micPlayer?.stop(); micPlayer = nil
        systemPlayer?.stop(); systemPlayer = nil
        position = 0
        duration = 0
    }

    func seek(to time: TimeInterval) {
        micPlayer?.currentTime = time
        systemPlayer?.currentTime = time
        position = time
    }

    private func tick() {
        position = max(micPlayer?.currentTime ?? 0, systemPlayer?.currentTime ?? 0)
        let micDone = micPlayer.map { !$0.isPlaying } ?? true
        let sysDone = systemPlayer.map { !$0.isPlaying } ?? true
        if micDone && sysDone && position > 0 {
            // 两轨都播完
            if position >= duration - 0.1 {
                pause()
                seek(to: 0)
            }
        }
    }
}
