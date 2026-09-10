import Foundation

/// 总结模板类型
public enum SummaryTemplate: String, CaseIterable, Sendable, Identifiable {
    case meeting     // 会议纪要
    case lecture     // 课程笔记
    case interview   // 访谈整理

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .meeting: return "会议纪要"
        case .lecture: return "课程笔记"
        case .interview: return "访谈整理"
        }
    }

    /// 系统指令（LanguageModelSession instructions）
    public var instructions: String {
        switch self {
        case .meeting:
            return """
            你是专业的会议记录助手。输入是带说话方标注的会议转写（"我"=本机麦克风录到的发言人，"对方"=其他应用的声音）。
            要求：忠于原文，不编造；保留人名、数字、日期、金额等关键信息；输出使用与转写内容一致的语言（中文转写用中文输出，英文用英文）。
            """
        case .lecture:
            return """
            你是学习笔记助手。输入是课程/讲座/视频的转写。
            要求：提炼知识结构与核心概念，按逻辑分条整理知识点；保留术语、公式、示例；输出使用与转写内容一致的语言。
            """
        case .interview:
            return """
            你是访谈整理助手。输入是访谈/对话转写（"我"与"对方"两方）。
            要求：按主题归纳问答要点，突出双方观点与关键引语；输出使用与转写内容一致的语言。
            """
        }
    }

    /// 各模板下字段的语义提示（用于 guided generation 的 prompt 补充）
    public var fieldHints: String {
        switch self {
        case .meeting:
            return "overview=会议概要；keyPoints=关键讨论点；decisions=达成的决议；actionItems=待办（尽量提取负责人与时间）"
        case .lecture:
            return "overview=课程主题概要；keyPoints=核心知识点（按讲解顺序）；decisions=重要结论/公式/定义；actionItems=课后练习或延伸阅读（如无则为空）"
        case .interview:
            return "overview=访谈主题概要；keyPoints=按主题归纳的问答要点；decisions=受访者最重要的观点/表态；actionItems=后续跟进事项（如无则为空）"
        }
    }
}

/// 总结输出
public struct SummaryResult: Sendable {
    public let overview: String
    public let keyPoints: [String]
    public let decisions: [String]
    public let actionItems: [ActionItemResult]
    public let keywords: [String]
    public let modelIdentifier: String

    public struct ActionItemResult: Sendable {
        public let owner: String
        public let task: String
        public let due: String
    }

    /// 渲染为 Markdown（SummaryDoc.markdown 存储）
    public func markdown(template: SummaryTemplate) -> String {
        var md = "## 概要\n\n\(overview)\n\n## 关键要点\n\n"
        md += keyPoints.map { "- \($0)" }.joined(separator: "\n")
        if !decisions.isEmpty {
            md += "\n\n## \(template == .lecture ? "重要结论" : (template == .interview ? "核心观点" : "决议"))\n\n"
            md += decisions.map { "- \($0)" }.joined(separator: "\n")
        }
        if !actionItems.isEmpty {
            md += "\n\n## 待办事项\n\n"
            md += actionItems.map { item in
                var line = "- [ ] \(item.task)"
                var meta: [String] = []
                if !item.owner.isEmpty { meta.append("负责人: \(item.owner)") }
                if !item.due.isEmpty { meta.append("时间: \(item.due)") }
                if !meta.isEmpty { line += "（\(meta.joined(separator: "，"))）" }
                return line
            }.joined(separator: "\n")
        }
        if !keywords.isEmpty {
            md += "\n\n## 关键词\n\n" + keywords.joined(separator: " · ")
        }
        return md
    }
}

public enum SummarizationError: LocalizedError, Sendable {
    case osNotSupported
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case emptyTranscript
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .osNotSupported: return "需要 macOS 26 或更高版本"
        case .deviceNotEligible: return "此设备不支持 Apple Intelligence（需 Apple Silicon 机型）"
        case .appleIntelligenceNotEnabled: return "未开启 Apple Intelligence（系统设置 → Apple Intelligence 与 Siri）"
        case .modelNotReady: return "端侧模型未就绪（系统可能正在下载模型，请稍后重试）"
        case .emptyTranscript: return "没有可总结的转写内容（请先完成实时转写或 Whisper 精转）"
        case .generationFailed(let msg): return "生成失败: \(msg)"
        }
    }
}
