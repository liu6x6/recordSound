import SwiftUI

@main
struct VoiceScribeApp: App {
    var body: some Scene {
        WindowGroup("VoiceScribe Spike") {
            SpikeView()
        }
        .windowResizability(.contentSize)
    }
}
