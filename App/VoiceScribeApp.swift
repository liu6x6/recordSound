import SwiftUI
import SwiftData
import CoreModels

@main
struct VoiceScribeApp: App {
    @State private var appState: AppState
    private let modelContainer: ModelContainer

    init() {
        let state = AppState()
        modelContainer = state.makeModelContainer()
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        WindowGroup("VoiceScribe", id: "main") {
            RootView()
                .environment(appState)
                .modelContainer(modelContainer)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .modelContainer(modelContainer)
        } label: {
            Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform.circle")
                .symbolEffect(.variableColor.iterative, isActive: appState.isRecording)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(modelContainer)
        }
    }
}
