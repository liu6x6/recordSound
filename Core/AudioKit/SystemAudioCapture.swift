import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// 系统声音采集：SCStream(capturesAudio: true) → 写 CAF 文件 + 电平回调
/// Spike 阶段：录主显示器对应音频，排除本进程声音，忽略视频帧
final class SystemAudioCapture: NSObject, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "屏幕录制权限未授权（系统声音捕获需要此权限）"
            case .noDisplay: return "未找到可用显示器"
            case .streamFailed(let msg): return "SCStream 失败: \(msg)"
            }
        }
    }

    private var stream: SCStream?
    private var file: AVAudioFile?
    private let fileURLLock = NSLock()
    private let audioQueue = DispatchQueue(label: "com.voicescribe.systemaudio", qos: .userInitiated)

    /// 电平回调（0.0 ~ 1.0），在 audioQueue 调用
    var onLevel: ((Float) -> Void)?

    private(set) var isRecording = false

    /// 触发/检测屏幕录制权限（首次调用会弹 TCC 授权框）
    static func checkPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func start(fileURL: URL) async throws {
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
        // 视频部分最小化（SCStream 无法完全关闭视频通道）
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        fileURLLock.withLock {
            file = nil
            pendingFileURL = fileURL
        }

        try await stream.startCapture()
        self.stream = stream
        isRecording = true
    }

    private var pendingFileURL: URL?

    func stop() async {
        guard isRecording, let stream else { return }
        isRecording = false
        do { try await stream.stopCapture() } catch { /* 已停止 */ }
        self.stream = nil
        audioQueue.sync {
            fileURLLock.withLock {
                self.file = nil
            }
        }
    }

    private func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        // 首帧到达时，用实际格式创建文件
        fileURLLock.withLock {
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
            fileURLLock.withLock {
                do { try self.file?.write(from: pcmBuffer) } catch { /* spike: 忽略 */ }
            }
            onLevel?(Self.rms(pcmBuffer))
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        var count: Int = 0
        for i in stride(from: 0, to: n, by: 4) { sum += data[i] * data[i]; count += 1 }
        guard count > 0 else { return 0 }
        let rms = sqrtf(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 40) / 40, 0), 1)
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRecording = false
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        handleAudioBuffer(sampleBuffer)
    }
}
