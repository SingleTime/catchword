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

        // 用 canWorkNow 而不是 hasAccessibility：后者在本进程内被缓存，
        // 用户刚授权时仍返回 false，会把 ⌘C 兜底这条路整条跳过。
        if Permissions.canWorkNow {
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

    // MARK: - 划词触发用

    /// 划词场景取词：AX 优先，读不到时用一次 ⌘C 兜底。
    ///
    /// 为什么可以兜底：⌘C 只是复制，**不会取消选区**，拖选刚结束的这一刻复制是安全的；
    /// 剪贴板在复制前后完整备份并恢复，用户感知不到。
    /// 这一步很关键 —— Chrome / VS Code / PDF / 终端里 `kAXSelectedTextAttribute`
    /// 经常返回空，只靠 AX 会让「划词即译」在这些 App 里彻底失效。
    static func captureSelectionWithFallback() async -> Capture? {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? ""
        let bundleID = app?.bundleIdentifier ?? ""

        // 调试开关：强制走 ⌘C，用于验证兜底路径
        if ProcessInfo.processInfo.environment["CATCHWORD_FORCE_COPY"] == "1" {
            Diag.log("强制模式：跳过 AX，直接模拟 ⌘C")
        } else if let text = axSelectedText(app: app), !text.isEmpty {
            Diag.log("取词成功（AX）: \(text.prefix(24))")
            return Capture(text: text, appName: appName, bundleID: bundleID, method: "AX")
        }

        Diag.log("AX 未取到选中文本，回退模拟 ⌘C（app=\(appName)）")
        guard let text = await copySelectedText(), !text.isEmpty else {
            Diag.log("⌘C 兜底也失败")
            return nil
        }
        Diag.log("取词成功（⌘C）: \(text.prefix(24))")
        return Capture(text: text, appName: appName, bundleID: bundleID, method: "⌘C")
    }

    /// 只读 AX、不做任何副作用（热键路径里仍需权限判定时用）
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

        // 1) App 的焦点元素（绝大多数情况）
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused,
           CFGetTypeID(focused) == AXUIElementGetTypeID(),
           let text = selectedText(of: focused as! AXUIElement) {
            return text
        }

        // 2) 系统级焦点元素：少数 App 只有这条路径通
        let systemWide = AXUIElementCreateSystemWide()
        var globalFocused: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &globalFocused) == .success,
           let globalFocused,
           CFGetTypeID(globalFocused) == AXUIElementGetTypeID(),
           let text = selectedText(of: globalFocused as! AXUIElement) {
            return text
        }
        return nil
    }

    /// 单个元素上尝试两条取值路径：AXSelectedText → AXSelectedTextRange + AXStringForRange
    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // 有些 App 只提供选区 range，不提供选中字符串
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range),
              range.length > 0, range.length < 4000
        else { return nil }

        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
                                                         kAXStringForRangeParameterizedAttribute as CFString,
                                                         rangeRef,
                                                         &strRef) == .success,
              let s = strRef as? String
        else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
