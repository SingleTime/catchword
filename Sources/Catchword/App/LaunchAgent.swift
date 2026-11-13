import Foundation
import ServiceManagement

/// 开机自启。
/// SMAppService 是 macOS 13 的新接口；macOS 12 退回用户级 LaunchAgent plist。
enum LaunchAgent {
    private static let label = "com.fw.catchword.login"

    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.e("开机自启设置失败: \(error.localizedDescription)")
            }
            return
        }

        if enabled { writePlist() } else { removePlist() }
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - macOS 12

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 只写 plist，下次登录由 launchd 拉起；不主动 load，避免已经运行时又开一个副本
    private static func writePlist() {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            let dir = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            Log.w("已写入 LaunchAgent: \(plistURL.path)")
        } catch {
            Log.e("写入 LaunchAgent 失败: \(error.localizedDescription)")
        }
    }

    private static func removePlist() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
