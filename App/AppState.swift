import Foundation
import Observation
import SwiftData
import AVFoundation
import AudioKit
import CoreModels

/// 全局应用状态：主窗口与 MenuBar 共享同一个录音 VM
@MainActor
@Observable
final class AppState {
    let recorder = RecordViewModel()
    let permissions = PermissionCenter.shared

    var isRecording: Bool { recorder.phase != .idle }

    func makeModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Recording.self, TranscriptSegment.self, SummaryDoc.self)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }

    /// 崩溃恢复：把上次异常退出遗留的 .recording 状态录音收尾
    func recoverInterruptedRecordings(context: ModelContext) {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.statusRaw == "recording" }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
        for r in stale {
            let micURL = RecordingStore.micFileURL(for: r.id)
            let sysURL = RecordingStore.systemFileURL(for: r.id)
            r.hasMicTrack = RecordingStore.hasAudio(at: micURL)
            r.hasSystemTrack = RecordingStore.hasAudio(at: sysURL)
            if r.duration <= 0 {
                let url = r.hasMicTrack ? micURL : sysURL
                r.duration = Self.estimateDuration(url: url)
            }
            r.status = (r.hasMicTrack || r.hasSystemTrack) ? .done : .failed
        }
        try? context.save()
    }

    /// 从音频文件估算时长（崩溃恢复用，同步读取文件头）
    static func estimateDuration(url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }
}
