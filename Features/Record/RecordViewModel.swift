import Foundation
import Observation
import SwiftData
import AudioKit
import CoreModels

/// 录音页 ViewModel：驱动 RecordingSession + 维护 SwiftData Recording 记录
@MainActor
@Observable
final class RecordViewModel {

    enum Phase: Equatable {
        case idle, recording, paused
    }

    // 用户音源选择
    var captureMic = true
    var captureSystem = true

    // 运行状态
    private(set) var phase: Phase = .idle
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var elapsed: TimeInterval = 0
    var statusMessage: String?

    /// 录音结束回调（跳转详情等）
    var onFinished: ((Recording) -> Void)?

    private var session: RecordingSession?
    private var activeRecording: Recording?
    private var timer: Timer?

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

        let formatter = Date.FormatStyle().year().month().day().hour().minute()
        let recording = Recording(
            id: session.id,
            title: "录音 \(Date.now.formatted(formatter))",
            hasMicTrack: doMic,
            hasSystemTrack: doSystem,
            status: .recording
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

        let result = await session.stop()

        recording.duration = result.duration
        recording.hasMicTrack = result.micFileURL != nil
        recording.hasSystemTrack = result.systemFileURL != nil
        recording.status = (result.micFileURL != nil || result.systemFileURL != nil) ? .done : .failed
        try? context.save()

        self.session = nil
        self.activeRecording = nil
        self.phase = .idle
        self.micLevel = 0
        self.systemLevel = 0
        self.elapsed = 0

        if recording.status == .done {
            onFinished?(recording)
        } else {
            statusMessage = "录音失败：没有捕获到任何音频"
        }
    }
}
