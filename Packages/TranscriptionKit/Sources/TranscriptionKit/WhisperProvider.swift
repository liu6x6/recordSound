import Foundation
import WhisperKit

/// 精转输出片段（时间轴相对音频文件起点）
public struct WhisperSegment: Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 可选模型（多语言版，均支持中文+英文+auto 检测）
public enum WhisperModel: String, CaseIterable, Sendable, Identifiable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case largeTurbo = "large-v3-v20240930_626MB"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tiny: return "Tiny（最快，调试用）"
        case .base: return "Base（快）"
        case .small: return "Small（均衡）"
        case .largeTurbo: return "Large Turbo（推荐，中英最准）"
        }
    }

    public var approximateSizeMB: Int {
        switch self {
        case .tiny: return 60
        case .base: return 200
        case .small: return 650
        case .largeTurbo: return 800
        }
    }
}

/// WhisperKit（CoreML 端侧推理）封装：模型管理 + 文件精转
public final class WhisperProvider: @unchecked Sendable {

    public enum WhisperError: LocalizedError {
        case pipelineUnavailable
        case transcriptionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .pipelineUnavailable: return "Whisper 模型管线不可用"
            case .transcriptionFailed(let msg): return "Whisper 转写失败: \(msg)"
            }
        }
    }

    /// 模型存储目录：Application Support/VoiceScribe/WhisperModels
    public static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceScribe/WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var pipe: WhisperKit?
    private var loadedModel: WhisperModel?

    public init() {}

    // MARK: 模型管理（静态）

    public static func downloadedModelFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
    }

    public static func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let folder = modelFolderName(for: model)
        guard folder != nil else { return false }
        return true
    }

    /// WhisperKit 下载后的文件夹名形如 whisperkit-coreml-<model>；以实际扫描为准
    public static func modelFolderName(for model: WhisperModel) -> String? {
        downloadedModelFolders().first { $0.contains(model.rawValue) }
    }

    public static func deleteModel(_ model: WhisperModel) throws {
        guard let folder = modelFolderName(for: model) else { return }
        try FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(folder))
    }

    // MARK: 转写

    /// 仅下载/加载模型（不转写），供设置页预下载
    public func preloadModel(
        _ model: WhisperModel,
        onState: (@Sendable (String) -> Void)? = nil
    ) async throws {
        if pipe != nil && loadedModel == model { return }
        if Self.isModelDownloaded(model) {
            onState?("加载模型…")
        } else {
            onState?("下载模型（约 \(model.approximateSizeMB) MB）…")
        }
        let config = WhisperKitConfig(
            model: model.rawValue,
            modelFolder: Self.modelsDirectory.path,
            verbose: false,
            logLevel: .error,
            download: true
        )
        pipe = try await WhisperKit(config)
        loadedModel = model
        onState?("完成")
    }

    /// 加载模型（首次自动从 HuggingFace 下载）并转写整个音频文件
    /// - Parameters:
    ///   - fileURL: 音频文件（caf/wav/m4a）
    ///   - model: 模型
    ///   - language: "auto"（自动检测，支持中英混说）/ "zh" / "en"
    ///   - onState: 状态文案回调（下载模型/加载模型/转写中）
    public func transcribe(
        fileURL: URL,
        model: WhisperModel,
        language: String = "auto",
        onState: (@Sendable (String) -> Void)? = nil
    ) async throws -> [WhisperSegment] {
        // 1. 确保管线就绪
        if pipe == nil || loadedModel != model {
            if Self.isModelDownloaded(model) {
                onState?("加载模型 \(model.rawValue)…")
            } else {
                onState?("下载模型 \(model.rawValue)（约 \(model.approximateSizeMB) MB，首次需要网络）…")
            }
            let config = WhisperKitConfig(
                model: model.rawValue,
                modelFolder: Self.modelsDirectory.path,
                verbose: false,
                logLevel: .error,
                download: true
            )
            pipe = try await WhisperKit(config)
            loadedModel = model
        }
        guard let pipe else { throw WhisperError.pipelineUnavailable }

        // 2. 转写（流式加载长音频，内存占用有界）
        onState?("转写中…")
        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: language == "auto" ? nil : language,
            detectLanguage: language == "auto" ? true : false,
            wordTimestamps: false
        )
        let audioOptions = AudioInputOptions(
            channelMode: .sumChannels(nil),
            audioLoadingMode: .incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioPath: fileURL.path,
                audioInputOptions: audioOptions,
                decodeOptions: decodeOptions
            )
        } catch {
            throw WhisperError.transcriptionFailed(error.localizedDescription)
        }

        // 3. 展平为带时间戳的片段
        return results
            .flatMap { $0.segments }
            .map {
                WhisperSegment(
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
    }
}
