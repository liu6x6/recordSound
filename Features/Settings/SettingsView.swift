import SwiftUI
import AudioKit
import SummarizationKit
import TranscriptionKit

/// 设置页（M1 最小版：存储位置 + 隐私说明；M2/M3 增加转写引擎与模型管理）
struct SettingsView: View {
    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            transcriptionTab
                .tabItem { Label("转写", systemImage: "captions.bubble") }
            summarySettingsTab
                .tabItem { Label("总结", systemImage: "sparkles") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
        .padding()
    }

    private var generalTab: some View {
        Form {
            LabeledContent("录音存储位置") {
                HStack {
                    Text(RecordingStore.rootDirectory.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("打开") {
                        NSWorkspace.shared.open(RecordingStore.rootDirectory)
                    }
                }
            }
            LabeledContent("权限状态") {
                PermissionStatusRow()
            }
            Toggle("全局热键 ⌥⌘R（开始/停止录音）", isOn: Binding(
                get: { HotKeyManager.shared.isEnabled },
                set: { HotKeyManager.shared.isEnabled = $0 }
            ))
        }
        .formStyle(.grouped)
    }

    // MARK: 转写设置

    @State private var whisper = WhisperService.shared

    private var transcriptionTab: some View {
        Form {
            Section("实时转写（录音中字幕，Apple Speech 端侧）") {
                Picker("识别语言", selection: Binding(
                    get: { whisper.liveASRLocale },
                    set: { whisper.liveASRLocale = $0 }
                )) {
                    Text("中文").tag("zh-CN")
                    Text("English").tag("en-US")
                }
                Text("实时字幕为单语言识别；中英混说建议录音后用 Whisper 精转（语言选“自动”）获得终稿。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Whisper 精转（终稿，支持中英混说）") {
                Picker("默认模型", selection: Binding(
                    get: { whisper.defaultModel },
                    set: { whisper.defaultModel = $0 }
                )) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Picker("精转语言", selection: Binding(
                    get: { whisper.refineLanguage },
                    set: { whisper.refineLanguage = $0 }
                )) {
                    Text("自动检测（推荐，中英混说）").tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Toggle("录音结束后自动精转", isOn: Binding(
                    get: { whisper.autoRefine },
                    set: { whisper.autoRefine = $0 }
                ))
            }

            Section("模型管理") {
                ForEach(WhisperModel.allCases) { model in
                    modelRow(model)
                }
                Text("模型首次下载需要网络（HuggingFace），之后完全离线使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let downloaded = whisper.isModelDownloaded(model)
        let downloadState = whisper.modelDownloads[model.rawValue]
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("约 \(model.approximateSizeMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let state = downloadState {
                ProgressView()
                    .controlSize(.small)
                Text(state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if downloaded {
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button(role: .destructive) {
                    whisper.deleteModel(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除模型文件")
            } else {
                Button("下载") { whisper.downloadModel(model) }
            }
        }
    }

    // MARK: 总结设置

    @State private var summarization = SummarizationService.shared

    private var summarySettingsTab: some View {
        Form {
            Section("本地 AI 总结（Apple Intelligence）") {
                HStack {
                    Text("端侧模型状态")
                    Spacer()
                    if let error = summarization.availabilityError {
                        Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(error.localizedDescription)
                    } else {
                        Label("可用", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Picker("默认模板", selection: Binding(
                    get: { summarization.defaultTemplate },
                    set: { summarization.defaultTemplate = $0 }
                )) {
                    ForEach(SummaryTemplate.allCases) { tpl in
                        Text(tpl.displayName).tag(tpl)
                    }
                }
                Toggle("转写完成后自动生成总结", isOn: Binding(
                    get: { summarization.autoSummarize },
                    set: { summarization.autoSummarize = $0 }
                ))
                Text("总结全部由设备端 Apple Intelligence 模型生成，不联网、不上传。长录音会先分段提取要点再汇总。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("VoiceScribe").font(.title2.bold())
            Text("版本 0.1.0（Spike / M1）")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("🔒 隐私承诺：所有录音、转写与总结均在您的设备本地处理与存储，App 无网络请求。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PermissionStatusRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let perms = appState.permissions
        HStack(spacing: 12) {
            Label("麦克风", systemImage: perms.micGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(perms.micGranted ? .green : .red)
            Label("屏幕录制", systemImage: perms.screenGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(perms.screenGranted ? .green : .red)
            Label("语音识别", systemImage: perms.speechGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(perms.speechGranted ? .green : .red)
            Button("刷新") { Task { await perms.refresh() } }
        }
        .font(.callout)
        .task { await perms.refresh() }
    }
}
