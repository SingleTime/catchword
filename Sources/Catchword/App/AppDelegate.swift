import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var vocabWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        PanelController.shared.setup()
        registerHotKey()
        installObservers()
        prewarmTranslationHost()
        applyTriggerSettings()

        // 首次启动：提示授权
        if !Permissions.hasAccessibility,
           !UserDefaults.standard.bool(forKey: "didPromptAccessibility") {
            UserDefaults.standard.set(true, forKey: "didPromptAccessibility")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.promptAccessibility()
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

        let permTitle = Permissions.hasAccessibility ? "辅助功能权限：已授权 ✓" : "辅助功能权限：未授权（点击授权）"
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

    /// 设置里改「划词即译」后调用，按需装/卸事件监听
    func applyTriggerSettings() {
        if SettingsStore.shared.settings.selectionTriggerEnabled {
            // 权限可能是刚授的，每次回到前台都试一次
            SelectionMonitor.shared.start()
        } else {
            SelectionMonitor.shared.stop()
            SelectionBubble.shared.dismiss()
        }
    }

    /// 自检：事件监听是否装上、气泡窗口能不能正常出现/收起
    func runTriggerSelfTest() {
        print("[selftest] 辅助功能: \(Permissions.hasAccessibility)")
        print("[selftest] 设置: 划词=\(SettingsStore.shared.settings.selectionTriggerEnabled) 双击直出=\(SettingsStore.shared.settings.selectionDirectOnDoubleClick) 上限=\(SettingsStore.shared.settings.selectionMaxLength)")
        print("[selftest] 事件监听: \(SelectionMonitor.shared.isRunning ? "运行中" : "未启动")")

        let anchor = NSEvent.mouseLocation
        SelectionBubble.shared.show(text: "serendipity", appName: "SelfTest", anchor: anchor)
        print("[selftest] 气泡可见: \(SelectionBubble.shared.isVisible) frame=\(SelectionBubble.shared.frame)")
        print("[selftest] 锚点: \(anchor)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            SelectionBubble.shared.dismiss()
            print("[selftest] 收起后可见: \(SelectionBubble.shared.isVisible)")
            print("[selftest] 结束")
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
            let hasPermission = Permissions.hasAccessibility
            if let cap = await SelectionGrabber.capture(), !cap.text.isEmpty {
                PanelController.shared.show(text: cap.text, appName: cap.appName)
            } else if !hasPermission {
                PanelController.shared.showEmpty(
                    hint: "未获「辅助功能」权限，无法自动读取选中文字。可直接输入，或到 设置 › 通用 里授权。")
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

    private func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "捕词需要「辅助功能」权限"
        alert.informativeText = """
        用于读取你在任意 App 中选中的文字（并模拟 ⌘C 作为兜底）。
        文字只在本机处理，不会上传；只有当你选择了云端大模型服务时，才会把待翻译内容发给你自己配置的接口。

        授权路径：系统设置 › 隐私与安全性 › 辅助功能 → 勾选「捕词」。
        """
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }

    // MARK: - 通知

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .lingoRequestSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        })
        observers.append(center.addObserver(forName: .lingoRequestVocabulary, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openVocabulary() }
        })
        // 用户刚在系统设置里勾上辅助功能时，回到前台就把划词监听补装上
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      SettingsStore.shared.settings.selectionTriggerEnabled,
                      !SelectionMonitor.shared.isRunning,
                      Permissions.hasAccessibility else { return }
                self.applyTriggerSettings()
            }
        })
    }
}
