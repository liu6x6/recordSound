import SwiftUI
import SwiftData
import AudioKit
import CoreModels

/// 录音主页：权限引导 + 音源选择 + 电平 + 控制按钮
struct RecordView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let vm = appState.recorder
        let perms = appState.permissions

        VStack(alignment: .leading, spacing: 16) {
            permissionBanners(perms: perms)

            GroupBox("音源") {
                VStack(alignment: .leading, spacing: 10) {
                    sourceRow(
                        title: "麦克风",
                        subtitle: "录制您说的话",
                        icon: "mic.fill",
                        isOn: Binding(get: { vm.captureMic }, set: { vm.captureMic = $0 }),
                        level: vm.micLevel,
                        enabled: perms.micGranted && vm.phase == .idle
                    )
                    sourceRow(
                        title: "系统声音",
                        subtitle: "录制其他 App 的声音（对方说话、视频音频等）",
                        icon: "speaker.wave.3.fill",
                        isOn: Binding(get: { vm.captureSystem }, set: { vm.captureSystem = $0 }),
                        level: vm.systemLevel,
                        enabled: perms.screenGranted && vm.phase == .idle
                    )
                }
                .padding(6)
            }

            Spacer()

            // 控制区
            VStack(spacing: 8) {
                Text(timeString(vm.elapsed))
                    .font(.system(size: 44, weight: .light, design: .monospaced))
                    .foregroundStyle(vm.phase == .recording ? .primary : .secondary)
                    .contentTransition(.numericText())

                HStack(spacing: 20) {
                    switch vm.phase {
                    case .idle:
                        Button {
                            Task { await vm.start(context: modelContext) }
                        } label: {
                            Label("开始录音", systemImage: "record.circle")
                                .font(.headline)
                                .frame(minWidth: 140)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!perms.canRecordAnything)
                        .keyboardShortcut("r", modifiers: [.command])

                    case .recording:
                        Button {
                            Task { await vm.pause() }
                        } label: {
                            Label("暂停", systemImage: "pause.circle.fill")
                                .frame(minWidth: 100)
                        }
                        .controlSize(.large)

                        Button {
                            Task { await vm.stop(context: modelContext) }
                        } label: {
                            Label("结束录音", systemImage: "stop.circle.fill")
                                .font(.headline)
                                .frame(minWidth: 140)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(".", modifiers: [.command])

                    case .paused:
                        Button {
                            Task { await vm.resume() }
                        } label: {
                            Label("继续", systemImage: "play.circle.fill")
                                .frame(minWidth: 100)
                        }
                        .controlSize(.large)

                        Button {
                            Task { await vm.stop(context: modelContext) }
                        } label: {
                            Label("结束录音", systemImage: "stop.circle.fill")
                                .font(.headline)
                                .frame(minWidth: 140)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(".", modifiers: [.command])
                    }
                }

                if let msg = vm.statusMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if vm.phase == .recording {
                    Text("提示：结束后在「录音库」中查看和回放")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(20)
        .task { await perms.refresh() }
    }

    // MARK: - 子视图

    @ViewBuilder
    private func permissionBanners(perms: PermissionCenter) -> some View {
        if !perms.micGranted {
            PermissionBanner(
                icon: "mic.badge.xmark",
                text: "麦克风权限未授权，无法录制您的声音",
                actionTitle: "请求授权"
            ) {
                Task { await perms.requestMic() }
            }
        }
        if !perms.screenGranted {
            PermissionBanner(
                icon: "display.badge.xmark",
                text: "屏幕录制权限未授权，无法捕获系统声音。授权后需重启 VoiceScribe",
                actionTitle: "打开系统设置"
            ) {
                perms.openScreenCaptureSettings()
            }
        }
    }

    private func sourceRow(title: String, subtitle: String, icon: String,
                           isOn: Binding<Bool>, level: Float, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: icon)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)
            LevelBar(level: level)
                .frame(width: 140)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d.%d", m, s, Int((t - floor(t)) * 10))
    }
}

struct PermissionBanner: View {
    let icon: String
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
            Spacer()
            Button(actionTitle, action: action)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.8 ? .red : .green)
                    .frame(width: max(2, geo.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 8)
    }
}
