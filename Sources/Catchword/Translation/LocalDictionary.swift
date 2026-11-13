import Foundation
import CoreServices

/// 词条（来自本机离线词典）
struct DictionaryEntry {
    var term: String
    var phonetic: String
    var pos: String
    var definition: String
}

/// 本机离线词典。
/// 用 DictionaryServices 的 `DCSCopyTextDefinition` 查询用户在「词典.app」里装的词库，
/// 新系统上通常自带《牛津英汉汉英词典》，所以中英互查也能离线完成。
/// 这个 API 从 10.5 就有，macOS 12 上照样可用 —— 老系统没有系统翻译引擎时的兜底。
enum LocalDictionary {

    static func lookup(_ term: String) -> DictionaryEntry? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let range = CFRange(location: 0, length: trimmed.utf16.count)
        guard let copied = DCSCopyTextDefinition(nil, trimmed as CFString, range) else { return nil }
        guard let raw = copied.takeRetainedValue() as String? else { return nil }

        let entry = parse(raw, fallbackTerm: trimmed)
        guard usable(entry, for: trimmed) else { return nil }
        return entry
    }

    /// 过滤掉词头对不上、或者中文查出来只是「现代汉语词典」的汉语释义（对翻译没用）
    private static func usable(_ entry: DictionaryEntry, for term: String) -> Bool {
        let head = entry.term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let want = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return false }
        // 模糊匹配会把 "library" 匹配到 "App Library" 这类词条，直接丢掉
        guard head == want || head.hasPrefix(want) else { return false }

        // 查中文词时，只有释义里真的出现英文单词才算翻译；否则就是汉语词典的解释
        if Lang.isChinese(term) {
            return containsLatinWord(entry.definition)
        }
        return true
    }

    private static func containsLatinWord(_ text: String) -> Bool {
        var run = 0
        for ch in text.unicodeScalars {
            if (0x41...0x5A).contains(ch.value) || (0x61...0x7A).contains(ch.value) {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// 词典返回的格式大致是 `词头 | 音标 | 词性 释义`，也见过没有分隔符的纯文本
    static func parse(_ raw: String, fallbackTerm: String) -> DictionaryEntry {
        let cleaned = raw
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var term = fallbackTerm
        var phonetic = ""
        var body = cleaned

        if parts.count >= 3 {
            term = parts[0].isEmpty ? fallbackTerm : parts[0]
            phonetic = shortPhonetic(parts[1])
            body = parts[2...].joined(separator: " | ")
        } else if parts.count == 2 {
            term = parts[0].isEmpty ? fallbackTerm : parts[0]
            body = parts[1]
        } else {
            // 没有分隔符时，首行通常就是词头（例如 "App Library"）
            let firstLine = cleaned.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? cleaned
            let head = firstLine.trimmingCharacters(in: .whitespaces)
            if !head.isEmpty, head.count <= 40 { term = head }
        }

        let pos = body.contains("\n") ? "" : leadingPartOfSpeech(body)
        // 词性已经从释义里提出来了，别再在正文里重复一遍
        if !pos.isEmpty, body.hasPrefix(pos) {
            body = String(body.dropFirst(pos.count)).trimmingCharacters(in: .whitespaces)
        }

        return DictionaryEntry(term: term,
                               phonetic: phonetic,
                               pos: pos,
                               definition: tidy(body))
    }

    /// "BrE ˌsɛr(ə)nˈdɪpɪti, AmE ˌsɛrənˈdɪpədi" → "ˌsɛr(ə)nˈdɪpɪti"
    private static func shortPhonetic(_ s: String) -> String {
        var out = s
        for prefix in ["BrE ", "AmE ", "BrE", "AmE"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count))
            break
        }
        if let comma = out.firstIndex(of: ",") {
            out = String(out[..<comma])
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 取释义开头连续的词性标记（noun / verb / adj. …），遇到义项序号 ① 就停
    private static func leadingPartOfSpeech(_ body: String) -> String {
        var words: [String] = []
        for token in body.split(separator: " ", maxSplits: 3) {
            let t = String(token)
            if t.isEmpty || t.contains("①") || t.contains("②") || t.contains("▸") { break }
            let letters = t.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0 == "." }
            guard letters else { break }
            words.append(t)
            if words.count >= 3 { break }
        }
        return words.joined(separator: " ")
    }

    /// 把词典的排版符号改成适合浮窗展示的换行
    private static func tidy(_ body: String) -> String {
        var s = body
        s = s.replacingOccurrences(of: " ▸", with: "\n▸ ")
        s = s.replacingOccurrences(of: "▸", with: "\n▸ ").replacingOccurrences(of: "\n▸ \n", with: "\n▸ ")
        s = s.replacingOccurrences(of: " ①", with: "\n① ")
        s = s.replacingOccurrences(of: " ②", with: "\n② ")
        s = s.replacingOccurrences(of: " ③", with: "\n③ ")
        s = s.replacingOccurrences(of: " ④", with: "\n④ ")
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
