import Foundation

/// Spike 录音会话：同时编排麦克风轨 + 系统声音轨，记录统一起始时间
@MainActor
final class SpikeRecordingSession {
    let mic = MicCapture()
    let system = SystemAudioCapture()

    let sessionDir: URL
    var startDate: Date?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceScribe/SpikeSessions", isDirectory: true)
        sessionDir = base.appendingPathComponent(
            Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-"),
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    var micFileURL: URL { sessionDir.appendingPathComponent("mic.caf") }
    var systemFileURL: URL { sessionDir.appendingPathComponent("system.caf") }

    /// - Parameters:
    ///   - captureMic: 是否录麦克风
    ///   - captureSystem: 是否录系统声音
    func start(captureMic: Bool, captureSystem: Bool) async throws {
        if captureSystem {
            try await system.start(fileURL: systemFileURL)
        }
        if captureMic {
            try mic.start(fileURL: micFileURL)
        }
        startDate = .now
    }

    func stop() async {
        mic.stop()
        await system.stop()
    }

    var duration: TimeInterval {
        guard let startDate else { return 0 }
        return Date.now.timeIntervalSince(startDate)
    }
}
