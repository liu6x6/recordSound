import AVFoundation
@preconcurrency import Speech

/// Apple Speech 端侧流式识别 Provider
///
/// 设计要点：
/// - `requiresOnDeviceRecognition = true`（若机型支持），数据不出设备
/// - Apple 对单个识别任务有时长限制 → 任务结束（final/error）后自动重启新任务，
///   已提交文本不受影响（committed 以"任务内滚动文本"为基准，重启时清零）
/// - 句子提交策略：出现句末标点（。！？.!?）或任务 final 时，把稳定前缀提交为 segment；
///   其余部分作为 partial 实时字幕回调
public final class SpeechLiveProvider: @unchecked Sendable {

    public enum ProviderError: LocalizedError {
        case notAuthorized
        case recognizerUnavailable
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .notAuthorized: return "语音识别权限未授权"
            case .recognizerUnavailable: return "语音识别器不可用（请检查系统语言支持或网络）"
            case .notRunning: return "识别器未在运行"
            }
        }
    }

    // MARK: 回调（在识别器内部队列调用，均 @Sendable）

    /// 已提交的完整句子
    public var onSegmentCommitted: (@Sendable (String) -> Void)?
    /// 当前未提交的滚动字幕（可能为空）
    public var onPartial: (@Sendable (String) -> Void)?
    /// 运行错误（如权限被回收）
    public var onError: (@Sendable (String) -> Void)?

    nonisolated(unsafe) private let recognizer: SFSpeechRecognizer?
    private let localeIdentifier: String
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()

    private var running = false
    private var rollingText = ""      // 当前任务内累计文本
    private var committedLength = 0   // 已提交前缀长度

    public init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = localeIdentifier
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    // MARK: 静态：权限

    public static var authStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// 端侧识别是否可用（供设置页展示）
    public var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: 生命周期

    public func start() throws {
        guard Self.authStatus == .authorized else { throw ProviderError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw ProviderError.recognizerUnavailable }
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        startTask(recognizer: recognizer)
    }

    /// 结束音频输入并等待最后一批结果提交（宽限期），然后停止
    public func finish(gracePeriod: TimeInterval = 1.0) async {
        let wasRunning = lock.withLock { () -> Bool in
            guard running else { return false }
            return true
        }
        guard wasRunning else { return }

        request?.endAudio()
        // 等待 final 回调把尾句提交
        try? await Task.sleep(for: .seconds(gracePeriod))

        lock.withLock {
            running = false
            task?.cancel()
            task = nil
            request = nil
        }
    }

    public func cancel() {
        lock.lock()
        running = false
        task?.cancel()
        task = nil
        request = nil
        lock.unlock()
    }

    /// 喂入 PCM 音频（float32，任意采样率/声道）
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        let running = self.running
        lock.unlock()
        guard running, let request else { return }
        request.append(buffer)
    }

    // MARK: 内部

    private func startTask(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true
        request.taskHint = .dictation

        lock.lock()
        self.request = request
        self.rollingText = ""
        self.committedLength = 0
        let isRunning = running
        lock.unlock()
        guard isRunning else { return }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.handleResult(result)
            }
            if error != nil || result?.isFinal == true {
                self.lock.lock()
                let shouldRestart = self.running
                self.task = nil
                self.request = nil
                self.lock.unlock()

                if shouldRestart {
                    // 单个识别任务到达系统时长上限 → 稍候重启新任务
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self, let recognizer = self.recognizer else { return }
                        self.lock.lock()
                        let stillRunning = self.running
                        self.lock.unlock()
                        if stillRunning { self.startTask(recognizer: recognizer) }
                    }
                }
            }
        }
        lock.lock()
        self.task = task
        lock.unlock()
    }

    private static let sentenceEnders: Set<Character> = ["。", "！", "？", "!", "?", ".", "；", ";"]

    private func handleResult(_ result: SFSpeechRecognitionResult) {
        lock.lock()
        let text = result.bestTranscription.formattedString
        rollingText = text
        let committed = String(text.prefix(committedLength))
        let rest = String(text.dropFirst(committedLength))
        lock.unlock()
        _ = committed

        if result.isFinal {
            // 全部提交
            commitAll(text: text, rest: rest)
            return
        }

        // 找 rest 中最后一个句末标点，提交到该处
        if let lastEndIndex = rest.lastIndex(where: { Self.sentenceEnders.contains($0) }) {
            let toCommit = String(rest[rest.startIndex...lastEndIndex])
            lock.lock()
            committedLength += toCommit.count
            lock.unlock()
            let cleaned = toCommit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                onSegmentCommitted?(cleaned)
            }
            emitPartial()
        } else {
            onPartial?(rest.trimmingCharacters(in: .whitespaces))
        }
    }

    private func commitAll(text: String, rest: String) {
        let cleaned = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        committedLength = text.count
        lock.unlock()
        if !cleaned.isEmpty {
            onSegmentCommitted?(cleaned)
        }
        onPartial?("")
    }

    private func emitPartial() {
        lock.lock()
        let rest = String(rollingText.dropFirst(committedLength))
            .trimmingCharacters(in: .whitespaces)
        lock.unlock()
        onPartial?(rest)
    }
}
