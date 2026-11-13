import AppKit
import SwiftUI

// MARK: - 浮窗

final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 控制器

@MainActor
final class PanelController {
    static let shared = PanelController()

    let model = PanelModel()
    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<PanelView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var contentHeight: CGFloat = 180

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func setup() {
        guard panel == nil else { return }

        let p = FloatingPanel()
        let view = PanelView(model: model) { [weak self] height in
            self?.applyContentHeight(height)
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 180)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        panel = p
        hostingView = host

        NotificationCenter.default.addObserver(forName: .lingoTogglePin, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.togglePin()
            }
        }
    }

    // MARK: 显示

    func show(text: String, appName: String, near point: NSPoint? = nil) {
        setup()
        guard let panel else { return }

        model.isPinned = false
        model.reset()
        model.show(text: text, appName: appName)

        present(near: point)
    }

    func showEmpty(near point: NSPoint? = nil, hint: String? = nil) {
        setup()
        guard let panel else { return }

        model.reset()
        model.isPinned = false
        model.noticeText = hint
        model.sourceLabel = "自动检测"
        let target = SettingsStore.shared.settings.targetLanguage
        model.targetLabel = (target == "auto") ? "自动（中 ↔ 英）" : Lang.displayName(target)
        model.providerName = SettingsStore.shared.settings.primaryProvider?.name ?? ""
        model.sourceAppName = ""

        present(near: point)
    }

    private func present(near point: NSPoint?) {
        guard let panel else { return }
        positionPanel(near: point, height: max(contentHeight, 90))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        model.focusToken += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installOutsideMonitors()
    }

    func hide() {
        model.stopSpeaking()
        panel?.orderOut(nil)
        removeMonitors()
    }

    func toggle(text: String, appName: String) {
        if isVisible {
            hide()
        } else {
            show(text: text, appName: appName)
        }
    }

    func togglePin() {
        model.isPinned.toggle()
    }

    // MARK: 尺寸与定位

    private func applyContentHeight(_ height: CGFloat) {
        guard height > 10 else { return }
        contentHeight = height
        guard let panel, panel.isVisible else { return }
        var frame = panel.frame
        if abs(frame.height - height) < 0.5 { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
        hostingView?.frame = NSRect(x: 0, y: 0, width: frame.width, height: height)
    }

    private func positionPanel(near point: NSPoint?, height: CGFloat) {
        guard let panel else { return }
        let mouse = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = CGFloat(SettingsStore.shared.settings.panelWidth)
        let gap: CGFloat = 18

        var x = mouse.x - width + 60
        var y = mouse.y - height - gap

        if y < visible.minY + 8 {
            y = mouse.y + gap          // 下方不够，翻到光标上方
        }
        if y + height > visible.maxY - 8 {
            y = max(visible.minY + 8, visible.maxY - height - 8)
        }
        if x + width > visible.maxX - 8 { x = visible.maxX - width - 8 }
        if x < visible.minX + 8 { x = visible.minX + 8 }

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        hostingView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    // MARK: 外部点击隐藏

    private func installOutsideMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.isPinned else { return }
                self.hide()
            }
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}
