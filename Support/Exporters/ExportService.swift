import AppKit
import AVFoundation
import UniformTypeIdentifiers
import AudioKit
import CoreModels
import SwiftData

/// 导出服务：Markdown / SRT / 纯文本 / 混音 m4a
@MainActor
enum ExportService {

    enum ExportError: LocalizedError {
        case nothingToExport
        case mixdownFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingToExport: return "没有可导出的内容"
            case .mixdownFailed(let msg): return "混音导出失败: \(msg)"
            }
        }
    }

    enum ExportKind: String, CaseIterable, Identifiable {
        case markdown = "Markdown（总结+文稿）"
        case srt = "SRT 字幕"
        case plainText = "纯文本文稿"
        case mixedAudio = "混音音频（m4a）"
        var id: String { rawValue }
    }

    // MARK: 内容构建

    static func markdown(for recording: Recording) -> String {
        var md = "# \(recording.title)\n\n"
        md += "- 日期：\(recording.createdAt.formatted(date: .long, time: .shortened))\n"
        md += "- 时长：\(durationString(recording.duration))\n"
        var tracks: [String] = []
        if recording.hasMicTrack { tracks.append("麦克风") }
        if recording.hasSystemTrack { tracks.append("系统声音") }
        md += "- 音轨：\(tracks.joined(separator: " + "))\n\n"

        if let summary = recording.summary {
            md += "---\n\n# AI 总结\n\n\(summary.markdown)\n\n"
        }
        if !recording.segments.isEmpty {
            md += "---\n\n# 转写文稿\n\n"
            for seg in recording.segments.sorted(by: { $0.start < $1.start }) {
                let speaker = seg.channel == .mic ? "**我**" : "**对方**"
                md += "- `[\(durationString(seg.start))]` \(speaker)：\(seg.text)\n"
            }
            md += "\n"
        }
        md += "\n> 由 VoiceScribe 生成 · 全部处理均在设备本地完成\n"
        return md
    }

    static func srt(for recording: Recording) -> String {
        let sorted = recording.segments.sorted { $0.start < $1.start }
        var out = ""
        for (i, seg) in sorted.enumerated() {
            let speaker = seg.channel == .mic ? "我" : "对方"
            out += "\(i + 1)\n"
            out += "\(srtTime(seg.start)) --> \(srtTime(max(seg.end, seg.start + 0.5)))\n"
            out += "\(speaker): \(seg.text)\n\n"
        }
        return out
    }

    private static func srtTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let ms = Int((t - floor(t)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func plainText(for recording: Recording) -> String {
        recording.segments.sorted { $0.start < $1.start }.map { seg in
            let speaker = seg.channel == .mic ? "我" : "对方"
            return "\(speaker)：\(seg.text)"
        }.joined(separator: "\n")
    }

    // MARK: 混音导出（mic + system → 立体声 AAC m4a，离线渲染）

    static func mixdown(recording: Recording, to outputURL: URL) async throws {
        var sourceURLs: [URL] = []
        if recording.hasMicTrack { sourceURLs.append(RecordingStore.micFileURL(for: recording.id)) }
        if recording.hasSystemTrack { sourceURLs.append(RecordingStore.systemFileURL(for: recording.id)) }
        guard !sourceURLs.isEmpty else { throw ExportError.nothingToExport }

        try await Task.detached(priority: .userInitiated) {
            // 在后台重新打开文件（避免跨隔离域传递非 Sendable 对象）
            var files: [AVAudioFile] = []
            var maxDuration: TimeInterval = 0
            for url in sourceURLs {
                let file = try AVAudioFile(forReading: url)
                maxDuration = max(maxDuration, Double(file.length) / file.processingFormat.sampleRate)
                files.append(file)
            }
            guard maxDuration > 0 else { throw ExportError.nothingToExport }

            let engine = AVAudioEngine()
            let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

            do {
                try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 8192)

                var players: [AVAudioPlayerNode] = []
                for file in files {
                    let player = AVAudioPlayerNode()
                    engine.attach(player)
                    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
                    players.append(player)
                }

                try engine.start()
                for (player, file) in zip(players, files) {
                    player.scheduleFile(file, at: nil)
                    player.play()
                }

                let outputFile = try AVAudioFile(forWriting: outputURL, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)

                let totalFrames = AVAudioFramePosition(maxDuration * 48_000) + 48_000  // +1s 尾余
                let maxFrames: AVAudioFrameCount = 8192
                guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                    frameCapacity: maxFrames) else {
                    throw ExportError.mixdownFailed("无法创建渲染缓冲")
                }
                var rendered: AVAudioFramePosition = 0
                while rendered < totalFrames {
                    let frames = min(buffer.frameCapacity, AVAudioFrameCount(totalFrames - rendered))
                    let status = try engine.renderOffline(frames, to: buffer)
                    guard status == .success else { break }
                    try outputFile.write(from: buffer)
                    rendered += AVAudioFramePosition(buffer.frameLength)
                }
                engine.stop()
            } catch {
                engine.stop()
                throw ExportError.mixdownFailed(error.localizedDescription)
            }
        }.value
    }

    // MARK: 导出入口（NSSavePanel）

    static func export(_ recording: Recording, kind: ExportKind) async -> Bool {
        let baseName = sanitized(recording.title)
        var targetURL: URL?
        var content: String?

        switch kind {
        case .markdown:
            guard let url = savePanel(defaultName: "\(baseName).md", fileTypes: ["md"]) else { return false }
            targetURL = url; content = markdown(for: recording)
        case .srt:
            guard !recording.segments.isEmpty,
                  let url = savePanel(defaultName: "\(baseName).srt", fileTypes: ["srt"]) else { return false }
            targetURL = url; content = srt(for: recording)
        case .plainText:
            guard !recording.segments.isEmpty,
                  let url = savePanel(defaultName: "\(baseName).txt", fileTypes: ["txt"]) else { return false }
            targetURL = url; content = plainText(for: recording)
        case .mixedAudio:
            guard let url = savePanel(defaultName: "\(baseName).m4a", fileTypes: ["m4a"]) else { return false }
            targetURL = url
        }

        guard let targetURL else { return false }

        if let content {
            do {
                try content.write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
        } else {
            do {
                try await mixdown(recording: recording, to: targetURL)
            } catch {
                return false
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
        return true
    }

    private static func savePanel(defaultName: String, fileTypes: [String]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func sanitized(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func durationString(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "00:00" }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
