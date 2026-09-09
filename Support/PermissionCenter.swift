import AppKit
import AudioKit
import TranscriptionKit
import Foundation

/// TCC 权限检测与引导
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    var micGranted = false
    var screenGranted = false
    var speechGranted = false

    func refresh() async {
        micGranted = MicCapture.permissionStatus == .authorized
        screenGranted = await SystemAudioCapture.checkPermission()
        speechGranted = SpeechLiveProvider.authStatus == .authorized
    }

    func requestMic() async {
        micGranted = await MicCapture.requestPermission()
        await refresh()
    }

    func requestSpeech() async {
        speechGranted = await SpeechLiveProvider.requestAuthorization()
    }

    func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    var canRecordAnything: Bool { micGranted || screenGranted }
}
