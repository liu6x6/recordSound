import Foundation
import Observation
import SwiftData
import AudioKit
import TranscriptionKit
import CoreModels

/// 录音页 ViewModel：驱动 RecordingSession + 实时转写 + SwiftData Recording 记录
@MainActor
@Observable
final class RecordViewModel {

    enum Phase: Equatable {
        case idle, recording, paused
    }

    /// 已提交/待入库的实时转写片段
    struct PendingSegment {
        let channel: Channel
        let text: String
        let time: TimeInterval
    }

    // 用户选项
    var captureMic = true
    var captureSystem = true
    var liveTranscriptionEnabled = true

    // 运行状态
    private(set) var phase: Phase = .idle
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var elapsed: TimeInterval = 0
    var statusMessage: String?

    // 实时字幕
    private(set) var micCaption: String = ""
    private(set) var systemCaption: String = ""
    private(set) var pendingSegments: [PendingSegment] = []
    private(set) var liveTranscriptionActive = false

    /// 录音结束回调（跳转详情等）
    var onFinished: ((Recording) -> Void)?

    private var session: RecordingSession?
    private var activeRecording: Recording?
    private var timer: Timer?
    private var micASR: SpeechLiveProvider?
    private var systemASR: SpeechLiveProvider?

    func start(context: ModelContext) async {
        guard phase == .idle else { return }

        let perms = PermissionCenter.shared
        await perms.refresh()
        let doMic = captureMic && perms.micGranted
        let doSystem = captureSystem && perms.screenGranted
        guard doMic || doSystem else {
            statusMessage = "没有可用音源：请先在上方授权麦克风或屏幕录制权限"
            return
        }

        let session = RecordingSession()
        session.onMicLevel = { level in
            Task { @MainActor in self.micLevel = level }
        }
        session.onSystemLevel = { level in
            Task { @MainActor in self.systemLevel = level }
        }

        do {
            try await session.start(.init(captureMic: doMic, captureSystem: doSystem))
        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
            return
        }

        // 实时转写
        pendingSegments = []
        micCaption = ""
        systemCaption = ""
        var asrStarted = false
        if liveTranscriptionEnabled && perms.speechGranted {
            if doMic, let provider = makeProvider(channel: .mic, session: session) {
                session.onMicBuffer = { buffer in provider.append(buffer) }
                micASR = provider
                asrStarted = true
            }
            if doSystem, let provider = makeProvider(channel: .system, session: session) {
                session.onSystemBuffer = { buffer in provider.append(buffer) }
                systemASR = provider
                asrStarted = true
            }
        }
        liveTranscriptionActive = asrStarted

        let formatter = Date.FormatStyle().year().month().day().hour().minute()
        let recording = Recording(
            id: session.id,
            title: "录音 \(Date.now.formatted(formatter))",
            hasMicTrack: doMic,
            hasSystemTrack: doSystem,
            status: .recording,
            liveEngine: asrStarted ? .appleSpeech : .none
        )
        context.insert(recording)
        try? context.save()

        self.session = session
        self.activeRecording = recording
        self.phase = .recording
        self.elapsed = 0
        self.statusMessage = nil

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let session = self.session else { return }
                self.elapsed = session.elapsed
            }
        }
    }

    private func makeProvider(channel: Channel, session: RecordingSession) -> SpeechLiveProvider? {
        let locale = WhisperService.shared.liveASRLocale
        let provider = SpeechLiveProvider(localeIdentifier: locale)
        do {
            try provider.start()
        } catch {
            statusMessage = "实时转写启动失败（\(channel == .mic ? "麦克风" : "系统声音")）: \(error.localizedDescription)"
            return nil
        }
        provider.onSegmentCommitted = { [weak self] text in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                self.pendingSegments.append(
                    PendingSegment(channel: channel, text: text, time: session.elapsed)
                )
            }
        }
        provider.onPartial = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                if channel == .mic { self.micCaption = text } else { self.systemCaption = text }
            }
        }
        provider.onError = { [weak self] message in
            Task { @MainActor in self?.statusMessage = "转写错误: \(message)" }
        }
        return provider
    }

    func pause() async {
        guard phase == .recording, let session else { return }
        await session.pause()
        phase = .paused
        micLevel = 0
        systemLevel = 0
    }

    func resume() async {
        guard phase == .paused, let session else { return }
        do {
            try await session.resume()
            phase = .recording
        } catch {
            statusMessage = "恢复失败: \(error.localizedDescription)"
        }
    }

    func stop(context: ModelContext) async {
        guard phase != .idle, let session, let recording = activeRecording else { return }
        timer?.invalidate()
        timer = nil

        // 1. 先结束转写（喂完尾部音频，等待最后提交）
        let micASR = self.micASR, systemASR = self.systemASR
        self.micASR = nil
        self.systemASR = nil
        await micASR?.finish()
        await systemASR?.finish()
        micCaption = ""
        systemCaption = ""
        liveTranscriptionActive = false

        // 2. 停止音频采集
        let result = await session.stop()

        // 3. 更新数据库记录 + 写入转写片段
        recording.duration = result.duration
        recording.hasMicTrack = result.micFileURL != nil
        recording.hasSystemTrack = result.systemFileURL != nil
        recording.status = (result.micFileURL != nil || result.systemFileURL != nil) ? .done : .failed

        appendPendingSegments(to: recording)
        if !pendingSegments.isEmpty { recording.status = .liveDone }
        try? context.save()

        self.session = nil
        self.activeRecording = nil
        self.phase = .idle
        self.micLevel = 0
        self.systemLevel = 0
        self.elapsed = 0

        if recording.status == .failed {
            statusMessage = "录音失败：没有捕获到任何音频"
        } else {
            // 自动精转（设置中开启时）
            let whisper = WhisperService.shared
            if whisper.autoRefine && whisper.isModelDownloaded(whisper.defaultModel) {
                whisper.refine(recordingID: recording.id, context: context)
            }
            onFinished?(recording)
        }
    }

    /// 把实时转写片段写入 Recording（估算 end 时间：字数 × 0.28s，不超过下一段起点）
    private func appendPendingSegments(to recording: Recording) {
        let sorted = pendingSegments.sorted { $0.time < $1.time }
        for (index, seg) in sorted.enumerated() {
            let estimated = min(2.0 + Double(seg.text.count) * 0.28, 30.0)
            let nextStart = index + 1 < sorted.count ? sorted[index + 1].time : recording.duration
            let end = min(seg.time + estimated, max(nextStart, seg.time + 0.5))
            let transcript = TranscriptSegment(
                start: seg.time, end: end, text: seg.text, channel: seg.channel, isFinal: true
            )
            transcript.recording = recording
            recording.segments.append(transcript)
        }
        pendingSegments = []
    }
}
