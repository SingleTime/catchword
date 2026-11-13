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
