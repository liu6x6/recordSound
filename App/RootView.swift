import SwiftUI
import SwiftData
import AudioKit
import CoreModels

/// 根视图：侧边栏导航（新录音 / 录音库）+ 详情路由
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var selection: SidebarItem? = .record
    @State private var detailRecordingID: UUID?
    /// onFinished 程序化切换 selection 时，抑制 onChange 清空详情
    @State private var suppressDetailClear = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.done")
    @Query(filter: #Predicate<Recording> { $0.statusRaw == "recording" },
           sort: \Recording.createdAt, order: .reverse)
    private var activeRecordings: [Recording]

    enum SidebarItem: String, CaseIterable, Identifiable {
        case record = "新录音"
        case library = "录音库"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .record: return "record.circle"
            case .library: return "square.stack"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label {
                        HStack {
                            Text(item.rawValue)
                            if item == .record && appState.isRecording {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    } icon: {
                        Image(systemName: item.icon)
                    }
                    .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if let id = detailRecordingID,
               let recording = findRecording(id: id) {
                DetailView(recording: recording)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                detailRecordingID = nil
                                selection = .library
                            } label: {
                                Label("返回录音库", systemImage: "chevron.left")
                            }
                        }
                    }
            } else {
                switch selection {
                case .record:
                    RecordView()
                case .library:
                    LibraryView(onSelect: { id in
                        detailRecordingID = id
                    })
                case .none:
                    RecordView()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .onChange(of: selection) { _, _ in
            // 用户点击侧边栏时退出详情页
            if suppressDetailClear {
                suppressDetailClear = false
            } else {
                detailRecordingID = nil
            }
        }
        .task {
            // 崩溃恢复 + 接线录音完成回调
            appState.recoverInterruptedRecordings(context: modelContext)
            appState.recorder.onFinished = { recording in
                if selection != .library {
                    suppressDetailClear = true
                    selection = .library
                }
                detailRecordingID = recording.id
            }

            // 全局热键：⌥⌘R 开始/停止录音
            let hotKey = HotKeyManager.shared
            hotKey.onHotKey = {
                let vm = appState.recorder
                Task {
                    switch vm.phase {
                    case .idle:
                        await vm.start(context: modelContext)
                    case .recording, .paused:
                        await vm.stop(context: modelContext)
                    }
                }
            }
            hotKey.registerIfNeeded()
        }
    }

    private func findRecording(id: UUID) -> Recording? {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
}
