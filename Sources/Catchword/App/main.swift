import AppKit

// AppKit 入口（用 SPM 构建，无需 Xcode 工程文件）
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
