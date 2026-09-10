import AppKit
import Carbon.HIToolbox

/// 全局热键（Carbon API，无需辅助功能权限）
/// 默认 ⌥⌘R：开始/停止录音
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// 热键触发回调（主线程）
    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registered = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkey.enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "hotkey.enabled")
            newValue ? register() : unregister()
        }
    }

    func registerIfNeeded() {
        if isEnabled { register() }
    }

    private func register() {
        guard !registered else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // 安装事件处理器（一次性）
        if eventHandler == nil {
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else { return noErr }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            manager.onHotKey?()
                        }
                    }
                    return noErr
                },
                1, &eventType, selfPtr, &eventHandler
            )
        }

        // ⌥⌘R
        var hotKeyID = EventHotKeyID(signature: OSType(0x5653484B) /* 'VSHK' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        registered = (status == noErr)
    }

    private func unregister() {
        guard registered, let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        registered = false
    }
}
