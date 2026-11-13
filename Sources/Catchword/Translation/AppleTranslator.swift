import Foundation
import NaturalLanguage
import Translation

/// 系统翻译引擎的可用性判断。
/// `Translation.framework` 在 macOS 15 才出现，能脱离 SwiftUI 直接构造 session 的
/// `TranslationSession(installedSource:target:)` 要 macOS 26，所以引擎本体全部关在 `@available` 里。
enum AppleEngine {
    /// 当前系统能否真正调用系统翻译
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var systemVersionText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// 不可用时的说明（带上当前系统版本，便于用户判断）
    static var unavailableReason: String {
        "当前系统是 macOS \(systemVersionText)，系统翻译引擎需要 macOS 26 或更新版本"
    }
}

/// Apple 系统翻译（Translation.framework，macOS 26+ 可直接构造 Session，无需 SwiftUI）
@available(macOS 26.0, *)
final class AppleTranslator {
    static let shared = AppleTranslator()

    private let availability = LanguageAvailability()

    func status(sourceCode: String, targetCode: String) async -> LanguageAvailability.Status {
        await availability.status(from: Locale.Language(identifier: sourceCode),
                                  to: Locale.Language(identifier: targetCode))
    }

    /// 同步检测语言包的轻量入口（用于设置页展示）
    func isPairInstalled(sourceCode: String, targetCode: String) async -> Bool {
        await status(sourceCode: sourceCode, targetCode: targetCode) == .installed
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

        let session = TranslationSession(installedSource: source, target: target)
        do {
            let response = try await session.translate(trimmed)
            let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { throw TranslationFailure.empty }
            return out
        } catch let failure as TranslationFailure {
            throw failure
        } catch {
            let ns = error as NSError
            throw TranslationFailure.appleUnavailable("\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
        }
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
