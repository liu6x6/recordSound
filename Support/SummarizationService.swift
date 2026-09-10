import Foundation
import Observation
import SwiftData
import UserNotifications
import SummarizationKit
import CoreModels

/// 本地 AI 总结服务：编排转写全文 → AppleLLMProvider → SummaryDoc
@MainActor
@Observable
final class SummarizationService {
    static let shared = SummarizationService()

    private let defaults = UserDefaults.standard
    private let provider = AppleLLMProvider()

    // MARK: 设置

    var defaultTemplate: SummaryTemplate {
        get {
            SummaryTemplate(rawValue: defaults.string(forKey: "summary.template") ?? "") ?? .meeting
        }
        set { defaults.set(newValue.rawValue, forKey: "summary.template") }
    }

    /// 转写完成后自动生成总结
    var autoSummarize: Bool {
        get { defaults.object(forKey: "summary.auto") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "summary.auto") }
    }

    // MARK: 状态

    /// recordingID → 进行中状态文案 / 错误信息
    private(set) var states: [UUID: String] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var availabilityError: SummarizationError? { AppleLLMProvider.availabilityError() }

    func isSummarizing(_ id: UUID) -> Bool { states[id] != nil }

    // MARK: 生成

    func generate(recordingID: UUID, template: SummaryTemplate? = nil, context: ModelContext) {
        guard states[recordingID] == nil else { return }
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })
        guard let recording = try? context.fetch(descriptor).first else { return }

        let transcript = Self.buildTranscript(from: recording)
        guard !transcript.isEmpty else {
            states[recordingID] = SummarizationError.emptyTranscript.localizedDescription
            scheduleStateClear(recordingID, after: 5)
            return
        }

        let tpl = template ?? defaultTemplate
        states[recordingID] = "准备生成…"

        tasks[recordingID] = Task { [weak self] in
            guard let self else { return }
            await self.runGenerate(recording: recording, transcript: transcript, template: tpl, context: context)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    /// 自动总结（转写/精转完成后调用）：满足条件才触发
    func autoGenerateIfNeeded(recording: Recording, context: ModelContext) {
        guard autoSummarize,
              availabilityError == nil,
              recording.summary == nil,
              !recording.segments.isEmpty else { return }
        generate(recordingID: recording.id, context: context)
    }

    private func runGenerate(recording: Recording, transcript: String,
                             template: SummaryTemplate, context: ModelContext) async {
        let id = recording.id
        do {
            let result = try await provider.summarize(transcript: transcript, template: template) { [weak self] state in
                Task { @MainActor in self?.states[id] = state }
            }
            try Task.checkCancellation()

            // 替换旧总结
            if let old = recording.summary {
                context.delete(old)
                recording.summary = nil
            }
            let doc = SummaryDoc(
                templateKind: template.rawValue,
                markdown: result.markdown(template: template),
                keywords: result.keywords,
                model: result.modelIdentifier
            )
            doc.recording = recording
            recording.summary = doc
            try context.save()

            states[id] = nil
            notify(title: "总结已生成", body: "「\(recording.title)」的\(template.displayName)已就绪")
        } catch is CancellationError {
            states[id] = nil
        } catch {
            states[id] = "失败: \(error.localizedDescription)"
            scheduleStateClear(id, after: 8)
        }
        tasks[id] = nil
    }

    private func scheduleStateClear(_ id: UUID, after seconds: Int) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if let state = self.states[id], state.hasPrefix("失败") || state.contains("没有可总结") {
                self.states[id] = nil
            }
        }
    }

    // MARK: 转写全文构建

    /// 把 segments 拼成带说话方与时间戳的纯文本
    static func buildTranscript(from recording: Recording) -> String {
        let sorted = recording.segments.sorted { $0.start < $1.start }
        return sorted.map { seg in
            let speaker = seg.channel == .mic ? "我" : "对方"
            return "[\(timeString(seg.start))] \(speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    private static func timeString(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: 通知

    private var notificationAuthorized = false

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        if !notificationAuthorized {
            notificationAuthorized = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
