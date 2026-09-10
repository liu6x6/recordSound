import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple 端侧 LLM（FoundationModels / Apple Intelligence）总结 Provider
///
/// 流程：转写全文 → Chunker 分块 → 逐块提取要点（map）→ 汇总（reduce）
///      → guided generation 输出结构化文档
public final class AppleLLMProvider: Sendable {

    public init() {}

    // MARK: 可用性

    /// 端侧 LLM 是否可用；不可用时返回对应错误（供 UI 展示原因）
    public static func availabilityError() -> SummarizationError? {
        guard #available(macOS 26.0, *) else { return .osNotSupported }
        return availabilityErrorOnNewOS()
    }

    public static var isAvailable: Bool { availabilityError() == nil }

    @available(macOS 26.0, *)
    private static func availabilityErrorOnNewOS() -> SummarizationError? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        @unknown default:
            return .modelNotReady
        }
    }

    // MARK: 生成

    /// 总结一段转写全文（带说话方标注与时间戳的纯文本）
    public func summarize(
        transcript: String,
        template: SummaryTemplate,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> SummaryResult {
        guard #available(macOS 26.0, *) else { throw SummarizationError.osNotSupported }
        return try await summarizeOnNewOS(transcript: transcript, template: template, onProgress: onProgress)
    }

    @available(macOS 26.0, *)
    private func summarizeOnNewOS(
        transcript: String,
        template: SummaryTemplate,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> SummaryResult {
        if let error = Self.availabilityErrorOnNewOS() { throw error }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizationError.emptyTranscript }

        let model = SystemLanguageModel.default
        let session = LanguageModelSession(model: model, instructions: template.instructions)

        // ── Map：长文分块提取要点 ──
        let chunks = Chunker.split(trimmed, maxChars: 1200)
        var source: String
        if chunks.count > 1 {
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                onProgress?("提取要点 \(index + 1)/\(chunks.count)…")
                do {
                    let note = try await session.respond(
                        to: "请从以下转写片段中提取要点（保留人名、数字、日期、待办；输出不超过 200 字的要点列表）：\n\n\(chunk)"
                    )
                    notes.append(note.content)
                } catch {
                    // 单块失败不中断，跳过
                    continue
                }
            }
            guard !notes.isEmpty else {
                throw SummarizationError.generationFailed("所有分段要点提取均失败")
            }

            // ── Reduce：合并笔记（若仍超长则再压缩）──
            source = notes.joined(separator: "\n")
            var rounds = 0
            while source.count > 2500 && rounds < 3 {
                try Task.checkCancellation()
                onProgress?("合并要点…")
                let condensed = try await session.respond(
                    to: "请把以下笔记合并精简为不超过 1500 字的要点（保留所有关键信息，不丢人名/数字/待办）：\n\n\(source)"
                )
                source = condensed.content
                rounds += 1
            }
        } else {
            source = trimmed
        }

        // ── 结构化输出 ──
        try Task.checkCancellation()
        onProgress?("生成\(template.displayName)…")
        do {
            let output = try await session.respond(
                to: """
                请基于以下内容生成结构化\(template.displayName)。字段语义：\(template.fieldHints)。

                内容：
                \(source)
                """,
                generating: GuidedSummaryDoc.self
            )
            let doc = output.content
            return SummaryResult(
                overview: doc.overview,
                keyPoints: doc.keyPoints,
                decisions: doc.decisions,
                actionItems: doc.actionItems.map {
                    SummaryResult.ActionItemResult(owner: $0.owner, task: $0.task, due: $0.due)
                },
                keywords: doc.keywords,
                modelIdentifier: "apple-foundation-model"
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw SummarizationError.generationFailed(String(describing: error))
        } catch {
            throw SummarizationError.generationFailed(error.localizedDescription)
        }
    }
}

// MARK: - Guided Generation Schema

@available(macOS 26.0, *)
@Generable(description: "结构化的转写总结文档")
public struct GuidedSummaryDoc {

    @Guide(description: "不超过 150 字的整体概要")
    public var overview: String = ""

    @Guide(description: "关键要点列表，每条一句话，按重要性排序")
    public var keyPoints: [String] = []

    @Guide(description: "达成的决议 / 重要结论 / 核心观点，可为空")
    public var decisions: [String] = []

    @Guide(description: "待办事项列表，可为空")
    public var actionItems: [GuidedActionItem] = []

    @Guide(description: "3~8 个关键词")
    public var keywords: [String] = []

    public init() {}
}

@available(macOS 26.0, *)
@Generable(description: "一条待办事项")
public struct GuidedActionItem {

    @Guide(description: "负责人，无法确定时为空字符串")
    public var owner: String = ""

    @Guide(description: "要做的事情")
    public var task: String = ""

    @Guide(description: "截止时间或时间描述，无法确定时为空字符串")
    public var due: String = ""

    public init() {}
}
