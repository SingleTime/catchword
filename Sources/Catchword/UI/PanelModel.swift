import Foundation
import AppKit
import AVFoundation
import Combine

@MainActor
final class PanelModel: ObservableObject {
    @Published var sourceText: String = ""
    @Published var translation: String = ""
    @Published var word: WordInfo?
    @Published var isTranslating: Bool = false
    @Published var errorText: String?
    @Published var noticeText: String?
    @Published var providerName: String = ""
    @Published var targetLabel: String = ""
    @Published var sourceLabel: String = ""
    @Published var frequency: Int = 0
    @Published var isStarred: Bool = false
    @Published var isPinned: Bool = false
    @Published var isEditing: Bool = false
    @Published var sourceAppName: String = ""
    @Published var elapsed: Double = 0
    @Published var showSettingsHint: Bool = false
    /// 每次弹出面板自增，用于让输入框自动获得焦点
    @Published var focusToken: Int = 0

    private var startedAt: Date?
    private var lastText: String = ""
    private let speech = AVSpeechSynthesizer()

    var wordMode: Bool { word != nil }

    // MARK: - 入口

    func show(text: String, appName: String) {
        sourceText = text
        sourceAppName = appName
        translate()
    }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastText = text
        isTranslating = true
        errorText = nil
        noticeText = nil
        translation = ""
        word = nil
        elapsed = 0
        startedAt = Date()

        let settings = SettingsStore.shared.settings
        providerName = settings.primaryProvider?.name ?? "未配置"
        let targetCode = TranslationService.resolveTarget(text: text, settings: settings)
        targetLabel = Lang.displayName(targetCode)
        sourceLabel = LangDetect.languageName(LangDetect.detect(text))

        // 命中词库则先展示历史释义，避免空白等待
        if let entry = VocabularyStore.shared.entry(for: text), !entry.translation.isEmpty {
            if !entry.phonetic.isEmpty {
                word = WordInfo(phonetic: entry.phonetic, pos: entry.pos,
                                definition: entry.translation, example: entry.example)
            }
        }
        frequency = VocabularyStore.shared.lookupCount(for: text).advanced(by: 1)

        TranslationService.shared.translate(rawText: text, sourceApp: sourceAppName) { [weak self] event in
            guard let self else { return }
            switch event {
            case .partial(let t):
                self.translation = t
            case .word(let w):
                self.word = w
            case .notice(let msg):
                self.noticeText = msg
            case .completed(let text, let w):
                self.translation = text
                if let w { self.word = w }
                self.isTranslating = false
                if let s = self.startedAt { self.elapsed = Date().timeIntervalSince(s) }
                self.refreshStar()
                self.frequency = VocabularyStore.shared.lookupCount(for: self.lastText)
                if SettingsStore.shared.settings.speakOnTranslate {
                    self.speak()
                }
                if SettingsStore.shared.settings.autoCopyTranslation {
                    self.copyResult(quiet: true)
                }
                self.postSizeChange()
            case .failed(let failure):
                self.isTranslating = false
                if failure == .cancelled {
                    self.errorText = nil
                } else {
                    self.errorText = failure.errorDescription
                }
                self.postSizeChange()
            }
        }
    }

    func retranslate(with provider: Provider) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isTranslating = true
        errorText = nil
        noticeText = nil
        translation = ""
        word = nil
        startedAt = Date()
        providerName = provider.name

        TranslationService.shared.translate(rawText: text, sourceApp: sourceAppName, forceProvider: provider) { [weak self] event in
            guard let self else { return }
            switch event {
            case .partial(let t): self.translation = t
            case .word(let w): self.word = w
            case .notice(let m): self.noticeText = m
            case .completed(let t, let w):
                self.translation = t
                if let w { self.word = w }
                self.isTranslating = false
                if let s = self.startedAt { self.elapsed = Date().timeIntervalSince(s) }
                self.refreshStar()
                self.postSizeChange()
            case .failed(let f):
                self.isTranslating = false
                self.errorText = f == .cancelled ? nil : f.errorDescription
                self.postSizeChange()
            }
        }
    }

    /// 中英互转
    func swapDirection() {
        let settings = SettingsStore.shared.settings
        let current = TranslationService.resolveTarget(text: lastText, settings: settings)
        var newSettings = settings
        newSettings.targetLanguage = (current == "en") ? "zh-Hans" : "en"
        SettingsStore.shared.settings = newSettings
        translate()
    }

    // MARK: - 操作

    func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sourceText, forType: .string)
    }

    func copyResult(quiet: Bool = false) {
        let text = translation.isEmpty ? (word?.definition ?? "") : translation
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if !quiet { noticeText = "译文已复制" }
    }

    func speak() {
        let text = word?.definition ?? translation
        guard !text.isEmpty else { return }
        let target = TranslationService.resolveTarget(text: lastText, settings: SettingsStore.shared.settings)
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: target)
        utterance.rate = 0.48
        speech.speak(utterance)
    }

    func stopSpeaking() {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
    }

    func refreshStar() {
        isStarred = VocabularyStore.shared.entry(for: lastText)?.starred ?? false
    }

    func toggleStar() {
        if let entry = VocabularyStore.shared.entry(for: lastText) {
            VocabularyStore.shared.toggleStar(entry)
        } else {
            VocabularyStore.shared.record(term: lastText,
                                           translation: translation,
                                           targetLang: TranslationService.resolveTarget(text: lastText, settings: SettingsStore.shared.settings),
                                           phonetic: word?.phonetic ?? "",
                                           pos: word?.pos ?? "",
                                           example: word?.example ?? "",
                                           sourceApp: sourceAppName,
                                           provider: providerName)
            if let e = VocabularyStore.shared.entry(for: lastText), !e.starred {
                VocabularyStore.shared.toggleStar(e)
            }
        }
        refreshStar()
    }

    private func postSizeChange() {
        NotificationCenter.default.post(name: .lingoContentSizeChanged, object: nil)
    }

    func reset() {
        TranslationService.shared.cancel()
        sourceText = ""
        translation = ""
        word = nil
        errorText = nil
        noticeText = nil
        frequency = 0
    }
}

extension Notification.Name {
    static let lingoContentSizeChanged = Notification.Name("lingo.contentSizeChanged")
    static let lingoRequestSettings = Notification.Name("lingo.requestSettings")
    static let lingoRequestVocabulary = Notification.Name("lingo.requestVocabulary")
    static let lingoTogglePin = Notification.Name("lingo.togglePin")
}
