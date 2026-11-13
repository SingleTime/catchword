import Foundation
import AppKit
import SwiftUI
import Translation

/// macOS 15–25 上获得 `TranslationSession` 的唯一途径。
///
/// `TranslationSession` 没有公开的无参初始化方法，直接 `TranslationSession(installedSource:target:)`
/// 要 macOS 26。系统只肯通过 SwiftUI 的 `.translationTask` 修饰符把 session 递进来。
///
/// 这里的做法：挂一个 1×1 全透明的隐藏窗口，里面放一个只有 `Color.clear` 的宿主视图，
/// 用 `.translationTask` 接住 session；外部请求先进内部队列，再由修饰符的 action 闭包串行消费。
/// 真正的 `translate` 调用始终发生在闭包内 —— 闭包一旦返回，系统就会回收 session，
/// 所以消费循环不能退出，靠 `for await` 挂在任务流上。
@available(macOS 15.0, *)
@MainActor
final class AppleSessionBridge {
    static let shared = AppleSessionBridge()

    private final class Job {
        let text: String
        var continuation: CheckedContinuation<String, Error>?
        init(text: String) { self.text = text }
    }

    private var window: NSWindow?
    private var hostKey: String?
    private var jobFeed: AsyncStream<Job>.Continuation?
    /// 已入队未完成的请求，拆宿主时要逐个叫醒，否则调用方会一直挂着
    private var pending: [Job] = []
    private var sessionReady = false

    private init() {}

    // MARK: - 对外接口

    /// 用系统离线引擎翻译。
    ///
    /// **源语言必须显式传**：`source: nil` 交给系统自动识别时，单个单词（如 `coin`）
    /// 会因为语言置信度不足而一直挂着不返回（实测必现），整句则正常。
    /// 我们本来就用 NLD 检测过源语言，直接传进来，顺便省掉引擎内部的一次识别。
    func translate(_ text: String, sourceCode: String, targetCode: String) async throws -> String {
        try prepareHost(sourceCode: sourceCode, targetCode: targetCode)

        // 正常几十毫秒就绪；超时说明系统那边没起来，抛错让上层按降级链继续
        guard await waitReady(timeout: 6) else {
            throw TranslationFailure.appleUnavailable("系统翻译在 6 秒内没有就绪")
        }

        let job = Job(text: text)
        pending.append(job)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            job.continuation = cont
            jobFeed?.yield(job)
        }
    }

    /// 语言方向变了才重建宿主；否则复用现有 session
    private func prepareHost(sourceCode: String, targetCode: String) throws {
        let key = "\(sourceCode)|\(targetCode)"
        if window != nil, hostKey == key { return }

        if hostKey != nil {
            // 已有宿主但方向不同：静默重建，进行中的请求交给上层超时处理
            teardown()
        }
        guard window == nil else { return }

        let configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceCode),
            target: Locale.Language(identifier: targetCode))
        let (stream, feed) = AsyncStream<Job>.makeStream()
        jobFeed = feed

        let host = BridgeHostView(configuration: configuration) { [weak self] session in
            await self?.consume(session: session, stream: stream)
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.alphaValue = 0            // 全透明也不行？实测可行，见项目日志
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.contentView = NSHostingView(rootView: host)
        w.setFrameOrigin(NSPoint(x: 8, y: 8))
        w.orderFrontRegardless()    // 必须真正进窗口层级，否则 SwiftUI 不会跑 translationTask

        window = w
        hostKey = key
        sessionReady = false
    }

    /// 在 `.translationTask` 的 action 闭包内串行消费队列，直到任务被取消或流结束
    private func consume(session: TranslationSession, stream: AsyncStream<Job>) async {
        sessionReady = true

        for await job in stream {
            pending.removeAll { $0 === job }
            if Task.isCancelled {
                job.continuation?.resume(throwing: TranslationFailure.cancelled)
                break
            }
            do {
                let response = try await session.translate(job.text)
                let out = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.isEmpty {
                    job.continuation?.resume(throwing: TranslationFailure.empty)
                } else {
                    job.continuation?.resume(returning: out)
                }
            } catch {
                job.continuation?.resume(throwing: error)
            }
        }
        sessionReady = false
    }

    private func waitReady(timeout: TimeInterval) async -> Bool {
        if sessionReady { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sessionReady { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return sessionReady
    }

    private func teardown() {
        jobFeed?.finish()
        jobFeed = nil
        pending.forEach { $0.continuation?.resume(throwing: TranslationFailure.cancelled) }
        pending.removeAll()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        hostKey = nil
        sessionReady = false
    }

    /// 预热：浮窗打开前先把宿主窗口搭好，第一次查词就不用等一次窗口启动
    func prewarm(sourceCode: String, targetCode: String) {
        try? prepareHost(sourceCode: sourceCode, targetCode: targetCode)
    }

    /// 系统语言包状态变化（比如用户刚下载完）后调用，强制下次重建
    func invalidate() {
        teardown()
    }
}

/// 只做一件事：把 session 交给闭包，然后一直挂着
@available(macOS 15.0, *)
private struct BridgeHostView: View {
    let configuration: TranslationSession.Configuration
    let onSession: (TranslationSession) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                await onSession(session)
            }
    }
}
