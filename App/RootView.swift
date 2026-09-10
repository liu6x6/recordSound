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
            } else {
                switch selection {
                case .record:
                    RecordView()
                case .library:
                    LibraryView()
                case .none:
                    RecordView()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .navigationDestination(for: UUID.self) { id in
            if let recording = findRecording(id: id) {
                DetailView(recording: recording)
            }
        }
        .task {
            // 崩溃恢复 + 接线录音完成回调
            appState.recoverInterruptedRecordings(context: modelContext)
            appState.recorder.onFinished = { recording in
                selection = nil
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
