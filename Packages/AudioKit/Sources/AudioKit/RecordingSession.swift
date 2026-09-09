import Foundation
import AVFoundation

/// 一次录音会话：编排麦克风轨 + 系统声音轨，支持暂停/恢复，维护统一时间轴
public final class RecordingSession: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var captureMic: Bool
        public var captureSystem: Bool

        public init(captureMic: Bool, captureSystem: Bool) {
            self.captureMic = captureMic
            self.captureSystem = captureSystem
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle, recording, paused
    }

    public struct Result: Sendable {
        public let id: UUID
        public let micFileURL: URL?
        public let systemFileURL: URL?
        public let duration: TimeInterval
    }

    public let id = UUID()
    public private(set) var phase: Phase = .idle

    public var onMicLevel: (@Sendable (Float) -> Void)? {
        get { mic.onLevel }
        set { mic.onLevel = newValue }
    }
    public var onSystemLevel: (@Sendable (Float) -> Void)? {
        get { system.onLevel }
        set { system.onLevel = newValue }
    }

    /// PCM buffer 回调（已拷贝），供实时转写嗂入
    public var onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { mic.onBuffer }
        set { mic.onBuffer = newValue }
    }
    public var onSystemBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { system.onBuffer }
        set { system.onBuffer = newValue }
    }

    private let mic = MicCapture()
    private let system = SystemAudioCapture()

    // 时间轴：暂停期间不计入时长
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?

    public init() {}

    public var directory: URL { RecordingStore.directory(for: id) }
    public var micFileURL: URL { RecordingStore.micFileURL(for: id) }
    public var systemFileURL: URL { RecordingStore.systemFileURL(for: id) }

    /// 已录时长（不含暂停）
    public var elapsed: TimeInterval {
        accumulated + (segmentStart.map { Date.now.timeIntervalSince($0) } ?? 0)
    }

    public func start(_ config: Configuration) async throws {
        guard phase == .idle else { return }
        guard config.captureMic || config.captureSystem else {
            throw RecordingError.noSourceSelected
        }

        // 先启动系统声音（异步申请 SCStream），失败不影响麦克风轨
        var systemStarted = false
        if config.captureSystem {
            do {
                try await system.start(fileURL: systemFileURL)
                systemStarted = true
            } catch {
                if config.captureMic {
                    // 系统声音失败 → 降级仅麦克风
                    systemStarted = false
                } else {
                    throw error
                }
            }
        }

        if config.captureMic {
            do {
                try mic.start(fileURL: micFileURL)
            } catch {
                if !systemStarted { throw error }
                // 麦克风失败但系统声音在录 → 继续
            }
        }

        segmentStart = .now
        phase = .recording
    }

    public func pause() async {
        guard phase == .recording else { return }
        accumulated += segmentStart.map { Date.now.timeIntervalSince($0) } ?? 0
        segmentStart = nil
        mic.pause()
        system.pause()
        phase = .paused
    }

    public func resume() async throws {
        guard phase == .paused else { return }
        try mic.resume()
        system.resume()
        segmentStart = .now
        phase = .recording
    }

    public func stop() async -> Result {
        guard phase != .idle else {
            return Result(id: id, micFileURL: nil, systemFileURL: nil, duration: 0)
        }
        accumulated += segmentStart.map { Date.now.timeIntervalSince($0) } ?? 0
        segmentStart = nil

        mic.stop()
        await system.stop()
        phase = .idle

        let micURL = RecordingStore.hasAudio(at: micFileURL) ? micFileURL : nil
        let sysURL = RecordingStore.hasAudio(at: systemFileURL) ? systemFileURL : nil
        return Result(id: id, micFileURL: micURL, systemFileURL: sysURL, duration: accumulated)
    }

    public enum RecordingError: LocalizedError {
        case noSourceSelected
        public var errorDescription: String? {
            switch self {
            case .noSourceSelected: return "请至少选择一个音源（麦克风 / 系统声音）"
            }
        }
    }
}
