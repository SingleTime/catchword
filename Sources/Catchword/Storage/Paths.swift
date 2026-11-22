import Foundation

enum Paths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Catchword", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var dbFile: URL { supportDir.appendingPathComponent("catchword.sqlite") }
    static var settingsFile: URL { supportDir.appendingPathComponent("settings.json") }
    static var exportDir: URL {
        let dir = supportDir.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Log {
    static func w(_ items: Any...) {
        #if DEBUG
        print("[Catchword]", items.map { "\($0)" }.joined(separator: " "))
        #endif
    }

    static func e(_ items: Any...) {
        print("[Catchword][error]", items.map { "\($0)" }.joined(separator: " "))
    }
}

/// 现场诊断：只在数据目录里存在 `diag.on` 文件（或带 --diag 启动）时才写盘。
/// 用于定位「划词没反应」这类只在真实交互下才复现的问题 —— release 包里 print 是看不见的。
enum Diag {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--diag")
            || FileManager.default.fileExists(atPath: Paths.supportDir.appendingPathComponent("diag.on").path)
    }

    static var fileURL: URL { Paths.supportDir.appendingPathComponent("diag.log") }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[\(fmt.string(from: Date()))] \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
