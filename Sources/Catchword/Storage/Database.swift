import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case text(String)
    case int(Int)
    case double(Double)
    case null
}

struct Row {
    let stmt: OpaquePointer
    let columns: [String: Int32]

    func string(_ name: String) -> String {
        guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return "" }
        return String(cString: sqlite3_column_text(stmt, i))
    }

    func stringOrNil(_ name: String) -> String? {
        guard let i = columns[name], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, i))
    }

    func int(_ name: String) -> Int {
        guard let i = columns[name] else { return 0 }
        return Int(sqlite3_column_int64(stmt, i))
    }

    func double(_ name: String) -> Double {
        guard let i = columns[name] else { return 0 }
        return sqlite3_column_double(stmt, i)
    }

    func bool(_ name: String) -> Bool { int(name) != 0 }
}

final class Database {
    static let shared = Database()

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.fw.lingo.db")

    private init() {
        open()
        migrate()
    }

    private func open() {
        let path = Paths.dbFile.path
        if sqlite3_open(path, &handle) != SQLITE_OK {
            Log.e("数据库打开失败: \(String(cString: sqlite3_errmsg(handle)))")
            return
        }
        sqlite3_busy_timeout(handle, 3000)
        execRaw("PRAGMA journal_mode=WAL;")
        execRaw("PRAGMA synchronous=NORMAL;")
        execRaw("PRAGMA foreign_keys=ON;")
    }

    private func execRaw(_ sql: String) {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            Log.e("SQL 失败: \(String(cString: sqlite3_errmsg(handle))) : \(sql)")
        }
    }

    private func migrate() {
        execRaw("""
        CREATE TABLE IF NOT EXISTS vocabulary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL,
            normalized TEXT NOT NULL,
            lang TEXT NOT NULL DEFAULT '',
            translation TEXT NOT NULL DEFAULT '',
            phonetic TEXT NOT NULL DEFAULT '',
            pos TEXT NOT NULL DEFAULT '',
            example TEXT NOT NULL DEFAULT '',
            context TEXT NOT NULL DEFAULT '',
            source_app TEXT NOT NULL DEFAULT '',
            provider TEXT NOT NULL DEFAULT '',
            lookup_count INTEGER NOT NULL DEFAULT 1,
            starred INTEGER NOT NULL DEFAULT 0,
            mastered INTEGER NOT NULL DEFAULT 0,
            review_count INTEGER NOT NULL DEFAULT 0,
            ease REAL NOT NULL DEFAULT 2.5,
            interval_days REAL NOT NULL DEFAULT 0,
            due_at REAL NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        execRaw("CREATE UNIQUE INDEX IF NOT EXISTS idx_vocab_norm ON vocabulary(normalized, lang);")
        execRaw("CREATE INDEX IF NOT EXISTS idx_vocab_count ON vocabulary(lookup_count DESC);")
        execRaw("CREATE INDEX IF NOT EXISTS idx_vocab_due ON vocabulary(due_at);")

        execRaw("""
        CREATE TABLE IF NOT EXISTS lookup_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL,
            full_text TEXT NOT NULL DEFAULT '',
            translation TEXT NOT NULL DEFAULT '',
            target_lang TEXT NOT NULL DEFAULT '',
            provider TEXT NOT NULL DEFAULT '',
            source_app TEXT NOT NULL DEFAULT '',
            is_word INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        """)
        execRaw("CREATE INDEX IF NOT EXISTS idx_log_time ON lookup_log(created_at DESC);")
        execRaw("CREATE INDEX IF NOT EXISTS idx_log_term ON lookup_log(term);")

        execRaw("""
        CREATE TABLE IF NOT EXISTS cache (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
    }

    // MARK: - 基础执行

    func execute(_ sql: String, _ params: [SQLValue] = []) {
        queue.sync { _execute(sql, params) }
    }

    @discardableResult
    private func _execute(_ sql: String, _ params: [SQLValue]) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.e("prepare 失败: \(String(cString: sqlite3_errmsg(handle))) : \(sql)")
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            Log.e("step 失败(\(rc)): \(String(cString: sqlite3_errmsg(handle))) : \(sql)")
        }
        return Int(sqlite3_last_insert_rowid(handle))
    }

    func query(_ sql: String, _ params: [SQLValue] = []) -> [Row] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.e("prepare 失败: \(String(cString: sqlite3_errmsg(handle)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, params)

            var cols: [String: Int32] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                if let name = sqlite3_column_name(stmt, i) {
                    cols[String(cString: name)] = i
                }
            }

            var rows: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                // 必须立即复制出值，故用快照行
                rows.append(Row(stmt: stmt!, columns: cols))
            }
            return rows
        }
    }

    /// 一次性读取（在 step 循环内部完成映射，避免 stmt 失效）
    func fetch<T>(_ sql: String, _ params: [SQLValue] = [], map: (Row) -> T) -> [T] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.e("prepare 失败: \(String(cString: sqlite3_errmsg(handle)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, params)

            var cols: [String: Int32] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                if let name = sqlite3_column_name(stmt, i) {
                    cols[String(cString: name)] = i
                }
            }
            var out: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(map(Row(stmt: stmt!, columns: cols)))
            }
            return out
        }
    }

    func scalarInt(_ sql: String, _ params: [SQLValue] = []) -> Int {
        fetch(sql, params) { $0.int("v") }.first ?? 0
    }

    @discardableResult
    func insert(_ sql: String, _ params: [SQLValue] = []) -> Int {
        queue.sync { _execute(sql, params) }
    }

    func transaction(_ body: () -> Void) {
        queue.sync {
            _execute("BEGIN", [])
            body()
            _execute("COMMIT", [])
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ params: [SQLValue]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, Int64(n))
            case .double(let d):
                sqlite3_bind_double(stmt, idx, d)
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }
}
