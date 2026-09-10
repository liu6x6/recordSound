import Foundation
import AVFoundation

/// 系统声音捕获的统一接口（SCStream 全局 / Process Tap 按 App）
public protocol SystemAudioCapturing: AnyObject, Sendable {
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var isRecording: Bool { get }
    func start(fileURL: URL) async throws
    func pause()
    func resume()
    func stop() async
}

extension SystemAudioCapture: SystemAudioCapturing {}
extension ProcessTapCapture: SystemAudioCapturing {}

/// 一次录音会话：编排麦克风轨 + 系统声音轨（全局或按 App），支持暂停/恢复，维护统一时间轴
public final class RecordingSession: @unchecked Sendable {

    /// 系统声音捕获模式
    public enum SystemAudioMode: Equatable, Sendable {
        /// 全部系统声音（ScreenCaptureKit，需屏幕录制权限）
        case global
        /// 指定 App 的输出（Core Audio Process Taps，macOS 14.2+）
        case apps(processObjectIDs: [AudioObjectID], bundleIDs: [String])
    }

    public struct Configuration: Sendable {
        public var captureMic: Bool
        public var captureSystem: Bool
        public var systemMode: SystemAudioMode

        public init(captureMic: Bool, captureSystem: Bool, systemMode: SystemAudioMode = .global) {
            self.captureMic = captureMic
            self.captureSystem = captureSystem
            self.systemMode = systemMode
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
        /// 按 App 模式时记录来源 bundleID
        public let sourceApps: [String]
    }

    public let id = UUID()
    public private(set) var phase: Phase = .idle

    // 电平/buffer 回调（start 时接线到实际捕获对象）
    public var onMicLevel: (@Sendable (Float) -> Void)?
    public var onSystemLevel: (@Sendable (Float) -> Void)?
    public var onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onSystemBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private let mic = MicCapture()
    private var system: (any SystemAudioCapturing)?
    private var activeMode: SystemAudioMode = .global

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

        mic.onLevel = onMicLevel
        mic.onBuffer = onMicBuffer

        // 先启动系统声音（异步），失败不影响麦克风轨
        var systemStarted = false
        if config.captureSystem {
            let capture: any SystemAudioCapturing
            switch config.systemMode {
            case .global:
                capture = SystemAudioCapture()
            case .apps(let objectIDs, _):
                capture = ProcessTapCapture(processObjectIDs: objectIDs)
            }
            capture.onLevel = onSystemLevel
            capture.onBuffer = onSystemBuffer
            do {
                try await capture.start(fileURL: systemFileURL)
                system = capture
                activeMode = config.systemMode
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
        system?.pause()
        phase = .paused
    }

    public func resume() async throws {
        guard phase == .paused else { return }
        try mic.resume()
        system?.resume()
        segmentStart = .now
        phase = .recording
    }

    public func stop() async -> Result {
        guard phase != .idle else {
            return Result(id: id, micFileURL: nil, systemFileURL: nil, duration: 0, sourceApps: [])
        }
        accumulated += segmentStart.map { Date.now.timeIntervalSince($0) } ?? 0
        segmentStart = nil

        mic.stop()
        await system?.stop()
        system = nil
        phase = .idle

        let micURL = RecordingStore.hasAudio(at: micFileURL) ? micFileURL : nil
        let sysURL = RecordingStore.hasAudio(at: systemFileURL) ? systemFileURL : nil
        let apps: [String]
        if case .apps(_, let bundleIDs) = activeMode, sysURL != nil {
            apps = bundleIDs
        } else {
            apps = []
        }
        return Result(id: id, micFileURL: micURL, systemFileURL: sysURL,
                      duration: accumulated, sourceApps: apps)
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
