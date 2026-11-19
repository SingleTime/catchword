import AppKit

/// 划词后出现在选区右下角的小圆点。
///
/// 只做一个动作：点它、或者鼠标停 0.4 秒，就展开完整翻译面板。
/// 设计上刻意不直接弹面板——在 IDE 里拖选一个变量名就蹦出一整窗，谁都受不了。
@MainActor
final class SelectionBubble {
    static let shared = SelectionBubble()

    private var panel: NSPanel?
    private var button: BubbleButton?
    private var text = ""
    private var appName = ""
    private var anchor: NSPoint = .zero
    private var autoHide: DispatchWorkItem?

    private let diameter: CGFloat = 28

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: NSRect { panel?.frame ?? .zero }

    // MARK: - 显示 / 收起

    func show(text: String, appName: String, anchor: NSPoint) {
        self.text = text
        self.appName = appName
        self.anchor = anchor

        buildIfNeeded()
        guard let panel, let button else { return }

        var origin = NSPoint(x: anchor.x + 2, y: anchor.y - diameter - 8)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if origin.y < visible.minY + 6 { origin.y = anchor.y + 8 }        // 下方放不下就翻到上面
        if origin.y < visible.minY + 6 { origin.y = visible.minY + 6 }   // 翻转后仍越界（比如光标贴在屏幕最底）就夹住
        if origin.x + diameter > visible.maxX - 6 { origin.x = visible.maxX - diameter - 6 }
        if origin.x < visible.minX + 6 { origin.x = visible.minX + 6 }
        if origin.y + diameter > visible.maxY - 6 { origin.y = visible.maxY - diameter - 6 }

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: diameter, height: diameter)), display: true)
        button.needsDisplay = true

        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        if !wasVisible {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
        scheduleAutoHide()
    }

    func dismiss() {
        autoHide?.cancel()
        autoHide = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func scheduleAutoHide() {
        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func expand() {
        guard !text.isEmpty else { return }
        let t = text
        let a = appName
        let at = anchor
        dismiss()
        PanelController.shared.show(text: t, appName: a, near: at)
    }

    // MARK: - 面板

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none

        let b = BubbleButton(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        b.autoresizingMask = [.width, .height]
        b.onClick = { [weak self] in self?.expand() }
        b.onHover = { [weak self] in self?.expand() }
        p.contentView = b

        panel = p
        button = b
    }
}

// MARK: - 圆点

private final class BubbleButton: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    private var tracking: NSTrackingArea?
    private var hoverTask: DispatchWorkItem?
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        hoverTask?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onHover?() }
        hoverTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        hoverTask?.cancel()
        hoverTask = nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(ovalIn: rect)

        if hovered {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        }
        circle.fill()

        (hovered ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let title = "译"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: hovered ? NSColor.white : NSColor.labelColor
        ]
        let size = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                   withAttributes: attrs)
    }
}
