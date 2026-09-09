import AVFoundation

/// 麦克风采集：AVAudioEngine inputNode tap → 写 CAF 文件 + 电平回调
public final class MicCapture: @unchecked Sendable {

    public enum CaptureError: LocalizedError {
        case permissionDenied
        case noInputDevice

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "麦克风权限被拒绝"
            case .noInputDevice: return "没有可用的输入设备"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let lock = NSLock()

    /// 电平回调（0.0 ~ 1.0），在音频线程调用
    public var onLevel: (@Sendable (Float) -> Void)?

    /// PCM buffer 回调（已拷贝，可安全交给语音识别），在音频线程调用
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public private(set) var isRecording = false
    public private(set) var isPaused = false

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// 可用输入设备列表（M1 使用系统默认设备，列表供设置页展示）
    public static func inputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    public func start(fileURL: URL) throws {
        guard Self.permissionStatus == .authorized else { throw CaptureError.permissionDenied }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        file = try AVAudioFile(
            forWriting: fileURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.withLock {
                do { try self.file?.write(from: buffer) } catch { /* 忽略写盘错误 */ }
            }
            self.onLevel?(LevelMath.normalized(buffer))
            if self.onBuffer != nil, let copied = BufferCopy.copy(buffer) {
                self.onBuffer?(copied)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        isPaused = false
    }

    public func pause() {
        guard isRecording, !isPaused else { return }
        engine.pause()
        isPaused = true
    }

    public func resume() throws {
        guard isRecording, isPaused else { return }
        try engine.start()
        isPaused = false
    }

    public func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }
        isRecording = false
        isPaused = false
    }
}
