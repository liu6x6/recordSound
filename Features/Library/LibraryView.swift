import SwiftUI
import SwiftData
import AudioKit
import CoreModels

/// 录音库：列表 + 搜索 + 重命名/删除/导出入口
struct LibraryView: View {
    /// 点击录音行 → 由父层路由到详情页
    let onSelect: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.createdAt, order: .reverse) private var recordings: [Recording]
    @State private var searchText = ""
    @State private var renamingRecording: Recording?
    @State private var renameText = ""

    private var filtered: [Recording] {
        guard !searchText.isEmpty else { return recordings }
        return recordings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.segments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("暂无录音", systemImage: "waveform.slash")
                } description: {
                    Text(searchText.isEmpty
                         ? "点击左上角「新录音」开始您的第一场录制"
                         : "没有匹配「\(searchText)」的录音")
                }
            } else {
                List(filtered) { recording in
                    Button {
                        onSelect(recording.id)
                    } label: {
                        RecordingRow(recording: recording)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("重命名…") {
                            renamingRecording = recording
                            renameText = recording.title
                        }
                        Menu("导出") {
                            ForEach(ExportService.ExportKind.allCases) { kind in
                                Button(kind.rawValue) {
                                    Task { await ExportService.export(recording, kind: kind) }
                                }
                            }
                        }
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [RecordingStore.directory(for: recording.id)]
                            )
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            delete(recording)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $searchText, prompt: "搜索标题或转写内容")
        .navigationTitle("录音库")
        .alert("重命名录音", isPresented: Binding(
            get: { renamingRecording != nil },
            set: { if !$0 { renamingRecording = nil } }
        )) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renamingRecording = nil }
            Button("保存") {
                renamingRecording?.title = renameText
                try? modelContext.save()
                renamingRecording = nil
            }
        }
    }

    private func delete(_ recording: Recording) {
        RecordingStore.deleteFiles(for: recording.id)
        modelContext.delete(recording)
        try? modelContext.save()
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(recording.status == .recording ? .red : .accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(durationString(recording.duration))
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

            statusBadge
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.status {
        case .recording:
            Label("录音中", systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .processing:
            Label("处理中", systemImage: "gearshape.2")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .done, .liveDone, .refinedDone:
            Label("完成", systemImage: "checkmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    private func durationString(_ t: TimeInterval) -> String {
        guard t > 0 else { return "--:--" }
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
