import Foundation
import SwiftData

// MARK: - 枚举

public enum RecordingStatus: String, Codable, Sendable {
    case recording      // 录音中
    case processing     // 转写/总结处理中
    case liveDone       // 实时转写完成（终稿待精转）
    case refinedDone    // 精转 + 总结完成
    case done           // 仅录音完成（未启用 AI）
    case failed
}

public enum Channel: String, Codable, Sendable {
    case mic            // 我（本机麦克风）
    case system         // 对方（其他 App 声音）
}

public enum ASREngine: String, Codable, Sendable {
    case none
    case appleSpeech
    case whisper
}

// MARK: - Recording

@Model
public final class Recording {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var hasMicTrack: Bool
    public var hasSystemTrack: Bool
    public var statusRaw: String
    public var liveEngineRaw: String
    public var finalEngineRaw: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.recording)
    public var segments: [TranscriptSegment] = []

    @Relationship(deleteRule: .cascade, inverse: \SummaryDoc.recording)
    public var summary: SummaryDoc?

    public var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .done }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        hasMicTrack: Bool = false,
        hasSystemTrack: Bool = false,
        status: RecordingStatus = .recording,
        liveEngine: ASREngine = .none
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.hasMicTrack = hasMicTrack
        self.hasSystemTrack = hasSystemTrack
        self.statusRaw = status.rawValue
        self.liveEngineRaw = liveEngine.rawValue
        self.finalEngineRaw = nil
    }
}

// MARK: - TranscriptSegment（M2 使用）

@Model
public final class TranscriptSegment {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var channelRaw: String
    public var isFinal: Bool

    public var recording: Recording?

    public var channel: Channel {
        get { Channel(rawValue: channelRaw) ?? .mic }
        set { channelRaw = newValue.rawValue }
    }

    public init(start: TimeInterval, end: TimeInterval, text: String, channel: Channel, isFinal: Bool = false) {
        self.start = start
        self.end = end
        self.text = text
        self.channelRaw = channel.rawValue
        self.isFinal = isFinal
    }
}

// MARK: - SummaryDoc（M4 使用）

@Model
public final class SummaryDoc {
    public var generatedAt: Date
    public var templateKind: String
    public var markdown: String
    public var keywords: [String]
    public var model: String

    public var recording: Recording?

    public init(generatedAt: Date = .now, templateKind: String = "meeting", markdown: String, keywords: [String] = [], model: String) {
        self.generatedAt = generatedAt
        self.templateKind = templateKind
        self.markdown = markdown
        self.keywords = keywords
        self.model = model
    }
}
