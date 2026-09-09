import SwiftUI
import AudioKit

/// 设置页（M1 最小版：存储位置 + 隐私说明；M2/M3 增加转写引擎与模型管理）
struct SettingsView: View {
    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 260)
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
            Button("刷新") { Task { await perms.refresh() } }
        }
        .font(.callout)
        .task { await perms.refresh() }
    }
}
