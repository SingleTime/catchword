import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var vocabWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        PanelController.shared.setup()
        registerHotKey()
        installObservers()

        // 服务菜单（右键 › 服务 › 用捕词翻译）：零权限，系统还会自动给它分配快捷键
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        prewarmTranslationHost()
        applyTriggerSettings()

        // 首次启动：把「选中即译」的服务快捷键装好（只装一次，之后用户自己改的不会被覆盖）。
        // 这条通道不需要任何系统授权，是产品的主路径；所以不再弹「去授权」的窗口 ——
        // macOS 26 起那张授权表等于交出整台机器，一个翻译工具不该开这个口。
        if !UserDefaults.standard.bool(forKey: "didInstallServiceShortcut") {
            UserDefaults.standard.set(true, forKey: "didInstallServiceShortcut")
            if ServiceShortcut.current == nil { ServiceShortcut.install() }
        }

        // 主动请求辅助功能授权：系统会弹「捕词想要控制这台电脑」并把本 app 登记进列表
        if CommandLine.arguments.contains("--request-access") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // LSUIElement 应用不在前台时系统会压掉这个授权提示，先激活
                NSApp.activate(ignoringOtherApps: true)
                Permissions.requestAccessibility()
            }
        }

        // 端到端自检：写一次剪贴板，看气泡会不会自己冒出来
        if CommandLine.arguments.contains("--clip-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let pb = NSPasteboard.general
                print("[clip] watcher=\(ClipboardWatcher.shared.isRunning) 开关=\(SettingsStore.shared.settings.clipboardTriggerEnabled) 写入前=\(pb.changeCount) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                pb.clearContents()
                pb.setString("serendipity", forType: .string)
                print("[clip] 写入后=\(pb.changeCount)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    print("[clip] 气泡可见=\(SelectionBubble.shared.isVisible) frame=\(SelectionBubble.shared.frame)")
                    NSApp.terminate(nil)
                }
            }
        }

        // 调试用：--demo 直接展示一个示例浮窗
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                PanelController.shared.show(text: "serendipity", appName: "Demo")
            }
        }
        if CommandLine.arguments.contains("--bubble-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SelectionBubble.shared.show(text: "serendipity", appName: "Demo",
                                            anchor: NSEvent.mouseLocation)
            }
        }
        if CommandLine.arguments.contains("--selftest-trigger") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.runTriggerSelfTest()
            }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                self.openSettings()
            }
        }
        if CommandLine.arguments.contains("--vocab") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                self.openVocabulary()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsStore.shared.saveNow()
        HotKeyCenter.shared.uninstall()
        SelectionMonitor.shared.stop()
    }

    /// macOS 15–25 的系统翻译要靠隐藏宿主窗口取 session（macOS 26+ 不需要）。
    /// 提前搭好，第一次查词就少吃一次 ~200ms 的窗口启动开销。
    private func prewarmTranslationHost() {
        guard AppleEngine.needsBridge else { return }
        let settings = SettingsStore.shared.settings
        guard settings.primaryProvider?.kind == .apple else { return }
        let target = settings.targetLanguage == "auto" ? "zh-Hans" : settings.targetLanguage
        // 中文用户九成是英译中，先按这个方向预热；方向不对时 translate 会自己重建宿主
        let guessSource = (target == "zh-Hans" || target == "zh-Hant") ? "en" : "zh-Hans"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard #available(macOS 15.0, *) else { return }
            AppleSessionBridge.shared.prewarm(sourceCode: guessSource, targetCode: target)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 主菜单

    /// LSUIElement 应用默认没有主菜单，缺了它 ⌘C/⌘V/⌘A 等标准编辑命令在无边框浮窗里不生效
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 捕词", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let translateItem = NSMenuItem(title: "取词翻译", action: #selector(menuTranslate), keyEquivalent: "")
        translateItem.target = self
        appMenu.addItem(translateItem)
        let vocabItem = NSMenuItem(title: "词库…", action: #selector(menuVocabulary), keyEquivalent: "l")
        vocabItem.target = self
        appMenu.addItem(vocabItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 捕词", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 捕词", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "text.viewfinder",
                               accessibilityDescription: "捕词")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "捕词 · \(KeyCodeName.display(keyCode: SettingsStore.shared.settings.hotKeyCode, modifiers: SettingsStore.shared.settings.hotKeyModifiers))"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let shortcut = KeyCodeName.display(keyCode: SettingsStore.shared.settings.hotKeyCode,
                                           modifiers: SettingsStore.shared.settings.hotKeyModifiers)
        let translate = NSMenuItem(title: "翻译选中文字", action: #selector(menuTranslate), keyEquivalent: "")
        translate.target = self
        translate.attributedTitle = NSMutableAttributedString(
            string: "翻译选中文字",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        menu.addItem(translate)

        let hint = NSMenuItem(title: "快捷键 \(shortcut)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let vocab = NSMenuItem(title: "词库（\(VocabularyStore.shared.wordCount) 词 · 待复习 \(VocabularyStore.shared.dueCount)）",
                               action: #selector(menuVocabulary), keyEquivalent: "")
        vocab.target = self
        menu.addItem(vocab)

        let settings = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // 主路径放在最上面：选中即译走系统「服务」，零权限
        let svcTitle = ServiceShortcut.current
            .map { "选中即译（\(ServiceShortcut.humanize($0))）" }
            ?? "装上「选中即译」快捷键 ⌃⌘T"
        let svc = NSMenuItem(title: svcTitle, action: #selector(menuServiceShortcut), keyEquivalent: "")
        svc.target = self
        menu.addItem(svc)

        // 用 canWorkNow 而不是 hasAccessibility：后者在进程内被缓存，
        // 用户刚在系统设置里勾上时这里仍会显示未授权。
        let permTitle = Permissions.canWorkNow ? "划词自动气泡：已授权 ✓" : "划词自动气泡：未授权（需系统级总授权）"
        let perm = NSMenuItem(title: permTitle, action: #selector(menuPermission), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        let update = NSMenuItem(title: "打开数据目录", action: #selector(menuOpenDataFolder), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出捕词", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - 快捷键

    func registerHotKey() {
        let s = SettingsStore.shared.settings
        guard s.hotKeyEnabled else {
            HotKeyCenter.shared.uninstall()
            return
        }
        HotKeyCenter.shared.install(keyCode: s.hotKeyCode, modifiers: s.hotKeyModifiers) { [weak self] in
            self?.triggerCapture()
        }
    }

    func reregisterHotKey() {
        registerHotKey()
        statusItem?.button?.toolTip = "捕词 · \(KeyCodeName.display(keyCode: SettingsStore.shared.settings.hotKeyCode, modifiers: SettingsStore.shared.settings.hotKeyModifiers))"
    }

    // MARK: - 划词触发

    /// 重启自己。
    /// macOS 的辅助功能授权是在进程启动时定格的，用户勾选时如果进程已经在跑，
    /// 这个进程就永远读到 false —— 界面上表现成「勾了却还显示未授权」。只能重启。
    func relaunchApp() {
        SettingsStore.shared.saveNow()
        let path = Bundle.main.bundlePath
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "sleep 0.6; /usr/bin/open -n '\(path)'"]
        try? launcher.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    /// 服务菜单入口：任意 App 里选中文字 → 右键 › 服务 › 用捕词翻译。
    /// 选中文本由系统递过来，完全不需要辅助功能权限。
    @objc func translateService(_ pboard: NSPasteboard,
                                userData: String,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        NSApp.activate(ignoringOtherApps: true)
        PanelController.shared.show(text: text, appName: app)
    }

    /// 设置里改「划词即译」后调用，按需装/卸事件监听
    func applyTriggerSettings() {
        // 划词自动气泡要读别的 App 的 AX，没有系统级授权时装了也是白跑 ——
        // 不如不装：省电，也不会让用户以为「开了在等」其实永远不会响。
        if SettingsStore.shared.settings.selectionTriggerEnabled && Permissions.canWorkNow {
            SelectionMonitor.shared.start()
        } else {
            SelectionMonitor.shared.stop()
            SelectionBubble.shared.dismiss()
        }
        // 复制即译不需要任何权限，独立开关
        if SettingsStore.shared.settings.clipboardTriggerEnabled {
            ClipboardWatcher.shared.start()
        } else {
            ClipboardWatcher.shared.stop()
        }
    }

    /// 自检：事件监听是否装上、气泡窗口能不能正常出现/收起
    func runTriggerSelfTest() {
        var lines: [String] = []
        let outPath = CommandLine.arguments.first { $0.hasPrefix("--selftest-out=") }
            .map { String($0.dropFirst("--selftest-out=".count)) }
        // 每写一行就落一次盘：用 open 启动时 stdout 会被丢掉，只能靠文件带回结果。
        func emit(_ s: String) {
            print(s)
            lines.append(s)
            if let outPath {
                try? lines.joined(separator: "\n").appending("\n")
                    .write(toFile: outPath, atomically: true, encoding: .utf8)
            }
        }

        let parent = NSRunningApplication(processIdentifier: getppid())?.localizedName ?? "?"
        emit("[selftest] 进程: pid=\(getpid()) 父进程=\(parent)(pid=\(getppid()))")
        emit("[selftest] 辅助功能: 缓存=\(Permissions.hasAccessibility) 实测=\(Permissions.canWorkNow) 监听=\(SelectionMonitor.shared.isRunning)")
        emit("[selftest] 复制即译: \(ClipboardWatcher.shared.isRunning ? "运行中" : "未启动")")
        emit("[selftest] 设置: 划词=\(SettingsStore.shared.settings.selectionTriggerEnabled) 双击直出=\(SettingsStore.shared.settings.selectionDirectOnDoubleClick) 上限=\(SettingsStore.shared.settings.selectionMaxLength)")

        let anchor = NSEvent.mouseLocation
        SelectionBubble.shared.show(text: "serendipity", appName: "SelfTest", anchor: anchor)
        emit("[selftest] 气泡可见: \(SelectionBubble.shared.isVisible) frame=\(SelectionBubble.shared.frame)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            SelectionBubble.shared.dismiss()
            emit("[selftest] 收起后可见: \(SelectionBubble.shared.isVisible)")
            emit("[selftest] 结束")
            NSApp.terminate(nil)
        }
    }

    // MARK: - 取词

    func triggerCapture() {
        SelectionBubble.shared.dismiss()
        if PanelController.shared.isVisible {
            PanelController.shared.hide()
            return
        }
        Task { @MainActor in
            let hasPermission = Permissions.canWorkNow
            if let cap = await SelectionGrabber.capture(), !cap.text.isEmpty {
                PanelController.shared.show(text: cap.text, appName: cap.appName)
            } else if !hasPermission {
                PanelController.shared.showEmpty(
                    hint: "没读到选中文字 —— 系统没给这个 App 读选区的授权。想一步到位的话：选中文字后按 ⌃⌘T（走系统服务，不需要授权）。这里也可以直接输入。")
            } else {
                PanelController.shared.showEmpty(hint: "没读到选中的文字，直接输入也行。")
            }
        }
    }

    // MARK: - 窗口

    @objc private func menuTranslate() { triggerCapture() }

    @objc private func menuSettings() { openSettings() }

    @objc private func menuVocabulary() { openVocabulary() }

    @objc private func menuPermission() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    /// 没装就装，装了就去改键
    @objc private func menuServiceShortcut() {
        if ServiceShortcut.current == nil {
            ServiceShortcut.install()
        } else {
            Permissions.openKeyboardSettings()
        }
    }

    @objc private func menuOpenDataFolder() {
        NSWorkspace.shared.open(Paths.supportDir)
    }

    @objc private func menuAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "捕词 · 设置"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openVocabulary() {
        if vocabWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "捕词 · 词库"
            w.contentView = NSHostingView(rootView: VocabularyView())
            w.center()
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 780, height: 460)
            vocabWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        vocabWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 授权提示

    // MARK: - 通知

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .lingoRequestSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        })
        observers.append(center.addObserver(forName: .lingoRequestVocabulary, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openVocabulary() }
        })
        // 用户刚在系统设置里勾上辅助功能时，把划词监听补装上。
        // 不能查 Permissions.hasAccessibility：进程内缓存会把「刚授权」误判成没授权。
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTriggerSettings() }
        })
        // 关键：捕词是 LSUIElement，很少自己变成前台。用户是在「系统设置」里勾授权，
        // 勾完切走的那一刻（任意 App 被激活）才是补装监听的最好时机。
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTriggerSettings() }
        })
    }
}
