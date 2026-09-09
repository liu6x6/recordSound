import SwiftUI
import AVFoundation

@MainActor
@Observable
final class SpikeViewModel {
    enum Phase { case idle, recording, stopped }

    var phase: Phase = .idle
    var captureMic = true
    var captureSystem = true

    var micGranted = false
    var screenGranted = false
    var permissionChecked = false

    var micLevel: Float = 0
    var systemLevel: Float = 0
    var elapsed: TimeInterval = 0
    var statusMessage = ""

    var session: SpikeRecordingSession?
    var recordedFiles: [URL] = []

    private var timer: Timer?
    private var player: AVAudioPlayer?
    var playingFile: URL?

    func checkPermissions() async {
        micGranted = MicCapture.permissionStatus == .authorized
        screenGranted = await SystemAudioCapture.checkPermission()
        permissionChecked = true
        statusMessage = "麦克风: \(micGranted ? "✅" : "❌")   屏幕录制(系统声音): \(screenGranted ? "✅" : "❌")"
    }

    func requestMicPermission() async {
        micGranted = await MicCapture.requestPermission()
        await checkPermissions()
    }

    /// 屏幕录制权限无法程序化弹窗请求（首次 SCShareableContent 调用触发），
    /// 若拒绝需引导用户去系统设置
    func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func startRecording() async {
        guard phase != .recording else { return }
        let s = SpikeRecordingSession()

        s.mic.onLevel = { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        s.system.onLevel = { [weak self] level in
            Task { @MainActor in self?.systemLevel = level }
        }

        do {
            try await s.start(captureMic: captureMic && micGranted,
                              captureSystem: captureSystem && screenGranted)
            session = s
            phase = .recording
            statusMessage = "录音中… 文件目录: \(s.sessionDir.path)"
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.session else { return }
                    self.elapsed = s.duration
                }
            }
        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard phase == .recording, let session else { return }
        timer?.invalidate(); timer = nil
        await session.stop()
        phase = .stopped
        micLevel = 0; systemLevel = 0

        var files: [URL] = []
        for url in [session.micFileURL, session.systemFileURL]
        where FileManager.default.fileExists(atPath: url.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            if size > 44 { files.append(url) }   // 排除只有 header 的空文件
        }
        recordedFiles = files
        statusMessage = "录音完成，共 \(files.count) 个轨道文件"
        self.session = nil
    }

    func togglePlayback(_ url: URL) {
        if playingFile == url, let player, player.isPlaying {
            player.stop()
            playingFile = nil
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
        playingFile = url
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
