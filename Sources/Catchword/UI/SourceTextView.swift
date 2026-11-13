import SwiftUI
import AppKit

/// macOS 12 上可用的多行输入框。
/// SwiftUI 的 `TextField(axis: .vertical)`（13+）与 `.onKeyPress`（14+）在 12 上都不存在，
/// 这里直接用 NSTextView：自动长高、Enter 提交、Shift+Enter 换行、Esc 关闭。
struct SourceTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var focusToken: Int
    var maxHeight: CGFloat
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0

        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.allowsUndo = true
        tv.string = text

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self

        if tv.string != text {
            tv.string = text
            context.coordinator.moveCursorToEnd()
        }
        if tv.font?.pointSize != fontSize {
            tv.font = .systemFont(ofSize: fontSize)
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
        context.coordinator.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextView
        var textView: NSTextView?
        var lastFocusToken = -1
        private var lastHeight: CGFloat = 0

        init(_ parent: SourceTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }

        func moveCursorToEnd() {
            guard let tv = textView else { return }
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }

        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let oneLine = (tv.font?.pointSize ?? 14) * 1.5
            let height = ceil(min(max(used, oneLine), parent.maxHeight))
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            DispatchQueue.main.async { [weak self] in
                self?.parent.onHeightChange(height)
            }
        }
    }
}
