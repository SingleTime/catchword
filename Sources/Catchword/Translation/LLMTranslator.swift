import Foundation

/// OpenAI 协议兼容的大模型翻译（/chat/completions，支持 SSE 流式）
final class LLMTranslator {
    static let shared = LLMTranslator()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Prompt

    static func systemPrompt(wordMode: Bool, userOverride: String) -> String {
        if !userOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return userOverride
        }
        if wordMode {
            return """
            你是一名严谨的双语词典编纂者。用户会给你一个单词或短语，以及它出现的上下文。
            只输出一个 JSON 对象，不要 markdown 代码块，不要任何前后解释。字段如下：
            {"phonetic": "国际音标（不含斜杠）", "pos": "词性缩写，如 n. / v. / adj.", "definition": "简体中文简明释义，多个义项用；分隔", "example": "一个地道的英文例句", "exampleTranslation": "例句的简体中文翻译", "synonyms": ["近义词1","近义词2"]}
            若目标语言不是中文，则 definition 与 exampleTranslation 用目标语言书写。
            """
        }
        return """
        你是一个专业的翻译引擎。只输出译文本身，不要解释、不要加引号、不要复述原文。
        保持原文的段落结构、换行、列表与标点风格；专有名词、代码、变量名、URL 原样保留。
        译文要符合目标语言的自然表达习惯，不要逐字硬译。
        """
    }

    static func userPrompt(text: String, targetName: String, wordMode: Bool, context: String) -> String {
        if wordMode {
            var p = "单词：\(text)\n目标语言：\(targetName)"
            if !context.isEmpty {
                p += "\n出现上下文：\(String(context.prefix(300)))"
            }
            return p
        }
        return "把下面的内容翻译成\(targetName)：\n\n\(text)"
    }

    // MARK: - 请求构造

    static func endpoint(for provider: Provider) -> URL? {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        return URL(string: base + "/chat/completions")
    }

    private func makeRequest(provider: Provider, apiKey: String, body: [String: Any]) throws -> URLRequest {
        guard let url = Self.endpoint(for: provider) else {
            throw TranslationFailure.badURL(provider.baseURL)
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationFailure.missingAPIKey(providerName: provider.name)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("Catchword/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func body(provider: Provider, text: String, targetName: String,
                      wordMode: Bool, context: String, stream: Bool) -> [String: Any] {
        var messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt(wordMode: wordMode, userOverride: provider.systemPrompt)],
            ["role": "user", "content": Self.userPrompt(text: text, targetName: targetName, wordMode: wordMode, context: context)]
        ]
        // 词典模式带一点少样本，稳定 JSON
        if wordMode {
            messages = [
                ["role": "system", "content": Self.systemPrompt(wordMode: true, userOverride: provider.systemPrompt)],
                ["role": "user", "content": Self.userPrompt(text: text, targetName: targetName, wordMode: true, context: context)]
            ]
        }
        return [
            "model": provider.model,
            "messages": messages,
            "temperature": provider.temperature,
            "stream": stream
        ]
    }

    // MARK: - 句子翻译（流式）

    func translateStream(text: String,
                         provider: Provider,
                         apiKey: String,
                         targetName: String,
                         emit: @escaping (TranslationEvent) -> Void) async {
        do {
            let req = try makeRequest(provider: provider, apiKey: apiKey,
                                      body: body(provider: provider, text: text, targetName: targetName,
                                                 wordMode: false, context: "", stream: true))
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationFailure.network("无响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                var errBody = ""
                for try await line in bytes.lines {
                    errBody += line
                    if errBody.count > 500 { break }
                }
                throw TranslationFailure.http(http.statusCode, errBody)
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !contentType.contains("event-stream") {
                // 服务端忽略了 stream，按整体 JSON 处理
                var raw = ""
                for try await line in bytes.lines { raw += line }
                let full = Self.extractContent(fromJSON: raw) ?? raw
                let out = full.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty else { throw TranslationFailure.empty }
                emit(.partial(out))
                emit(.completed(text: out, word: nil))
                return
            }

            var buffer = ""
            var pending = ""
            for try await line in bytes.lines {
                if Task.isCancelled { throw TranslationFailure.cancelled }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }

                if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
                    if let delta = chunk.choices.first?.delta.content {
                        pending += delta
                        // 粗略按句节流，避免每个 token 都刷新 UI
                        if pending.count >= 8 || delta.contains("\n") || delta.contains("。")
                            || delta.contains("！") || delta.contains("？")
                            || delta.contains(".") || delta.contains("!") || delta.contains("?") {
                            buffer += pending
                            pending = ""
                            emit(.partial(buffer))
                        }
                    }
                }
            }
            buffer += pending
            let out = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { throw TranslationFailure.empty }
            emit(.completed(text: out, word: nil))
        } catch let failure as TranslationFailure {
            emit(.failed(failure))
        } catch is CancellationError {
            emit(.failed(.cancelled))
        } catch let urlError as URLError where urlError.code == .cancelled {
            emit(.failed(.cancelled))
        } catch {
            let ns = error as NSError
            emit(.failed(.network(ns.localizedDescription)))
        }
    }

    // MARK: - 单词查询（非流式 JSON，便于解析结构化字段）

    func lookupWord(_ term: String,
                    context: String,
                    provider: Provider,
                    apiKey: String,
                    targetName: String,
                    emit: @escaping (TranslationEvent) -> Void) async {
        do {
            let req = try makeRequest(provider: provider, apiKey: apiKey,
                                      body: body(provider: provider, text: term, targetName: targetName,
                                                 wordMode: true, context: context, stream: false))
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationFailure.network("无响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw TranslationFailure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            guard let raw = String(data: data, encoding: .utf8),
                  let content = Self.extractContent(fromJSON: raw) else {
                throw TranslationFailure.empty
            }

            if let info = Self.parseWordInfo(content) {
                emit(.word(info))
                let text = info.definition.isEmpty ? content : info.definition
                emit(.completed(text: text, word: info))
            } else {
                let out = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !out.isEmpty else { throw TranslationFailure.empty }
                emit(.partial(out))
                emit(.completed(text: out, word: nil))
            }
        } catch let failure as TranslationFailure {
            emit(.failed(failure))
        } catch is CancellationError {
            emit(.failed(.cancelled))
        } catch {
            let ns = error as NSError
            emit(.failed(.network(ns.localizedDescription)))
        }
    }

    // MARK: - 解析

    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    static func extractContent(fromJSON raw: String) -> String? {
        guard let data = raw.data(using: .utf8) else { return nil }
        if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) {
            return decoded.choices.first?.message.content
        }
        // 有些兼容实现把 message 简化为 text / 直接 delta
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = obj["choices"] as? [[String: Any]],
           let first = choices.first {
            if let msg = first["message"] as? [String: Any],
               let c = msg["content"] as? String { return c }
            if let c = first["text"] as? String { return c }
        }
        return nil
    }

    static func parseWordInfo(_ content: String) -> WordInfo? {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉可能的 ```json 围栏
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            }
            if let range = s.range(of: "```", options: .backwards) {
                s = String(s[..<range.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = String(s[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        guard let info = try? JSONDecoder().decode(WordInfo.self, from: data) else { return nil }
        return info.isEmpty ? nil : info
    }
}
