import SwiftUI

/// 首次启动引导：功能介绍 → 权限授予 → 开始使用
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: welcomePage
                case 1: featuresPage
                case 2: permissionsPage
                default: donePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: page)

            // 页码指示器
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 12)

            HStack {
                Button("跳过") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if page < 3 {
                    Button("继续") { page += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("开始使用") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 440)
        .task { await appState.permissions.refresh() }
    }

    private var welcomePage: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(colors: [.indigo, .purple],
                                                 startPoint: .top, endPoint: .bottom))
            Text("欢迎使用 VoiceScribe")
                .font(.largeTitle.bold())
            Text("录制会议与课程，本地 AI 生成纪要")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("核心能力").font(.title2.bold())
            featureRow(icon: "mic.fill", color: .blue, title: "麦克风录音",
                       desc: "录制您说的话")
            featureRow(icon: "speaker.wave.3.fill", color: .purple, title: "系统声音录音",
                       desc: "录制会议对方、视频音频等其他 App 的声音，双轨分开存储")
            featureRow(icon: "captions.bubble.fill", color: .green, title: "实时转写 + Whisper 精转",
                       desc: "录音时同步出字幕；结束后可用本地 Whisper 模型提升准确率，支持中英混说")
            featureRow(icon: "sparkles", color: .orange, title: "AI 会议纪要",
                       desc: "Apple Intelligence 端侧模型自动生成概要、要点、待办")
        }
        .padding(32)
    }

    private func featureRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(desc).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsPage: some View {
        let perms = appState.permissions
        return VStack(alignment: .leading, spacing: 16) {
            Text("授权").font(.title2.bold())
            Text("VoiceScribe 需要以下权限，全部数据仅在本地处理")
                .font(.callout).foregroundStyle(.secondary)

            permissionRow(title: "麦克风", desc: "录制您的声音", granted: perms.micGranted) {
                Task { await perms.requestMic() }
            }
            permissionRow(title: "语音识别", desc: "实时转写（端侧）", granted: perms.speechGranted) {
                Task { await perms.requestSpeech() }
            }
            permissionRow(title: "屏幕录制", desc: "捕获系统声音（macOS 的要求，不录画面）",
                          granted: perms.screenGranted) {
                perms.openScreenCaptureSettings()
            }
            if !perms.screenGranted {
                Text("⚠️ 屏幕录制授权后需要重启 VoiceScribe 才能生效")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(32)
    }

    private func permissionRow(title: String, desc: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("授权", action: action)
            }
        }
    }

    private var donePage: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("一切就绪！").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 8) {
                Text("• 主窗口或菜单栏均可开始录音")
                Text("• 全局热键 ⌥⌘R 快速开始/停止")
                Text("• 设置 → 转写 中可下载 Whisper 模型获得更准终稿")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding.done")
        dismiss()
    }
}
