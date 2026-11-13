import Foundation
import NaturalLanguage

// MARK: - 结构化词条

struct WordInfo: Codable, Hashable {
    var phonetic: String = ""
    var pos: String = ""
    var definition: String = ""
    var example: String = ""
    var exampleTranslation: String = ""
    var synonyms: [String] = []

    var isEmpty: Bool {
        phonetic.isEmpty && definition.isEmpty && example.isEmpty
    }

    init() {}

    init(phonetic: String = "", pos: String = "", definition: String = "",
         example: String = "", exampleTranslation: String = "", synonyms: [String] = []) {
        self.phonetic = phonetic
        self.pos = pos
        self.definition = definition
        self.example = example
        self.exampleTranslation = exampleTranslation
        self.synonyms = synonyms
    }

    private enum CodingKeys: String, CodingKey {
        case phonetic, pos, definition, example, exampleTranslation, synonyms
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phonetic = (try? c.decodeIfPresent(String.self, forKey: .phonetic)) ?? ""
        pos = (try? c.decodeIfPresent(String.self, forKey: .pos)) ?? ""
        definition = (try? c.decodeIfPresent(String.self, forKey: .definition)) ?? ""
        example = (try? c.decodeIfPresent(String.self, forKey: .example)) ?? ""
        exampleTranslation = (try? c.decodeIfPresent(String.self, forKey: .exampleTranslation)) ?? ""
        synonyms = (try? c.decodeIfPresent([String].self, forKey: .synonyms)) ?? []
    }
}

// MARK: - 事件

enum TranslationEvent {
    /// 流式增量（整体文本快照）
    case partial(String)
    /// 非致命提示（如自动降级到备用服务）
    case notice(String)
    /// 结构化词条到达
    case word(WordInfo)
    /// 完成
    case completed(text: String, word: WordInfo?)
    /// 失败
    case failed(TranslationFailure)
}

enum TranslationFailure: LocalizedError, Equatable {
    case appleLanguagePackMissing(sourceName: String, targetName: String)
    case appleUnsupportedPair(sourceName: String, targetName: String)
    case appleUnavailable(String)
    case missingAPIKey(providerName: String)
    case badURL(String)
    case http(Int, String)
    case network(String)
    case dictionaryWordsOnly
    case dictionaryMiss(String)
    case empty
    case cancelled

    var errorDescription: String? {
        switch self {
        case .appleLanguagePackMissing(let s, let t):
            return "系统缺少「\(s) → \(t)」离线语言包。打开 系统设置 › 通用 › 语言与地区 › 翻译语言 下载后重试。"
        case .appleUnsupportedPair(let s, let t):
            return "Apple 翻译暂不支持 \(s) → \(t)，换一个大模型服务试试。"
        case .appleUnavailable(let msg):
            return "Apple 翻译不可用：\(msg)"
        case .missingAPIKey(let name):
            return "「\(name)」还没有填 API Key，去设置里补上。"
        case .badURL(let s):
            return "接口地址不合法：\(s)"
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "请求失败 HTTP \(code)\(trimmed.isEmpty ? "" : "：\(trimmed.prefix(180))")"
        case .network(let msg):
            return "网络错误：\(msg)"
        case .dictionaryWordsOnly:
            return "本机词典只能查单个词。整句请换用大模型服务，或在设置里指定默认服务。"
        case .dictionaryMiss(let term):
            return "本机词典里没有「\(term)」。可以换一个大模型服务，或在「词典.app」里添加更多词库。"
        case .empty:
            return "翻译结果为空，换个服务或重试。"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - 语言工具

enum LangDetect {
    /// 用 NaturalLanguage 做粗检测，失败则用字符统计兜底
    static func detect(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(200)))
        if let lang = recognizer.dominantLanguage {
            let raw = lang.rawValue
            if raw.hasPrefix("zh") { return "zh" }
            if raw == "und" { return Lang.isChinese(text) ? "zh" : "en" }
            return raw
        }
        return Lang.isChinese(text) ? "zh" : "en"
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "zh": return "中文"
        case "en": return "英文"
        case "ja": return "日文"
        case "ko": return "韩文"
        case "fr": return "法文"
        case "de": return "德文"
        case "es": return "西班牙文"
        case "ru": return "俄文"
        default:
            return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? code
        }
    }
}
