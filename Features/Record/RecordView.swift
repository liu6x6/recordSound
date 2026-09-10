import SwiftUI
import AppKit
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
                        enabled: (perms.screenGranted || vm.systemSourceMode == .apps) && vm.phase == .idle
                    )
                    if vm.captureSystem {
                        systemModeSection(vm: vm, perms: perms)
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { vm.liveTranscriptionEnabled },
                        set: { vm.liveTranscriptionEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("实时转写（端侧语音识别）", systemImage: "captions.bubble")
                                .font(.body.weight(.medium))
                            Text("录音时同步生成文字，数据不出设备")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!perms.speechGranted || vm.phase != .idle)
                }
                .padding(6)
            }

            Spacer()

            // 实时字幕
            if vm.phase != .idle && vm.liveTranscriptionEnabled {
                liveCaptionBox(vm: vm)
            }

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
        if !perms.speechGranted {
            PermissionBanner(
                icon: "captions.bubble.badge.xmark",
                text: "语音识别权限未授权，实时转写不可用",
                actionTitle: "请求授权"
            ) {
                Task { await perms.requestSpeech() }
            }
        }
    }

    @ViewBuilder
    private func liveCaptionBox(vm: RecordViewModel) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if vm.captureSystem || !vm.systemCaption.isEmpty {
                    captionLine(label: "对方", color: .purple,
                                partial: vm.systemCaption,
                                lastCommitted: vm.pendingSegments.last(where: { $0.channel == .system })?.text)
                }
                if vm.captureMic || !vm.micCaption.isEmpty {
                    captionLine(label: "我", color: .blue,
                                partial: vm.micCaption,
                                lastCommitted: vm.pendingSegments.last(where: { $0.channel == .mic })?.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: vm.micCaption)
            .animation(.default, value: vm.systemCaption)
        } label: {
            Label("实时转写", systemImage: "captions.bubble.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func captionLine(label: String, color: Color, partial: String, lastCommitted: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let lastCommitted {
                    Text(lastCommitted)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if !partial.isEmpty {
                    Text(partial)
                        .font(.callout)
                        .lineLimit(2)
                } else if lastCommitted == nil {
                    Text("等待语音…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
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

    @ViewBuilder
    private func systemModeSection(vm: RecordViewModel, perms: PermissionCenter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("捕获范围", selection: Binding(
                get: { vm.systemSourceMode },
                set: { vm.systemSourceMode = $0 }
            )) {
                Text("全部系统声音").tag(RecordViewModel.SystemSourceMode.global)
                Text("指定 App（实验）").tag(RecordViewModel.SystemSourceMode.apps)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(vm.phase != .idle)

            if vm.systemSourceMode == .apps {
                appPickerList(vm: vm)
            }

            if let err = vm.processTapError {
                Text("⚠️ \(err)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 28)
    }

    @ViewBuilder
    private func appPickerList(vm: RecordViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("选择要录制的 App（按当前音频活动排序）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    vm.refreshAvailableApps()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(vm.phase != .idle)
            }
            if vm.availableApps.isEmpty {
                Text("未扫描到有音频活动的 App，点击刷新重试")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.availableApps) { app in
                            appRow(app: app, vm: vm)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .task { vm.refreshAvailableApps() }
    }

    @ViewBuilder
    private func appRow(app: AudioProcessInfo, vm: RecordViewModel) -> some View {
        let info = appInfo(for: app.bundleID)
        Toggle(isOn: Binding(
            get: { vm.selectedApps.contains(app.objectID) },
            set: { isOn in
                if isOn { vm.selectedApps.insert(app.objectID) }
                else { vm.selectedApps.remove(app.objectID) }
            }
        )) {
            HStack(spacing: 8) {
                if let icon = info?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(info?.name ?? app.bundleID)
                    .font(.callout)
                if app.isRunningOutput {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("正在播放声音")
                }
                Text(app.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(vm.phase != .idle)
    }

    private struct ResolvedApp {
        let name: String
        let icon: NSImage?
    }

    private func appInfo(for bundleID: String) -> ResolvedApp? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard running != nil || url != nil else { return nil }
        return ResolvedApp(
            name: running?.localizedName ?? bundleID,
            icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        )
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
