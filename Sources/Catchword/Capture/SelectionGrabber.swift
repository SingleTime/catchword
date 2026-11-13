import Foundation
import AppKit
import ApplicationServices

/// 取词：优先读 AXSelectedText，失败则模拟 ⌘C 并完整备份/恢复剪贴板
enum SelectionGrabber {

    struct Capture {
        var text: String
        var appName: String
        var bundleID: String
        var method: String
    }

    // MARK: - 主入口

    static func capture() async -> Capture? {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier ?? ""

        if Permissions.hasAccessibility {
            if let text = axSelectedText(app: app), !text.isEmpty {
                return Capture(text: text, appName: appName, bundleID: bundleID, method: "AX")
            }
            if let text = await copySelectedText(), !text.isEmpty {
                return Capture(text: text, appName: appName, bundleID: bundleID, method: "⌘C")
            }
            return nil
        }

        // 无辅助功能权限时，仍尝试 AX（某些环境可用）
        if let text = axSelectedText(app: app), !text.isEmpty {
            return Capture(text: text, appName: appName, bundleID: bundleID, method: "AX")
        }
        return nil
    }

    // MARK: - AX 读取

    private static func axSelectedText(app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - 模拟 ⌘C

    static func copySelectedText(timeout: TimeInterval = 0.45) async -> String? {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)
        let before = pb.changeCount

        postCommandC()

        var captured: String?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before {
                captured = pb.string(forType: .string)
                break
            }
        }

        // 稍等目标 App 写完剪贴板再恢复，避免恢复后又被覆盖
        try? await Task.sleep(nanoseconds: 40_000_000)
        restorePasteboard(pb, backup)

        guard let text = captured?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 0x08  // kVK_ANSI_C
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(12_000)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 剪贴板备份/恢复

    private struct PBItem {
        var types: [NSPasteboard.PasteboardType: Data]
    }

    private static func backupPasteboard(_ pb: NSPasteboard) -> [PBItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            return PBItem(types: map)
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, _ backup: [PBItem]) {
        guard !backup.isEmpty else { return }
        pb.clearContents()
        let items: [NSPasteboardItem] = backup.map { record in
            let item = NSPasteboardItem()
            for (type, data) in record.types {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    // MARK: - 手动输入的定位基准

    static func mouseLocation() -> NSPoint {
        NSEvent.mouseLocation
    }
}
