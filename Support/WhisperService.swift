import Foundation
import Observation
import SwiftData
import UserNotifications
import AudioKit
import TranscriptionKit
import CoreModels

/// Whisper 精转服务：模型下载管理 + 转写编排 + 设置项
@MainActor
@Observable
final class WhisperService {
    static let shared = WhisperService()

    // MARK: 设置（UserDefaults 持久化）

    private let defaults = UserDefaults.standard

    var defaultModel: WhisperModel {
        get {
            WhisperModel(rawValue: defaults.string(forKey: "whisper.defaultModel") ?? "")
                ?? .largeTurbo
        }
        set { defaults.set(newValue.rawValue, forKey: "whisper.defaultModel") }
    }

    /// 精转语言："auto"（中英混说）/ "zh" / "en"
    var refineLanguage: String {
        get { defaults.string(forKey: "whisper.language") ?? "auto" }
        set { defaults.set(newValue, forKey: "whisper.language") }
    }

    /// 录音结束后自动精转
    var autoRefine: Bool {
        get { defaults.bool(forKey: "whisper.autoRefine") }
        set { defaults.set(newValue, forKey: "whisper.autoRefine") }
    }

    /// 实时转写语言（Apple Speech locale）
    var liveASRLocale: String {
        get { defaults.string(forKey: "asr.liveLocale") ?? "zh-CN" }
        set { defaults.set(newValue, forKey: "asr.liveLocale") }
    }

    // MARK: 运行状态

    struct RefineState: Equatable {
        var statusText: String = ""
    }

    private(set) var refineStates: [UUID: RefineState] = [:]
    private(set) var modelDownloads: [String: String] = [:]   // model rawValue → 状态文案

    private let provider = WhisperProvider()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isRefining(_ id: UUID) -> Bool { refineStates[id] != nil }

    // MARK: 模型管理

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        WhisperProvider.isModelDownloaded(model)
    }

    func downloadModel(_ model: WhisperModel) {
        guard modelDownloads[model.rawValue] == nil else { return }
        modelDownloads[model.rawValue] = "准备下载…"
        Task {
            do {
                try await provider.preloadModel(model) { [weak self] state in
                    Task { @MainActor in self?.modelDownloads[model.rawValue] = state }
                }
                modelDownloads[model.rawValue] = nil
            } catch {
                modelDownloads[model.rawValue] = "失败: \(error.localizedDescription)"
            }
        }
    }

    func deleteModel(_ model: WhisperModel) {
        try? WhisperProvider.deleteModel(model)
    }

    // MARK: 精转编排

    /// 启动某条录音的精转（后台 Task，可取消）
    func refine(recordingID: UUID, context: ModelContext) {
        guard refineStates[recordingID] == nil else { return }

        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })
        guard let recording = try? context.fetch(descriptor).first else { return }
        guard recording.hasMicTrack || recording.hasSystemTrack else { return }

        refineStates[recordingID] = RefineState(statusText: "排队中…")
        recording.status = .processing
        try? context.save()

        let language = refineLanguage
        let model = defaultModel

        tasks[recordingID] = Task { [weak self] in
            guard let self else { return }
            await self.runRefine(recording: recording, model: model, language: language, context: context)
        }
    }

    func cancelRefine(_ id: UUID) {
        tasks[id]?.cancel()
    }

    private func runRefine(recording: Recording, model: WhisperModel, language: String, context: ModelContext) async {
        let id = recording.id

        func setState(_ text: String) {
            refineStates[id] = RefineState(statusText: text)
        }

        do {
            var collected: [(Channel, WhisperSegment)] = []

            if recording.hasMicTrack {
                let url = RecordingStore.micFileURL(for: id)
                setState("精转麦克风轨（我）…")
                let segs = try await provider.transcribe(fileURL: url, model: model, language: language) { [weak self] state in
                    Task { @MainActor in
                        self?.refineStates[id] = RefineState(statusText: state)
                    }
                }
                collected += segs.map { (.mic, $0) }
            }

            try Task.checkCancellation()

            if recording.hasSystemTrack {
                let url = RecordingStore.systemFileURL(for: id)
                setState("精转系统声音轨（对方）…")
                let segs = try await provider.transcribe(fileURL: url, model: model, language: language) { [weak self] state in
                    Task { @MainActor in
                        self?.refineStates[id] = RefineState(statusText: state)
                    }
                }
                collected += segs.map { (.system, $0) }
            }

            try Task.checkCancellation()

            // 替换旧片段（实时稿 → Whisper 终稿）
            setState("写入转写结果…")
            for old in recording.segments {
                context.delete(old)
            }
            recording.segments.removeAll()

            let sorted = collected.sorted { $0.1.start < $1.1.start }
            for (channel, seg) in sorted {
                let transcript = TranscriptSegment(
                    start: seg.start, end: max(seg.end, seg.start + 0.3),
                    text: seg.text, channel: channel, isFinal: true
                )
                transcript.recording = recording
                recording.segments.append(transcript)
            }

            recording.finalEngineRaw = ASREngine.whisper.rawValue
            recording.status = .refinedDone
            try context.save()

            setState("")
            refineStates[id] = nil
            notify(title: "精转完成", body: "「\(recording.title)」的 Whisper 终稿已生成")

            // 精转完成 → 自动总结（设置开启时）
            SummarizationService.shared.autoGenerateIfNeeded(recording: recording, context: context)
        } catch is CancellationError {
            refineStates[id] = nil
            recording.status = recording.segments.isEmpty ? .done : .liveDone
            try? context.save()
        } catch {
            setState("失败: \(error.localizedDescription)")
            recording.status = recording.segments.isEmpty ? .done : .liveDone
            try? context.save()
            // 3 秒后清掉错误状态
            Task {
                try? await Task.sleep(for: .seconds(5))
                self.refineStates[id] = nil
            }
        }
        tasks[id] = nil
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
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        center.add(request)
    }
}
