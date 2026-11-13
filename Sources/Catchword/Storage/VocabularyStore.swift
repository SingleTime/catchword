import Foundation
import Combine

struct VocabEntry: Identifiable, Hashable {
    var id: Int
    var term: String
    var normalized: String
    var lang: String
    var translation: String
    var phonetic: String
    var pos: String
    var example: String
    var context: String
    var sourceApp: String
    var provider: String
    var lookupCount: Int
    var starred: Bool
    var mastered: Bool
    var reviewCount: Int
    var ease: Double
    var intervalDays: Double
    var dueAt: Date
    var createdAt: Date
    var updatedAt: Date

    var isDue: Bool { dueAt <= Date() }

    /// 熟练度 0~5
    var strength: Int {
        if mastered { return 5 }
        if intervalDays <= 0 { return 0 }
        if intervalDays < 2 { return 1 }
        if intervalDays < 7 { return 2 }
        if intervalDays < 21 { return 3 }
        return 4
    }
}

enum VocabSort: String, CaseIterable, Identifiable {
    case frequency = "高频优先"
    case recent = "最近查询"
    case alphabetical = "字母顺序"
    case due = "待复习"
    var id: String { rawValue }
}

@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published private(set) var entries: [VocabEntry] = []
    @Published var searchText: String = ""
    @Published var sort: VocabSort = .frequency
    @Published var onlyStarred: Bool = false
    @Published private(set) var dueCount: Int = 0
    @Published private(set) var todayLookups: Int = 0
    @Published private(set) var totalLookups: Int = 0

    private let db = Database.shared

    private init() {
        reload()
    }

    // MARK: - 读取

    func reload() {
        var sql = "SELECT * FROM vocabulary"
        var conds: [String] = []
        var params: [SQLValue] = []
        if onlyStarred { conds.append("starred = 1") }
        if !searchText.isEmpty {
            conds.append("(term LIKE ? OR translation LIKE ? OR normalized LIKE ?)")
            let q = "%\(searchText)%"
            params.append(.text(q)); params.append(.text(q)); params.append(.text(q))
        }
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }

        switch sort {
        case .frequency: sql += " ORDER BY lookup_count DESC, updated_at DESC"
        case .recent: sql += " ORDER BY updated_at DESC"
        case .alphabetical: sql += " ORDER BY normalized ASC"
        case .due: sql += " ORDER BY due_at ASC"
        }

        entries = db.fetch(sql, params) { Self.map($0) }

        dueCount = db.scalarInt("SELECT COUNT(*) AS v FROM vocabulary WHERE due_at <= ? AND mastered = 0",
                                [.double(Date().timeIntervalSince1970)])
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        todayLookups = db.scalarInt("SELECT COUNT(*) AS v FROM lookup_log WHERE created_at >= ?", [.double(startOfDay)])
        totalLookups = db.scalarInt("SELECT COUNT(*) AS v FROM lookup_log")
    }

    private static func map(_ r: Row) -> VocabEntry {
        VocabEntry(
            id: r.int("id"),
            term: r.string("term"),
            normalized: r.string("normalized"),
            lang: r.string("lang"),
            translation: r.string("translation"),
            phonetic: r.string("phonetic"),
            pos: r.string("pos"),
            example: r.string("example"),
            context: r.string("context"),
            sourceApp: r.string("source_app"),
            provider: r.string("provider"),
            lookupCount: r.int("lookup_count"),
            starred: r.bool("starred"),
            mastered: r.bool("mastered"),
            reviewCount: r.int("review_count"),
            ease: r.double("ease"),
            intervalDays: r.double("interval_days"),
            dueAt: Date(timeIntervalSince1970: r.double("due_at")),
            createdAt: Date(timeIntervalSince1970: r.double("created_at")),
            updatedAt: Date(timeIntervalSince1970: r.double("updated_at"))
        )
    }

    func entry(for term: String) -> VocabEntry? {
        let n = normalize(term)
        return entries.first { $0.normalized == n }
    }

    func lookupCount(for term: String) -> Int {
        let n = normalize(term)
        if let hit = entries.first(where: { $0.normalized == n }) { return hit.lookupCount }
        return db.scalarInt("SELECT COUNT(*) AS v FROM lookup_log WHERE term = ?", [.text(n)])
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalize(_ s: String) -> String { Self.normalize(s) }

    // MARK: - 写入

    /// 记录一次查询。单词会进入词库并累加频次。
    @discardableResult
    func record(term rawTerm: String,
                translation: String,
                targetLang: String,
                phonetic: String = "",
                pos: String = "",
                example: String = "",
                context: String = "",
                sourceApp: String = "",
                provider: String = "",
                fullText: String = "") -> Int {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        let isWord = Lang.looksLikeWord(term)
        let lang = Lang.isChinese(term) ? "zh" : "en"

        db.insert("""
        INSERT INTO lookup_log (term, full_text, translation, target_lang, provider, source_app, is_word, created_at)
        VALUES (?,?,?,?,?,?,?,?)
        """, [.text(Self.normalize(term)), .text(fullText), .text(translation),
              .text(targetLang), .text(provider), .text(sourceApp),
              .int(isWord ? 1 : 0), .double(now)])

        let settings = SettingsStore.shared.settings
        guard settings.autoCollectWords, isWord, term.count >= settings.minWordLength else {
            refreshCounters()
            return 0
        }

        let normalized = Self.normalize(term)
        let existing = db.fetch("SELECT id, lookup_count FROM vocabulary WHERE normalized = ? AND lang = ?",
                                [.text(normalized), .text(lang)]) { ($0.int("id"), $0.int("lookup_count")) }.first

        if let (id, count) = existing {
            db.execute("""
            UPDATE vocabulary SET lookup_count = ?, translation = ?, updated_at = ?,
                phonetic = CASE WHEN ? = '' THEN phonetic ELSE ? END,
                pos = CASE WHEN ? = '' THEN pos ELSE ? END,
                example = CASE WHEN ? = '' THEN example ELSE ? END,
                context = CASE WHEN ? = '' THEN context ELSE ? END,
                source_app = CASE WHEN ? = '' THEN source_app ELSE ? END
            WHERE id = ?
            """, [.int(count + 1), .text(translation), .double(now),
                  .text(phonetic), .text(phonetic),
                  .text(pos), .text(pos),
                  .text(example), .text(example),
                  .text(context), .text(context),
                  .text(sourceApp), .text(sourceApp),
                  .int(id)])
            refreshCounters()
            return id
        } else {
            let id = db.insert("""
            INSERT INTO vocabulary
            (term, normalized, lang, translation, phonetic, pos, example, context, source_app, provider,
             lookup_count, starred, mastered, review_count, ease, interval_days, due_at, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,1,0,0,0,2.5,0,?,?,?)
            """, [.text(term), .text(normalized), .text(lang), .text(translation),
                  .text(phonetic), .text(pos), .text(example), .text(context),
                  .text(sourceApp), .text(provider),
                  .double(now + 86_400), .double(now), .double(now)])
            refreshCounters()
            return id
        }
    }

    private func refreshCounters() {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        todayLookups = db.scalarInt("SELECT COUNT(*) AS v FROM lookup_log WHERE created_at >= ?", [.double(startOfDay)])
        totalLookups = db.scalarInt("SELECT COUNT(*) AS v FROM lookup_log")
        dueCount = db.scalarInt("SELECT COUNT(*) AS v FROM vocabulary WHERE due_at <= ? AND mastered = 0",
                                [.double(Date().timeIntervalSince1970)])
    }

    func toggleStar(_ entry: VocabEntry) {
        db.execute("UPDATE vocabulary SET starred = ? WHERE id = ?",
                   [.int(entry.starred ? 0 : 1), .int(entry.id)])
        reload()
    }

    func toggleMastered(_ entry: VocabEntry) {
        db.execute("UPDATE vocabulary SET mastered = ? WHERE id = ?",
                   [.int(entry.mastered ? 0 : 1), .int(entry.id)])
        reload()
    }

    func delete(_ entry: VocabEntry) {
        db.execute("DELETE FROM vocabulary WHERE id = ?", [.int(entry.id)])
        reload()
    }

    func updateNote(term: String, translation: String) {
        let n = Self.normalize(term)
        db.execute("UPDATE vocabulary SET translation = ?, updated_at = ? WHERE normalized = ?",
                   [.text(translation), .double(Date().timeIntervalSince1970), .text(n)])
        reload()
    }

    /// 简易 SM-2：quality 0=忘了 1=模糊 2=记得
    func review(_ entry: VocabEntry, quality: Int) {
        var ease = max(1.3, entry.ease)
        var interval = entry.intervalDays
        var lapses = 0

        switch quality {
        case 0:
            ease = max(1.3, ease - 0.25)
            interval = 0
            lapses = 1
        case 1:
            ease = max(1.3, ease - 0.05)
            interval = max(1.0, interval * 1.3)
        default:
            ease = min(3.0, ease + 0.1)
            interval = interval < 1 ? 1 : interval * ease
        }

        let nextInterval = min(interval, 365)
        let due = quality == 0
            ? Date().addingTimeInterval(600)
            : Date().addingTimeInterval(nextInterval * 86_400)

        db.execute("""
        UPDATE vocabulary SET review_count = review_count + 1, ease = ?, interval_days = ?,
            due_at = ?, updated_at = ?, mastered = ?
        WHERE id = ?
        """, [.double(ease), .double(nextInterval), .double(due.timeIntervalSince1970),
              .double(Date().timeIntervalSince1970),
              .int(lapses == 0 && nextInterval >= 21 ? 1 : entry.mastered ? 1 : 0),
              .int(entry.id)])
        reload()
    }

    // MARK: - 统计

    struct DayCount: Identifiable {
        var id: String { date }
        var date: String
        var count: Int
    }

    func last7Days() -> [DayCount] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        var out: [DayCount] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let start = cal.startOfDay(for: day).timeIntervalSince1970
            let end = start + 86_400
            let c = db.scalarInt("SELECT COUNT(*) AS v FROM lookup_log WHERE created_at >= ? AND created_at < ?",
                                 [.double(start), .double(end)])
            out.append(DayCount(date: fmt.string(from: day), count: c))
        }
        return out
    }

    var wordCount: Int { db.scalarInt("SELECT COUNT(*) AS v FROM vocabulary") }

    // MARK: - 导出

    func exportCSV() throws -> URL {
        let rows = db.fetch("SELECT * FROM vocabulary ORDER BY lookup_count DESC") { Self.map($0) }
        var csv = "term,translation,phonetic,pos,count,review,due,context\n"
        for e in rows {
            let fields = [e.term, e.translation, e.phonetic, e.pos, "\(e.lookupCount)",
                          "\(e.reviewCount)", ISO8601DateFormatter().string(from: e.dueAt), e.context]
            csv += fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",") + "\n"
        }
        let url = Paths.exportDir.appendingPathComponent("捕词-词库-\(Self.stamp()).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Anki 可导入的 TSV（正面/背面）
    func exportAnki() throws -> URL {
        let rows = db.fetch("SELECT * FROM vocabulary ORDER BY lookup_count DESC") { Self.map($0) }
        var tsv = ""
        for e in rows {
            let front = e.phonetic.isEmpty ? e.term : "\(e.term)  /\(e.phonetic)/"
            var back = "\(e.pos) \(e.translation)"
            if !e.example.isEmpty { back += "<br><i>\(e.example)</i>" }
            if !e.context.isEmpty { back += "<br><span style='color:#888'>\(e.context)</span>" }
            tsv += "\(front)\t\(back)\n"
        }
        let url = Paths.exportDir.appendingPathComponent("捕词-Anki-\(Self.stamp()).txt")
        try tsv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// 供浮窗展示：这个词查过几次
    func frequencyBadge(for term: String) -> String? {
        let c = lookupCount(for: term)
        guard c > 1 else { return nil }
        return "查过 \(c) 次"
    }
}
