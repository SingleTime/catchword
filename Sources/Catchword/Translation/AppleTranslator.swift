import Foundation
import NaturalLanguage
import Translation

/// 系统翻译引擎的可用性与版本分流。
///
/// - macOS **15** 起有 `Translation.framework`（和「翻译.app」同一套端上模型），
///   但 `TranslationSession` 只能由 SwiftUI 的 `.translationTask` 递进来 → 走 `AppleSessionBridge`。
/// - macOS **26** 起新增 `TranslationSession(installedSource:target:)`，可脱离 SwiftUI 直接建 session → 直连。
/// - macOS **12–14** 系统里没有任何机器翻译引擎，只能靠本机词典（单词）或大模型（整句）。
enum AppleEngine {
    /// 当前系统能否调用系统翻译
    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 是否需要走「隐藏窗口 + translationTask」的兼容路径
    static var needsBridge: Bool {
        if #available(macOS 26.0, *) { return false }
        return true
    }

    static var systemVersionText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    static var unavailableReason: String {
        "当前系统是 macOS \(systemVersionText)，系统翻译引擎需要 macOS 15 或更新版本"
    }

    /// 调试用：在 macOS 26+ 上强制走兼容路径，用来验证 bridge 本身没问题
    static var forceBridge: Bool {
        ProcessInfo.processInfo.environment["CATCHWORD_FORCE_BRIDGE"] == "1"
    }
}

/// Apple 系统翻译（Translation.framework，macOS 15+）
@available(macOS 15.0, *)
final class AppleTranslator {
    static let shared = AppleTranslator()

    private let availability = LanguageAvailability()

    func status(sourceCode: String, targetCode: String) async -> LanguageAvailability.Status {
        await availability.status(from: Locale.Language(identifier: sourceCode),
                                  to: Locale.Language(identifier: targetCode))
    }

    /// 语言包是否已装（设置页展示用）
    func isPairInstalled(sourceCode: String, targetCode: String) async -> Bool {
        await status(sourceCode: sourceCode, targetCode: targetCode) == .installed
    }

    /// 拆掉宿主窗口，下次调用重建（语言包刚下载完、或 session 失效时用）
    @MainActor
    func invalidateBridge() {
        AppleSessionBridge.shared.invalidate()
    }

    func translate(_ text: String, targetCode: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationFailure.empty }

        let detected = LangDetect.detect(trimmed)
        let sourceCode = normalize(detected)
        let targetCode = normalize(targetCode)

        // 同语言无需翻译
        if sourceCode == targetCode {
            return trimmed
        }

        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetCode)

        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            throw TranslationFailure.appleLanguagePackMissing(
                sourceName: LangDetect.languageName(sourceCode),
                targetName: LangDetect.languageName(targetCode))
        case .unsupported:
            throw TranslationFailure.appleUnsupportedPair(
                sourceName: LangDetect.languageName(sourceCode),
                targetName: LangDetect.languageName(targetCode))
        @unknown default:
            throw TranslationFailure.appleUnavailable("未知的语言包状态")
        }

        do {
            if #available(macOS 26.0, *), !AppleEngine.forceBridge {
                return try await translateDirect(trimmed, source: source, target: target)
            } else {
                return try await AppleSessionBridge.shared.translate(trimmed,
                                                                    sourceCode: sourceCode,
                                                                    targetCode: targetCode)
            }
        } catch let failure as TranslationFailure {
            throw failure
        } catch {
            let ns = error as NSError
            // 兼容路径下 session 可能已失效，拆掉重建，避免下次继续撞同一个错
            await AppleSessionBridge.shared.invalidate()
            throw TranslationFailure.appleUnavailable("\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
        }
    }

    /// macOS 26+ 的直连路径：不需要 SwiftUI 宿主
    @available(macOS 26.0, *)
    private func translateDirect(_ text: String,
                                 source: Locale.Language,
                                 target: Locale.Language) async throws -> String {
        let session = TranslationSession(installedSource: source, target: target)
        let response = try await session.translate(text)
        let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw TranslationFailure.empty }
        return out
    }

    /// 统一成 Translation 框架认的语言标识（zh → zh-Hans）
    private func normalize(_ code: String) -> String {
        switch code {
        case "zh", "zh-CN", "zh_CN": return Lang.zhHans
        case "zh-TW", "zh-HK", "zh-Hant": return Lang.zhHant
        default: return code
        }
    }
}
