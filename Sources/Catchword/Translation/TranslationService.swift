import Foundation

/// 翻译调度：语言方向决策、服务选择、缓存、自动降级、词库落库
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    private var task: Task<Void, Never>?
    private var memCache: [String: (text: String, word: WordInfo?, at: Date)] = [:]
    private let memCacheLimit = 200

    private init() {}

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - 目标语言

    static func modelTargetName(_ code: String) -> String {
        switch code {
        case "zh-Hans", "zh": return "Simplified Chinese"
        case "zh-Hant": return "Traditional Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "ru": return "Russian"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        default: return Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        }
    }

    static func resolveTarget(text: String, settings: AppSettings) -> String {
        if settings.targetLanguage == "auto" {
            return Lang.isChinese(text) ? "en" : "zh-Hans"
        }
        return settings.targetLanguage
    }

    // MARK: - 主流程

    func translate(rawText: String,
                   sourceApp: String,
                   forceProvider: Provider? = nil,
                   emit: @escaping (TranslationEvent) -> Void) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            emit(.failed(.empty))
            return
        }

        task?.cancel()
        let settings = SettingsStore.shared.settings
        let targetCode = Self.resolveTarget(text: text, settings: settings)
        let provider = forceProvider ?? settings.primaryProvider

        guard let provider else {
            emit(.failed(.missingAPIKey(providerName: "未选择翻译服务")))
            return
        }

        let isWord = Lang.looksLikeWord(text)
        // 大模型才需要词典模式开关；系统词典服务本身就是词典
        let wordMode = settings.dictionaryModeForWords
            && isWord
            && !Lang.isChinese(text)
            && provider.kind == .openAI

        let cacheKey = "\(provider.id.uuidString)|\(targetCode)|\(wordMode)|\(text)"

        // 内存缓存
        if let hit = memCache[cacheKey], Date().timeIntervalSince(hit.at) < 3600 {
            if let w = hit.word { emit(.word(w)) }
            emit(.completed(text: hit.text, word: hit.word))
            return
        }

        let apiKey = SettingsStore.shared.apiKey(for: provider)

        task = Task { [weak self] in
            guard let self else { return }

            @MainActor
            func finish(_ out: String, _ word: WordInfo?, _ providerName: String) {
                guard !Task.isCancelled else { return }
                self.storeCache(key: cacheKey, text: out, word: word)
                VocabularyStore.shared.record(term: text,
                                               translation: out,
                                               targetLang: targetCode,
                                               phonetic: word?.phonetic ?? "",
                                               pos: word?.pos ?? "",
                                               example: Self.composeExample(word),
                                               context: "",
                                               sourceApp: sourceApp,
                                               provider: providerName,
                                               fullText: text)
                emit(.completed(text: out, word: word))
            }

            switch provider.kind {
            case .apple:
                await self.runApple(text: text, provider: provider, targetCode: targetCode,
                                    wordMode: wordMode, dictionaryMode: settings.dictionaryModeForWords,
                                    emit: emit, finish: finish)

            case .dictionary:
                await self.runDictionary(text: text, provider: provider, targetCode: targetCode,
                                         wordMode: wordMode, emit: emit, finish: finish)

            case .openAI:
                await self.runLLM(text: text, provider: provider, apiKey: apiKey,
                                  targetCode: targetCode, wordMode: wordMode,
                                  context: "", emit: emit, finish: finish)
            }
        }
    }

    // MARK: - 系统翻译（macOS 26+）

    private func runApple(text: String,
                          provider: Provider,
                          targetCode: String,
                          wordMode: Bool,
                          dictionaryMode: Bool,
                          emit: @escaping (TranslationEvent) -> Void,
                          finish: @escaping (String, WordInfo?, String) -> Void) async {
        guard #available(macOS 26.0, *) else {
            // macOS 12–25 没有可用的系统翻译引擎，直接走兜底
            await fallback(after: .appleUnavailable(AppleEngine.unavailableReason),
                           text: text, targetCode: targetCode, wordMode: wordMode,
                           emit: emit, finish: finish, avoidedProviderID: provider.id)
            return
        }

        do {
            let out = try await AppleTranslator.shared.translate(text, targetCode: targetCode)
            guard !Task.isCancelled else { return }
            emit(.partial(out))

            // 单词顺手补上本机词典的音标/词性，不必再问大模型
            var info: WordInfo?
            if dictionaryMode, Lang.looksLikeWord(text), let entry = LocalDictionary.lookup(text) {
                info = WordInfo(phonetic: entry.phonetic, pos: entry.pos, definition: out)
            }
            finish(out, info, provider.name)
        } catch {
            guard !Task.isCancelled else { return }
            let failure = (error as? TranslationFailure) ?? .appleUnavailable(error.localizedDescription)
            await fallback(after: failure, text: text, targetCode: targetCode, wordMode: wordMode,
                           emit: emit, finish: finish, avoidedProviderID: provider.id)
        }
    }

    // MARK: - 本机离线词典

    private func runDictionary(text: String,
                               provider: Provider,
                               targetCode: String,
                               wordMode: Bool,
                               emit: @escaping (TranslationEvent) -> Void,
                               finish: @escaping (String, WordInfo?, String) -> Void) async {
        guard Lang.looksLikeWord(text) else {
            emit(.failed(.dictionaryWordsOnly))
            return
        }
        guard let entry = LocalDictionary.lookup(text) else {
            // 词典里没有：能借大模型就借
            if let llm = firstAvailableLLM(excluding: provider) {
                let key = SettingsStore.shared.apiKey(for: llm)
                if !key.isEmpty {
                    emit(.notice("本机词典没有「\(text)」，改用「\(llm.name)」"))
                    await runLLM(text: text, provider: llm, apiKey: key,
                                 targetCode: targetCode, wordMode: true,
                                 context: "", emit: emit, finish: finish)
                    return
                }
            }
            emit(.failed(.dictionaryMiss(text)))
            return
        }

        let info = WordInfo(phonetic: entry.phonetic, pos: entry.pos, definition: entry.definition)
        emit(.word(info))
        finish(entry.definition, info, provider.name)
    }

    // MARK: - 降级链

    /// 系统翻译不可用时的兜底：本机词典（单词）→ 大模型 → 报错
    private func fallback(after failure: TranslationFailure,
                          text: String,
                          targetCode: String,
                          wordMode: Bool,
                          emit: @escaping (TranslationEvent) -> Void,
                          finish: @escaping (String, WordInfo?, String) -> Void,
                          avoidedProviderID: UUID?) async {
        if Lang.looksLikeWord(text), let entry = LocalDictionary.lookup(text) {
            emit(.notice("系统翻译不可用，已改用本机离线词典"))
            let info = WordInfo(phonetic: entry.phonetic, pos: entry.pos, definition: entry.definition)
            emit(.word(info))
            finish(entry.definition, info, "本机词典")
            return
        }

        if let fallbackProvider = firstAvailableLLM(excludingID: avoidedProviderID) {
            let key = SettingsStore.shared.apiKey(for: fallbackProvider)
            if !key.isEmpty {
                emit(.notice("系统翻译不可用，已改用「\(fallbackProvider.name)」"))
                await runLLM(text: text, provider: fallbackProvider, apiKey: key,
                             targetCode: targetCode, wordMode: wordMode,
                             context: "", emit: emit, finish: finish)
                return
            }
        }

        emit(.failed(failure))
    }

    // MARK: - 大模型

    private func runLLM(text: String,
                        provider: Provider,
                        apiKey: String,
                        targetCode: String,
                        wordMode: Bool,
                        context: String,
                        emit: @escaping (TranslationEvent) -> Void,
                        finish: @escaping (String, WordInfo?, String) -> Void) async {
        let targetName = Self.modelTargetName(targetCode)
        if wordMode {
            await LLMTranslator.shared.lookupWord(text, context: context, provider: provider,
                                                  apiKey: apiKey, targetName: targetName) { event in
                switch event {
                case .completed(let out, let word):
                    finish(out, word, provider.name)
                default:
                    emit(event)
                }
            }
        } else {
            await LLMTranslator.shared.translateStream(text: text, provider: provider,
                                                        apiKey: apiKey, targetName: targetName) { event in
                switch event {
                case .completed(let out, let word):
                    finish(out, word, provider.name)
                default:
                    emit(event)
                }
            }
        }
    }

    private func firstAvailableLLM(excluding: Provider) -> Provider? {
        firstAvailableLLM(excludingID: excluding.id)
    }

    private func firstAvailableLLM(excludingID: UUID?) -> Provider? {
        SettingsStore.shared.settings.providers.first {
            $0.kind == .openAI && $0.enabled && $0.id != excludingID
                && !(SettingsStore.shared.apiKey(for: $0).isEmpty)
        }
    }

    private static func composeExample(_ word: WordInfo?) -> String {
        guard let word, !word.example.isEmpty else { return "" }
        if word.exampleTranslation.isEmpty { return word.example }
        return "\(word.example)\n\(word.exampleTranslation)"
    }

    // MARK: - 缓存

    private func storeCache(key: String, text: String, word: WordInfo?) {
        if memCache.count > memCacheLimit {
            memCache.removeAll(keepingCapacity: true)
        }
        memCache[key] = (text, word, Date())
    }
}
