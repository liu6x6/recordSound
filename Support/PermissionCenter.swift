import AppKit
import AudioKit
import Foundation

/// TCC 权限检测与引导
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    var micGranted = false
    var screenGranted = false

    func refresh() async {
        micGranted = MicCapture.permissionStatus == .authorized
        screenGranted = await SystemAudioCapture.checkPermission()
    }

    func requestMic() async {
        micGranted = await MicCapture.requestPermission()
        await refresh()
    }

    func openScreenCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    var canRecordAnything: Bool { micGranted || screenGranted }
}
