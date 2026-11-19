import Foundation
import Carbon.HIToolbox
import AppKit

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    private let signature: OSType = 0x4C4E474F  // 'LNGO'
    private var isInstalled = false

    private init() {}

    func install(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        uninstall()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            HotKeyCenter.shared.fire()
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isInstalled = (status == noErr)
        if !isInstalled {
            Log.e("全局快捷键注册失败: \(status)")
        }
    }

    func uninstall() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
        isInstalled = false
    }

    fileprivate func fire() {
        action?()
    }
}

// MARK: - 快捷键展示

enum KeyCodeName {
    static let named: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        122: "F1", 120: "F2", 118: "F3", 115: "Home", 116: "PgUp", 117: "⌦", 119: "End", 121: "PgDn"
    ]

    static func name(_ code: UInt32) -> String {
        named[code] ?? "?"
    }

    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += name(keyCode)
        return s
    }
}

// MARK: - 权限

enum Permissions {
    /// 注意：`AXIsProcessTrusted()` 的结果在本进程内会被缓存 ——
    /// 进程启动时没权限，之后用户再去系统设置勾上，这里依然返回 false，直到进程重启。
    /// 判断「现在到底能不能用」请用 `canWorkNow`。
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 实时判定，绕开 `AXIsProcessTrusted()` 的进程内缓存。
    /// 做法是直接问系统一次：给别的 App 建个 AX 客户端读一个属性，
    /// 没权限会立刻返回 `.apiDisabled`。零副作用 ——
    /// 不要改用「试着建一个事件监听」来探测：主进程本来就占着一个 tap，再建第二个会失败，
    /// 会把有权限误判成没权限。
    static var canWorkNow: Bool {
        if AXIsProcessTrusted() { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != me && $0.activationPolicy == .regular
        }) else { return false }
        let ax = AXUIElementCreateApplication(other.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value)
        return err != .apiDisabled
    }

    /// 弹系统授权提示
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
