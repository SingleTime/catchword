import Foundation
import Combine
import AppKit

// MARK: - 语言

enum Lang {
    static let zhHans = "zh-Hans"
    static let zhHant = "zh-Hant"
    static let en = "en"

    /// 可选目标语言（"auto" = 中英自动互译）
    static let targets: [(code: String, name: String)] = [
        ("auto", "自动（中 ↔ 英）"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("ru", "Русский"),
        ("it", "Italiano"),
        ("pt", "Português")
    ]

    static func displayName(_ code: String) -> String {
        targets.first { $0.code == code }?.name ?? code
    }

    /// 判断文本是否为中文母语文本
    static func isChinese(_ text: String) -> Bool {
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (0x41...0x7A).contains($0.value) }.count
        if han == 0 { return false }
        return han * 3 >= latin
    }

    /// 是否"像"一个待查的单词（单 token、字母为主）
    static func looksLikeWord(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 1, t.count <= 40 else { return false }
        if t.contains(" ") || t.contains("\n") { return false }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= 1 && Double(letters) >= Double(t.count) * 0.6
    }
}

// MARK: - 服务商

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case apple
    case dictionary
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple 系统翻译"
        case .dictionary: return "系统词典（离线）"
        case .openAI: return "OpenAI 兼容接口"
        }
    }

    var subtitle: String {
        switch self {
        case .apple: return "离线 · 系统原生 · 零延迟"
        case .dictionary: return "离线 · 牛津英汉 · 只需单词"
        case .openAI: return "云端大模型 · 可自定义 Prompt"
        }
    }

    var symbol: String {
        switch self {
        case .apple: return "apple.logo"
        case .dictionary: return "character.book.closed"
        case .openAI: return "sparkles"
        }
    }
}

struct Provider: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: ProviderKind
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini"
    var temperature: Double = 0.2
    var enabled: Bool = true
    /// 自定义系统提示词，留空则使用内置
    var systemPrompt: String = ""

    static func apple() -> Provider {
        Provider(name: "Apple 系统翻译", kind: .apple)
    }

    static func dictionary() -> Provider {
        Provider(name: "系统词典（离线）", kind: .dictionary)
    }

    static func openAI(name: String = "OpenAI",
                       baseURL: String = "https://api.openai.com/v1",
                       model: String = "gpt-4o-mini") -> Provider {
        Provider(name: name, kind: .openAI, baseURL: baseURL, model: model)
    }

    var host: String {
        URL(string: baseURL)?.host ?? baseURL
    }
}

// MARK: - 设置

struct AppSettings: Codable {
    var providers: [Provider] = [
        Provider.apple(),
        Provider.dictionary(),
        Provider.openAI()
    ]
    /// 主翻译服务
    var primaryProviderID: UUID?
    /// 对照服务（可选，为空则不显示第二栏）
    var compareProviderID: UUID?
    /// 目标语言，"auto" 为中英互译
    var targetLanguage: String = "auto"

    // 快捷键（Carbon keyCode + modifier flags）
    var hotKeyCode: UInt32 = 2          // kVK_ANSI_D
    var hotKeyModifiers: UInt32 = 2048  // optionKey
    var hotKeyEnabled: Bool = true
    /// 取词方式：axOnly / clipboard
    var captureMode: String = "auto"

    // 外观
    var fontSize: Double = 14
    var panelWidth: Double = 400
    var autoCopyTranslation: Bool = false
    var speakOnTranslate: Bool = false

    // 词库
    var autoCollectWords: Bool = true
    /// 收录最短长度（字符）
    var minWordLength: Int = 2
    /// 单词查询走词典模式（结构化音标/词性/例句）
    var dictionaryModeForWords: Bool = true
    var showFrequencyInPanel: Bool = true

    // 行为
    var hideOnOutsideClick: Bool = true
    var launchAtLogin: Bool = false

    init() {}

