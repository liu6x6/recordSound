import SwiftUI
import AppKit
import SwiftData
import CoreModels

/// 菜单栏控制面板：录音状态 + 快捷控制
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let vm = appState.recorder

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(vm.phase == .recording ? .red : (vm.phase == .paused ? .orange : .gray))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                Spacer()
                if vm.phase != .idle {
                    Text(timeString(vm.elapsed))
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            switch vm.phase {
            case .idle:
                Button("开始录音（麦克风+系统声音）") {
                    Task { await vm.start(context: modelContext) }
                }
                .disabled(!appState.permissions.canRecordAnything)
            case .recording:
                Button("暂停") { Task { await vm.pause() } }
                Button("结束录音") { Task { await vm.stop(context: modelContext) } }
                    .keyboardShortcut(".")
            case .paused:
                Button("继续") { Task { await vm.resume() } }
                Button("结束录音") { Task { await vm.stop(context: modelContext) } }
            }

            Divider()

            Button("打开主窗口") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("退出 VoiceScribe") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(10)
        .frame(width: 280)
        .task { await appState.permissions.refresh() }
    }

    private var statusText: String {
        switch appState.recorder.phase {
        case .idle: return "未在录音"
        case .recording: return "录音中"
        case .paused: return "已暂停"
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
