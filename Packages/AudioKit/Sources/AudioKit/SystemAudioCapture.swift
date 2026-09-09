import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// 系统声音采集：SCStream(capturesAudio: true) → 写 CAF 文件 + 电平回调
/// 录主显示器对应音频，排除本进程声音（防自激），视频通道最小化
public final class SystemAudioCapture: NSObject, @unchecked Sendable {

    public enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay
        case streamFailed(String)

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "屏幕录制权限未授权（系统声音捕获需要此权限）"
            case .noDisplay: return "未找到可用显示器"
            case .streamFailed(let msg): return "SCStream 失败: \(msg)"
            }
        }
    }

    private var stream: SCStream?
    private var file: AVAudioFile?
    private var pendingFileURL: URL?
    private let lock = NSLock()
    private let audioQueue = DispatchQueue(label: "com.voicescribe.systemaudio", qos: .userInitiated)

    /// 电平回调（0.0 ~ 1.0），在 audioQueue 调用
    public var onLevel: (@Sendable (Float) -> Void)?

    /// PCM buffer 回调（已拷贝，可安全交给语音识别），在 audioQueue 调用
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public private(set) var isRecording = false
    public private(set) var isPaused = false

    public override init() { super.init() }

    /// 检测屏幕录制权限（首次调用会触发 TCC 授权流程）
    public static func checkPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    public func start(fileURL: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStream 无法完全关闭视频通道，最小化开销
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        lock.withLock {
            file = nil
            pendingFileURL = fileURL
        }

        try await stream.startCapture()
        self.stream = stream
        isRecording = true
        isPaused = false
    }

    public func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true   // 保持 SCStream 运行，暂停期间丢弃音频帧（不写盘）
    }

    public func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
    }

    public func stop() async {
        guard isRecording, let stream else { return }
        isRecording = false
        isPaused = false
        do { try await stream.stopCapture() } catch { /* 已停止 */ }
        self.stream = nil
        audioQueue.sync {
            lock.withLock {
                self.file = nil
                self.pendingFileURL = nil
            }
        }
    }

    // MARK: - 音频处理

    private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        if isPaused { return }   // 暂停期间丢弃（含转写，与写盘一致）
        // 首帧到达时，用实际格式创建文件
        lock.withLock {
            if file == nil, let url = pendingFileURL,
               let formatDescription = sampleBuffer.formatDescription,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: asbd.pointee.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.pointee.mChannelsPerFrame),
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: true,
                ]
                file = try? AVAudioFile(
                    forWriting: url,
                    settings: audioSettings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            }
        }

        guard let desc = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)

        try? sampleBuffer.withAudioBufferList { bufferList, _ -> Void in
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                   bufferListNoCopy: bufferList.unsafePointer,
                                                   deallocator: nil),
                  pcmBuffer.frameLength > 0 else { return }
            self.lock.withLock {
                do { try self.file?.write(from: pcmBuffer) } catch { /* 忽略 */ }
            }
            self.onLevel?(LevelMath.normalized(pcmBuffer))
            if self.onBuffer != nil, let copied = BufferCopy.copy(pcmBuffer) {
                self.onBuffer?(copied)
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        handleAudioBuffer(sampleBuffer)
    }
}
