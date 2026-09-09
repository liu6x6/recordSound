import SwiftUI

struct SpikeView: View {
    @State private var vm = SpikeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VoiceScribe — Spike 0")
                .font(.title.bold())
            Text("验证：① 麦克风采集 ② 系统声音采集（ScreenCaptureKit）③ 双轨写盘与回放")
                .foregroundStyle(.secondary)
                .font(.callout)

            Divider()

            // MARK: 权限
            GroupBox("权限状态") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("麦克风", systemImage: vm.micGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(vm.micGranted ? .green : .red)
                        Spacer()
                        if !vm.micGranted {
                            Button("请求授权") { Task { await vm.requestMicPermission() } }
                        }
                    }
                    HStack {
                        Label("屏幕录制（系统声音捕获需要）",
                              systemImage: vm.screenGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(vm.screenGranted ? .green : .red)
                        Spacer()
                        if !vm.screenGranted {
                            Button("打开系统设置") { vm.openScreenCaptureSettings() }
                        }
                    }
                    Button("刷新权限状态") { Task { await vm.checkPermissions() } }
                }
                .padding(4)
            }

            // MARK: 音源
            GroupBox("音源") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("麦克风", isOn: $vm.captureMic)
                            .disabled(!vm.micGranted || vm.phase == .recording)
                        LevelBar(level: vm.micLevel)
                    }
                    HStack {
                        Toggle("系统声音（其他 App）", isOn: $vm.captureSystem)
                            .disabled(!vm.screenGranted || vm.phase == .recording)
                        LevelBar(level: vm.systemLevel)
                    }
                }
                .padding(4)
            }

            // MARK: 控制
            HStack(spacing: 16) {
                if vm.phase == .recording {
                    Button(role: .destructive) {
                        Task { await vm.stopRecording() }
                    } label: {
                        Label("停止录音", systemImage: "stop.circle.fill")
                            .font(.headline)
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        Task { await vm.startRecording() }
                    } label: {
                        Label("开始录音", systemImage: "record.circle")
                            .font(.headline)
                    }
                    .controlSize(.large)
                    .disabled(!vm.micGranted && !vm.screenGranted)
                }

                Text(timeString(vm.elapsed))
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(vm.phase == .recording ? .red : .secondary)
            }

            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // MARK: 录音结果
            if !vm.recordedFiles.isEmpty {
                GroupBox("本次录音文件") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.recordedFiles, id: \.self) { url in
                            HStack {
                                Image(systemName: url.lastPathComponent == "mic.caf" ? "mic.fill" : "speaker.wave.3.fill")
                                Text(url.lastPathComponent)
                                Button(vm.playingFile == url ? "停止播放" : "播放") {
                                    vm.togglePlayback(url)
                                }
                                Button("Finder") { vm.revealInFinder(url) }
                                Spacer()
                            }
                        }
                    }
                    .padding(4)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .task { await vm.checkPermissions() }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60, ms = Int((t - floor(t)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
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
            }
        }
        .frame(height: 8)
    }
}