    // 容错解码：新增字段缺失时用默认值
    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        let def = AppSettings()
        providers = (try? d.decode([Provider].self, forKey: .providers)) ?? def.providers
        primaryProviderID = try? d.decodeIfPresent(UUID.self, forKey: .primaryProviderID)
        compareProviderID = try? d.decodeIfPresent(UUID.self, forKey: .compareProviderID)
        targetLanguage = (try? d.decode(String.self, forKey: .targetLanguage)) ?? def.targetLanguage
        hotKeyCode = (try? d.decode(UInt32.self, forKey: .hotKeyCode)) ?? def.hotKeyCode
        hotKeyModifiers = (try? d.decode(UInt32.self, forKey: .hotKeyModifiers)) ?? def.hotKeyModifiers
        hotKeyEnabled = (try? d.decode(Bool.self, forKey: .hotKeyEnabled)) ?? def.hotKeyEnabled
        captureMode = (try? d.decode(String.self, forKey: .captureMode)) ?? def.captureMode
        fontSize = (try? d.decode(Double.self, forKey: .fontSize)) ?? def.fontSize
        panelWidth = (try? d.decode(Double.self, forKey: .panelWidth)) ?? def.panelWidth
        autoCopyTranslation = (try? d.decode(Bool.self, forKey: .autoCopyTranslation)) ?? def.autoCopyTranslation
        speakOnTranslate = (try? d.decode(Bool.self, forKey: .speakOnTranslate)) ?? def.speakOnTranslate
        autoCollectWords = (try? d.decode(Bool.self, forKey: .autoCollectWords)) ?? def.autoCollectWords
        minWordLength = (try? d.decode(Int.self, forKey: .minWordLength)) ?? def.minWordLength
        dictionaryModeForWords = (try? d.decode(Bool.self, forKey: .dictionaryModeForWords)) ?? def.dictionaryModeForWords
        showFrequencyInPanel = (try? d.decode(Bool.self, forKey: .showFrequencyInPanel)) ?? def.showFrequencyInPanel
        hideOnOutsideClick = (try? d.decode(Bool.self, forKey: .hideOnOutsideClick)) ?? def.hideOnOutsideClick
        launchAtLogin = (try? d.decode(Bool.self, forKey: .launchAtLogin)) ?? def.launchAtLogin
    }

    var primaryProvider: Provider? {
        if let id = primaryProviderID, let p = providers.first(where: { $0.id == id }) { return p }
        return providers.first(where: { $0.enabled })
    }

    var compareProvider: Provider? {
        guard let id = compareProviderID else { return nil }
        return providers.first(where: { $0.id == id && $0.enabled })
    }
}

// MARK: - 设置存储

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    private init() {
        var isFresh = false
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
            isFresh = true
        }
        // 老配置文件里没有本机词典这一项，升级时补上（macOS 12–14 靠它离线查词）
        if !settings.providers.contains(where: { $0.kind == .dictionary }) {
            settings.providers.append(Provider.dictionary())
        }

        let primaryExists = settings.primaryProviderID.map { id in
            settings.providers.contains { $0.id == id }
        } ?? false

        if isFresh, !AppleEngine.isAvailable,
           let offline = settings.providers.first(where: { $0.kind == .dictionary && $0.enabled }) {
            // 新装且系统没有翻译引擎：默认落到本机词典，免得每次都走一遍降级
            settings.primaryProviderID = offline.id
        } else if !primaryExists {
            settings.primaryProviderID = settings.providers.first(where: { $0.enabled })?.id
                ?? settings.providers.first?.id
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        try? FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
        }
    }

    // 便捷访问
    var primaryProvider: Provider? { settings.primaryProvider }
    var compareProvider: Provider? { settings.compareProvider }

    func updateProvider(_ p: Provider) {
        if let i = settings.providers.firstIndex(where: { $0.id == p.id }) {
            settings.providers[i] = p
        }
    }

    func addProvider(_ p: Provider) {
        settings.providers.append(p)
    }

    func removeProvider(_ id: UUID) {
        settings.providers.removeAll { $0.id == id }
        if settings.primaryProviderID == id { settings.primaryProviderID = settings.providers.first?.id }
        if settings.compareProviderID == id { settings.compareProviderID = nil }
        Keychain.delete("provider.\(id.uuidString)")
    }

    func apiKey(for p: Provider) -> String {
        Keychain.get("provider.\(p.id.uuidString)") ?? ""
    }

    func setAPIKey(_ key: String, for p: Provider) {
        if key.isEmpty { Keychain.delete("provider.\(p.id.uuidString)") }
        else { Keychain.set(key, for: "provider.\(p.id.uuidString)") }
    }
}
