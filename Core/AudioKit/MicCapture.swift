import AVFoundation

/// 麦克风采集：AVAudioEngine inputNode tap → 写 CAF 文件 + 电平回调
final class MicCapture: @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "麦克风权限被拒绝"
            case .noInputDevice: return "没有可用的输入设备"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let fileLock = NSLock()

    /// 电平回调（0.0 ~ 1.0），在音频线程调用，UI 层需自行调度到主线程
    var onLevel: ((Float) -> Void)?

    private(set) var isRecording = false

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func start(fileURL: URL) throws {
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
            self.fileLock.lock()
            do { try self.file?.write(from: buffer) } catch { /* spike: 忽略写盘错误 */ }
            self.fileLock.unlock()
            self.onLevel?(Self.rms(buffer))
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        fileLock.lock()
        file = nil
        fileLock.unlock()
        isRecording = false
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrtf(sum / Float(n))
        // 简单映射到 0~1（40dB 动态范围）
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 40) / 40, 0), 1)
    }
}
