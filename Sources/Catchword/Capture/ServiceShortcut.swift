import Foundation

/// 系统「服务」菜单的快捷键（默认 ⌃⌘T）。
///
/// 为什么走这条路：`NSServices` 是系统把**当前选区**直接递给 App 的官方通道，
/// 全程不需要辅助功能 / 全盘访问 / 屏幕录制那套授权。
/// macOS 26 起 Apple 把这些打包成一张「System & App Protection Override」总授权表
/// （读全部数据 + 全部照片 + 浏览历史 + 键击监控），对翻译工具代价太大，所以不申请。
///
/// 快捷键存在 `~/Library/Preferences/pbs.plist` 的 `NSServicesStatus` 里，
/// 键名格式：`"<bundle id> - <菜单项标题> - <NSMessage>"`。
/// key_equivalent 的写法：`@`=⌘ `^`=⌃ `~`=⌥ `$`=⇧，末尾是字母。
enum ServiceShortcut {

    static let menuTitle = "用捕词翻译"
    static let message = "translateService"
    static let defaultEquivalent = "@^t"

    static var prefKey: String {
        let id = Bundle.main.bundleIdentifier ?? "com.fw.catchword"
        return "\(id) - \(menuTitle) - \(message)"
    }

    // MARK: - 读

    /// 已配置的 key equivalent（如 "@^t"）；没配置返回 nil。
    static var current: String? {
        guard let domains = exportPBS(),
              let status = (domains["NSServicesStatus"] as? [String: Any]),
              let entry = status[prefKey] as? [String: Any],
              let eq = entry["key_equivalent"] as? String,
              !eq.isEmpty
        else { return nil }
        return eq
    }

    /// 给界面看的写法："@^t" → "⌃⌘T"（修饰键按 ⌃⌥⇧⌘ 的惯例顺序重排）
    static func humanize(_ equivalent: String) -> String {
        var hasCommand = false, hasControl = false, hasOption = false, hasShift = false
        var letters = ""
        for ch in equivalent {
            switch ch {
            case "@": hasCommand = true
            case "^": hasControl = true
            case "~": hasOption = true
            case "$": hasShift = true
            case "#": letters.append("⌫")
            default:  letters.append(ch)
            }
        }
        var out = ""
        if hasControl { out += "⌃" }
        if hasOption  { out += "⌥" }
        if hasShift   { out += "⇧" }
        if hasCommand { out += "⌘" }
        return out + letters.uppercased()
    }

    // MARK: - 写

    /// 装上快捷键（幂等）。只在用户明确点按钮时调用 —— 别在启动时偷偷改人家的配置。
    @discardableResult
    static func install(_ equivalent: String = defaultEquivalent) -> Bool {
        let dict = """
        <dict>\
        <key>presentation_modes</key><dict>\
        <key>ContextMenu</key><true/><key>ServicesMenu</key><true/>\
        </dict>\
        <key>enabled_context_menu</key><true/>\
        <key>enabled_services_menu</key><true/>\
        <key>key_equivalent</key><string>\(equivalent)</string>\
        </dict>
        """
        let ok = run("/usr/bin/defaults",
                     ["write", "pbs", "NSServicesStatus", "-dict-add", prefKey, dict])
        // pbs 是「服务菜单」的守门人，改完配置要让它重新读一次，快捷键才会真的挂上。
        if ok { run("/usr/bin/killall", ["pbs"]) }
        return ok && current != nil
    }

    // MARK: - 底层

    private static func exportPBS() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["export", "pbs", "-"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
