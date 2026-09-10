import SwiftUI
import SwiftData
import AudioKit
import SummarizationKit
import CoreModels

/// 录音详情页：总结（M4）/ 文稿（M2）/ 音频（M1）
struct DetailView: View {
    @Environment(\.modelContext) private var modelContext
    let recording: Recording
    @State private var playback = PlaybackController()
    @State private var selectedTab: Tab = .audio
    @State private var whisper = WhisperService.shared
    @State private var summarization = SummarizationService.shared
    @State private var summaryTemplate: SummaryTemplate = SummarizationService.shared.defaultTemplate

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
                summaryTab
            case .transcript:
                transcriptTab
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

    // MARK: 总结 Tab

    @ViewBuilder
    private var summaryTab: some View {
        if let state = summarization.states[recording.id] {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text(state)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("取消") { summarization.cancel(recording.id) }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let summary = recording.summary {
            VStack(spacing: 0) {
                ScrollView {
                    SummaryMarkdownView(markdown: summary.markdown)
                        .padding(20)
                }
                Divider()
                HStack(spacing: 12) {
                    Text("\(templateName(summary.templateKind)) · 本地模型 · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $summaryTemplate) {
                        ForEach(SummaryTemplate.allCases) { tpl in
                            Text(tpl.displayName).tag(tpl)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    Button {
                        summarization.generate(recordingID: recording.id, template: summaryTemplate, context: modelContext)
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        } else if let error = summarization.availabilityError {
            ContentUnavailableView {
                Label("本地 AI 总结不可用", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
        } else if recording.segments.isEmpty {
            ContentUnavailableView {
                Label("AI 总结", systemImage: "sparkles")
            } description: {
                Text("暂无转写内容：先完成实时转写或 Whisper 精转，再生成总结")
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("由本地 Apple Intelligence 模型生成\(summarization.defaultTemplate.displayName)，数据不出设备")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    summarization.generate(recordingID: recording.id, context: modelContext)
                } label: {
                    Label("生成总结", systemImage: "sparkles")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func templateName(_ kind: String) -> String {
        SummaryTemplate(rawValue: kind)?.displayName ?? kind
    }

    private var transcriptTab: some View {
        VStack(spacing: 0) {
            refineControlBar
            Divider()
            if recording.segments.isEmpty {
                ContentUnavailableView {
                    Label("暂无转写文稿", systemImage: "text.quote")
                } description: {
                    Text(recording.status == .recording
                         ? "录音中…实时转写将在结束后显示在这里"
                         : "这场录音未开启实时转写（M3 将支持录音后离线转写）")
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(sortedSegments) { segment in
                            TranscriptBubble(
                                segment: segment,
                                isActive: playback.position >= segment.start && playback.position < segment.end
                            ) {
                                selectedTab = .audio
                                playback.seek(to: segment.start)
                            }
                            .id(segment.id)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: playback.position) { _, newPosition in
                        // 播放时自动滚动到当前片段
                        guard playback.isPlaying,
                              let current = sortedSegments.first(where: {
                                  newPosition >= $0.start && newPosition < $0.end
                              }) else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: 精转控制条

    @ViewBuilder
    private var refineControlBar: some View {
        HStack(spacing: 10) {
            if recording.finalEngineRaw == ASREngine.whisper.rawValue {
                Label("Whisper 终稿", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if recording.liveEngineRaw == ASREngine.appleSpeech.rawValue {
                Label("实时转写稿（可用 Whisper 精转提升准确率）", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let state = whisper.refineStates[recording.id] {
                ProgressView()
                    .controlSize(.small)
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("取消") {
                    whisper.cancelRefine(recording.id)
                }
                .controlSize(.small)
            } else if recording.status != .recording,
                      recording.hasMicTrack || recording.hasSystemTrack {
                Button {
                    whisper.refine(recordingID: recording.id, context: modelContext)
                } label: {
                    Label("用 Whisper 精转", systemImage: "sparkles")
                }
                .controlSize(.small)
                .help("本地模型重新转写，支持中英混说；首次使用需在设置中下载模型")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var sortedSegments: [TranscriptSegment] {
        recording.segments.sorted { $0.start < $1.start }
    }

    private func durationString(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "00:00" }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
