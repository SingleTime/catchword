import AppKit
import ApplicationServices

/// 划词监听：listen-only 的 CGEventTap。
///
/// 只做一件事——判断"用户刚选了一段文字"，然后交给 SelectionBubble 弹个小圆点。
/// tap 回调在鼠标抬起 / Shift+方向键 时才被唤醒，空闲不产生任何定时器或轮询。
///
/// 权限：和读取选中文字一样，只需要「辅助功能」。
@MainActor
final class SelectionMonitor {
    static let shared = SelectionMonitor()

    enum Intent {
        /// 拖选松手 → 弹小气泡，点开才展开面板
        case bubble
        /// 双击选词 → 直接展开面板
        case direct
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: DispatchWorkItem?

    private var isDragging = false
    private var lastText = ""
    private var lastFireAt = Date.distantPast

    private init() {}

    var isRunning: Bool { tap != nil }

    // MARK: - 启停

    func restart() {
        stop()
        start()
    }

    func start() {
        guard SettingsStore.shared.settings.selectionTriggerEnabled, tap == nil else { return }
        // 这里刻意不检查 Permissions.hasAccessibility：AXIsProcessTrusted 在本进程内有缓存，
        // 用户「刚勾上授权但还没重启」时它会一直报 false，把本来能用的功能挡住。
        // 直接试着建监听即可 —— 建得出来就是有权限，建不出来才是真没权限。
        // 优先连键盘事件一起监听（覆盖 Shift+方向键选区）；
        // 有些环境只允许鼠标事件，失败就退化成纯鼠标监听。
        if attach(mask: mouseMask | keyMask) { return }
        if attach(mask: mouseMask) {
            Log.w("划词监听已启动（仅鼠标事件）")
            return
        }
        Log.e("划词监听创建失败：CGEvent.tapCreate 返回 nil（多半是缺辅助功能权限）")
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
    }

    private var mouseMask: CGEventMask {
        CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
    }

    private var keyMask: CGEventMask {
        CGEventMask(1 << CGEventType.keyDown.rawValue)
    }

    private func attach(mask: CGEventMask) -> Bool {
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .listenOnly,
                                              eventsOfInterest: mask,
                                              callback: catchwordSelectionTap,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        tap = created
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.w("划词监听被系统暂停，已重新启用")
    }

    // MARK: - 事件处理

    fileprivate func handle(type: CGEventType, clickCount: Int64, location: CGPoint, flags: CGEventFlags) {
        let settings = SettingsStore.shared.settings
        let point = cocoaPoint(location)

        switch type {
        case .leftMouseDown:
            isDragging = false
            // 点气泡本身时要放过去，否则还没抬起就被关掉了
            if SelectionBubble.shared.isVisible, SelectionBubble.shared.frame.contains(point) { return }
            SelectionBubble.shared.dismiss()
            pending?.cancel()
            pending = nil

        case .leftMouseDragged:
            isDragging = true

        case .leftMouseUp:
            let wasDrag = isDragging
            isDragging = false
            guard settings.selectionTriggerEnabled, shouldListen(at: point) else { return }
            if clickCount >= 2, settings.selectionDirectOnDoubleClick {
                schedule(delay: 0.06, intent: .direct)
            } else if wasDrag {
                schedule(delay: 0.18, intent: .bubble)
            }

        case .keyDown:
            guard flags.contains(.maskShift), settings.selectionTriggerEnabled, shouldListen(at: point) else { return }
            schedule(delay: 0.32, intent: .bubble)

        default:
            break
        }
    }

    /// 只做最便宜的判断：浮窗盖住的区域不算划词
    private func shouldListen(at point: NSPoint) -> Bool {
        if PanelController.shared.isVisible, PanelController.shared.frame.contains(point) { return false }
        return true
    }

    private func schedule(delay: TimeInterval, intent: Intent) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.evaluate(intent: intent) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate(intent: Intent) {
        let settings = SettingsStore.shared.settings
        guard settings.selectionTriggerEnabled else { return }

        // 自己在前台（比如在设置窗口里选字）不算
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }

        guard let cap = SelectionGrabber.captureSelection() else {
            if intent == .bubble { SelectionBubble.shared.dismiss() }
            return
        }
        let text = cap.text
        // 单行、长度可控，才认为用户是在"查词/查句"，而不是在编辑大段代码
        guard !text.contains("\n"),
              text.count >= settings.minWordLength,
              text.count <= settings.selectionMaxLength
        else {
            if intent == .bubble { SelectionBubble.shared.dismiss() }
            return
        }
        // 同一段文字短时间内不重复弹（拖选时会连发多次）
        if text == lastText, Date().timeIntervalSince(lastFireAt) < 1.2 { return }
        lastText = text
        lastFireAt = Date()

        let anchor = SelectionGrabber.selectionAnchor() ?? cocoaPoint(CGEvent(source: nil)?.location ?? .zero)

        switch intent {
        case .direct:
            SelectionBubble.shared.dismiss()
            PanelController.shared.show(text: text, appName: cap.appName, near: anchor)
        case .bubble:
            if PanelController.shared.isVisible { return }
            SelectionBubble.shared.show(text: text, appName: cap.appName, anchor: anchor)
        }
    }

    // MARK: - 坐标

    /// CGEvent 的 location 以主屏左上角为原点，转成 Cocoa 的左下角原点
    private func cocoaPoint(_ point: CGPoint) -> NSPoint {
        let height = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return NSPoint(x: point.x, y: height - point.y)
    }
}

// MARK: - C 回调

private let catchwordSelectionTap: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }

    let clickCount = event.getIntegerValueField(.mouseEventClickState)
    let location = event.location
    let flags = event.flags
    MainActor.assumeIsolated {
        monitor.handle(type: type, clickCount: clickCount, location: location, flags: flags)
    }
    return Unmanaged.passUnretained(event)
}
