import AppKit

/// 「复制即译」：一条不依赖辅助功能权限的取词路径。
///
/// 系统不给授权、或者用户懒得去勾的时候，选中文字按一下 ⌘C 就能出气泡。
/// 实现上只读剪贴板的 `changeCount`（一个整数），变了才去读内容 ——
/// 没有事件监听、没有任何权限要求，空闲开销可以忽略。
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var timer: Timer?
    private var lastChangeCount = 0
    private var lastText = ""
    private var lastFire = Date.distantPast

    private init() {}

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        // 0.4s 读一个整数，不读内容、不建事件监听、不要权限
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in ClipboardWatcher.shared.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastText = ""
    }

    private func poll() {
        guard SettingsStore.shared.settings.clipboardTriggerEnabled else { return }

        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        // 自己面板里点「复制译文」也会改剪贴板，别再弹一次
        if NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier { return }

        guard let raw = pb.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != lastText else { return }
        lastText = text

        guard Self.acceptable(text) else { return }
        // 和划词去重：同一段文字刚弹过就不再弹
        guard Date().timeIntervalSince(lastFire) > 1.2 else { return }
        lastFire = Date()

        SelectionBubble.shared.show(text: text,
                                    appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                                    anchor: NSEvent.mouseLocation)
    }

    /// 只接「像一段被选中的文字」的内容：单行、长度合适、含字母。
    /// 复制文件路径、代码块、纯数字都不会触发。
    private static func acceptable(_ text: String) -> Bool {
        let s = SettingsStore.shared.settings
        guard text.count >= s.minWordLength, text.count <= s.selectionMaxLength else { return false }
        guard !text.contains("\n"), !text.contains("\r") else { return false }
        return text.rangeOfCharacter(from: .letters) != nil
    }
}
