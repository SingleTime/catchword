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

    // MARK: - 划词触发用（只读 AX）

    /// 划词场景下不能用「模拟 ⌘C」兜底：那会把用户刚选好的选区搞没。
    /// 拿不到就返回 nil，让调用方安静地什么都不做。
    static func captureSelection() -> Capture? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let text = axSelectedText(app: app) else { return nil }
        return Capture(text: text,
                       appName: app?.localizedName ?? "",
                       bundleID: app?.bundleIdentifier ?? "",
                       method: "AX")
    }

    /// 选区左下角（Cocoa 屏幕坐标），拿不到返回 nil。
    /// Chromium 系（Chrome / VS Code / Electron）经常不给 bounds，调用方要自己兜底到鼠标位置。
    static func selectionAnchor() -> NSPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        let rangeValue = rangeRef as! AXValue
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.length > 0 else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
                                                         kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue,
                                                         &boundsRef) == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }

        // AX 坐标以主屏左上角为原点，换成 Cocoa 的左下角原点
        let height = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return NSPoint(x: rect.minX, y: height - rect.maxY)
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
