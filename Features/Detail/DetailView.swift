import SwiftUI
import SwiftData
import AudioKit
import CoreModels

/// 录音详情页：总结（M4）/ 文稿（M2）/ 音频（M1）
struct DetailView: View {
    @Environment(\.modelContext) private var modelContext
    let recording: Recording
    @State private var playback = PlaybackController()
    @State private var selectedTab: Tab = .audio

    enum Tab: String, CaseIterable {
        case summary = "总结"
        case transcript = "文稿"
        case audio = "音频"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch selectedTab {
            case .summary:
                summaryPlaceholder
            case .transcript:
                transcriptPlaceholder
            case .audio:
                audioTab
            }
            Spacer()
        }
        .navigationTitle(recording.title)
        .onAppear { playback.load(recording: recording) }
        .onDisappear { playback.stop() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.createdAt.formatted(date: .long, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(durationString(recording.duration))
                        .font(.title3.monospacedDigit())
                    if recording.hasMicTrack {
                        Label("麦克风", systemImage: "mic.fill")
                    }
                    if recording.hasSystemTrack {
                        Label("系统声音", systemImage: "speaker.wave.2.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [RecordingStore.directory(for: recording.id)]
                )
            } label: {
                Label("Finder", systemImage: "folder")
            }
        }
        .padding()
    }

    // MARK: 音频 Tab

    private var audioTab: some View {
        VStack(spacing: 16) {
            // 传输控制
            HStack(spacing: 24) {
                Button {
                    playback.seek(to: max(0, playback.position - 10))
                } label: {
                    Image(systemName: "gobackward.10").font(.title2)
                }
                Button {
                    playback.isPlaying ? playback.pause() : playback.play()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(playback.isPlaying ? .orange : .accentColor)
                }
                Button {
                    playback.seek(to: min(playback.duration, playback.position + 10))
                } label: {
                    Image(systemName: "goforward.10").font(.title2)
                }
            }
            .buttonStyle(.plain)

            // 进度条
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { playback.position },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.01)
                )
                HStack {
                    Text(durationString(playback.position))
                    Spacer()
                    Text(durationString(playback.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            // 轨道开关
            GroupBox("轨道") {
                VStack(alignment: .leading, spacing: 8) {
                    if recording.hasMicTrack {
                        Toggle(isOn: Binding(
                            get: { playback.micEnabled },
                            set: { playback.micEnabled = $0 }
                        )) {
                            Label("麦克风（我）", systemImage: "mic.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    if recording.hasSystemTrack {
                        Toggle(isOn: Binding(
                            get: { playback.systemEnabled },
                            set: { playback.systemEnabled = $0 }
                        )) {
                            Label("系统声音（对方）", systemImage: "speaker.wave.3.fill")
                                .foregroundStyle(.purple)
                        }
                    }
                }
                .padding(6)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: 占位（M2 / M4）

    private var summaryPlaceholder: some View {
        ContentUnavailableView {
            Label("AI 总结", systemImage: "sparkles")
        } description: {
            Text("M4 里程碑：录音结束后由本地 Apple Intelligence 模型生成会议纪要")
        }
    }

    private var transcriptPlaceholder: some View {
        ContentUnavailableView {
            Label("转写文稿", systemImage: "text.quote")
        } description: {
            Text("M2 里程碑：本地语音识别将生成带时间戳的逐句文稿")
        }
    }

    private func durationString(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "00:00" }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
