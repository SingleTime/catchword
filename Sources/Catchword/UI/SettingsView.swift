import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 设置根视图

@MainActor
struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("通用", systemImage: "slider.horizontal.3") }
            ProvidersTab().tabItem { Label("翻译服务", systemImage: "server.rack") }
            VocabSettingsTab().tabItem { Label("词库", systemImage: "books.vertical") }
            AboutTab().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 560)
    }
}

// MARK: - 绑定辅助

@MainActor
extension SettingsStore {
    func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - 通用

@MainActor
struct GeneralTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "取词", icon: "cursorarrow.rays") {
                    HStack {
                        Label("取词快捷键", systemImage: "keyboard")
                        Spacer()
                        ShortcutRecorder(keyCode: store.bind(\.hotKeyCode),
                                         modifiers: store.bind(\.hotKeyModifiers))
                            .frame(width: 120)
                    }
                    Text("选中文字后按下即可取词翻译；直接按（不选文字）则打开空白输入框。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)

                    HStack {
                        Label("划词即译", systemImage: "text.cursor")
                        Spacer()
                        Toggle("", isOn: store.bind(\.selectionTriggerEnabled))
                            .labelsHidden()
                            .onChange(of: store.settings.selectionTriggerEnabled) { _ in
                                AppDelegate.shared?.applyTriggerSettings()
                            }
                    }
                    Text("选中文字松手后，在选区右下角冒出一个「译」小圆点，点它或让鼠标停一下就展开。不用再按快捷键。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Label("双击直接展开", systemImage: "hand.tap")
                        Spacer()
                        Toggle("", isOn: store.bind(\.selectionDirectOnDoubleClick))
                            .labelsHidden()
                            .disabled(!store.settings.selectionTriggerEnabled)
                    }

                    HStack {
                        Label("触发长度上限", systemImage: "textformat.size")
                        Spacer()
                        Stepper(value: store.bind(\.selectionMaxLength), in: 10...300, step: 10) {
                            Text("\(store.settings.selectionMaxLength) 字符")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(store.settings.selectionTriggerEnabled ? .primary : .secondary)
                        }
                        .disabled(!store.settings.selectionTriggerEnabled)
                    }
                    Text("只处理单行文本；超过这个长度（比如整段代码）不弹，避免误触。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)

                    HStack {
                        Label("复制即译", systemImage: "doc.on.clipboard")
                        Spacer()
                        Toggle("", isOn: store.bind(\.clipboardTriggerEnabled))
                            .labelsHidden()
                            .onChange(of: store.settings.clipboardTriggerEnabled) { _ in
                                AppDelegate.shared?.applyTriggerSettings()
                            }
                    }
                    Text("选中文字按一下 ⌘C 就弹气泡。不需要辅助功能权限——系统不给授权时用它兜底。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider().padding(.vertical, 2)

                    HStack {
                        Label("辅助功能权限", systemImage: "lock.shield")
                        Spacer()
                        PermissionBadge()
                    }
                    Text("在系统设置里勾选后不用重启，这里 1~2 秒内会自动变成「已授权」，划词也会自动接上。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard(title: "翻译", icon: "character.bubble") {
                    HStack {
                        Label("目标语言", systemImage: "globe")
                        Spacer()
                        Picker("", selection: store.bind(\.targetLanguage)) {
                            ForEach(Lang.targets, id: \.code) { item in
                                Text(item.name).tag(item.code)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    HStack {
                        Label("默认服务", systemImage: "wand.and.stars")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.settings.primaryProviderID ?? UUID() },
                            set: { store.settings.primaryProviderID = $0 }
                        )) {
                            ForEach(store.settings.providers.filter(\.enabled)) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    HStack {
                        Label("单词查词典", systemImage: "text.book.closed")
                        Spacer()
                        Toggle("", isOn: store.bind(\.dictionaryModeForWords)).labelsHidden()
                    }
                    Text("开启后，单个单词会附带音标、词性与释义（优先用本机词典，大模型可给出例句）。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard(title: "浮窗", icon: "macwindow") {
                    HStack {
                        Label("字号", systemImage: "textformat.size")
                        Spacer()
                        Slider(value: store.bind(\.fontSize), in: 11...20, step: 1)
                            .frame(width: 140)
                        Text("\(Int(store.settings.fontSize))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                    }
                    HStack {
                        Label("宽度", systemImage: "arrow.left.and.right")
                        Spacer()
                        Slider(value: store.bind(\.panelWidth), in: 320...560, step: 10)
                            .frame(width: 140)
                        Text("\(Int(store.settings.panelWidth))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }
                    Toggle("翻译后自动复制译文", isOn: store.bind(\.autoCopyTranslation))
                    Toggle("翻译后自动朗读", isOn: store.bind(\.speakOnTranslate))
                    HStack {
                        Toggle("显示查询次数", isOn: store.bind(\.showFrequencyInPanel))
                        Spacer()
                        Toggle("开机自启", isOn: store.bind(\.launchAtLogin))
                            .onChange(of: store.settings.launchAtLogin) { newValue in
                                LaunchAgent.setEnabled(newValue)
                            }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - 权限徽章

@MainActor
struct PermissionBadge: View {
    @State private var granted = Permissions.canWorkNow
    @State private var ticker: Timer?

    var body: some View {
        HStack(spacing: 8) {
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Label("未授权", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                Button("去授权") {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            granted = Permissions.canWorkNow
            ticker = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    // canWorkNow 会真的试着建一次事件监听，绕过 AXIsProcessTrusted 的进程内缓存，
                    // 所以用户在系统设置里勾上后，这里 1.5 秒内就会翻成已授权。
                    let now = Permissions.canWorkNow
                    if now != granted { granted = now }
                    if now, !SelectionMonitor.shared.isRunning {
                        SelectionMonitor.shared.start()   // 权限刚生效，顺手把划词监听补上
                    }
                }
            }
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
    }
}

// MARK: - 服务

@MainActor
struct ProvidersTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var expanded: UUID?
    @State private var testResult: [UUID: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.settings.providers) { provider in
                    ProviderCard(provider: provider,
                                 expanded: expanded == provider.id,
                                 testResult: testResult[provider.id],
                                 onToggleExpand: {
                                     expanded = (expanded == provider.id) ? nil : provider.id
                                 },
                                 onTest: { await test(provider) })
                }

                Menu {
                    Button("OpenAI 兼容接口") {
                        let p = Provider.openAI(name: "新服务")
                        store.addProvider(p)
                        expanded = p.id
                    }
                    Button("Apple 系统翻译") {
                        let p = Provider.apple()
                        store.addProvider(p)
                        expanded = p.id
                    }
                    Button("系统词典（离线）") {
                        let p = Provider.dictionary()
                        store.addProvider(p)
                        expanded = p.id
                    }
                } label: {
                    Label("添加服务", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

                Text("提示：任何兼容 OpenAI /chat/completions 协议的服务都可以接入（DeepSeek、通义、Kimi、Ollama、LM Studio、OneAPI 等）。API Key 存于系统钥匙串。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(20)
        }
    }

    private func test(_ provider: Provider) async {
        guard provider.kind == .openAI else {
            testResult[provider.id] = "本机可用"
            return
        }
        testResult[provider.id] = "测试中…"
        let key = Keychain.get("provider.\(provider.id.uuidString)") ?? ""
        guard !key.isEmpty else {
            testResult[provider.id] = "缺少 API Key"
            return
        }
        var req: URLRequest
        do {
            guard let url = LLMTranslator.endpoint(for: provider) else {
                testResult[provider.id] = "地址不合法"
                return
            }
            req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": provider.model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 8,
                "stream": false
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 20

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                testResult[provider.id] = "无响应"
                return
            }
            if (200..<300).contains(http.statusCode) {
                testResult[provider.id] = "连接正常"
            } else {
                let msg = String(data: data, encoding: .utf8)?.prefix(80) ?? ""
                testResult[provider.id] = "HTTP \(http.statusCode) \(msg)"
            }
        } catch {
            testResult[provider.id] = error.localizedDescription
        }
    }
}

@MainActor
struct ProviderCard: View {
    let provider: Provider
    let expanded: Bool
    let testResult: String?
    let onToggleExpand: () -> Void
    let onTest: () async -> Void

    @ObservedObject private var store = SettingsStore.shared
    @State private var apiKeyDraft: String = ""
    @State private var showKey = false

    private func bind<T>(_ kp: WritableKeyPath<Provider, T>) -> Binding<T> {
        Binding(
            get: { store.settings.providers.first(where: { $0.id == provider.id })?[keyPath: kp] ?? provider[keyPath: kp] },
            set: { value in
                guard var p = store.settings.providers.first(where: { $0.id == provider.id }) else { return }
                p[keyPath: kp] = value
                store.updateProvider(p)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: provider.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(.system(size: 13, weight: .medium))
                    Text(provider.kind.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.settings.primaryProviderID == provider.id {
                    Badge(text: "默认", color: .accentColor)
                }
                Toggle("", isOn: bind(\.enabled)).labelsHidden().controlSize(.mini)
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if provider.kind == .openAI {
                        field("名称", text: bind(\.name))
                        field("接口地址", text: bind(\.baseURL), hint: "以 /v1 结尾，例如 https://api.deepseek.com/v1")
                        HStack(spacing: 10) {
                            field("模型", text: bind(\.model), hint: "deepseek-chat / qwen-plus / gpt-4o-mini")
                        }

                        HStack(spacing: 8) {
                            Text("API Key").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            Group {
                                if showKey {
                                    TextField("sk-…", text: $apiKeyDraft)
                                } else {
                                    SecureField("sk-…", text: $apiKeyDraft)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Text("温度").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            Slider(value: bind(\.temperature), in: 0...1, step: 0.1)
                            Text(String(format: "%.1f", provider.temperature))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("自定义提示词（留空用内置）").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextEditor(text: bind(\.systemPrompt))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 54)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        }

                        HStack(spacing: 10) {
                            Button("测试连接") { Task { await onTest() } }
                                .controlSize(.small)
                            if let r = testResult {
                                Text(r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if store.settings.providers.count > 1 {
                                Button("删除", role: .destructive) {
                                    store.removeProvider(provider.id)
                                }
                                .controlSize(.small)
                            }
                        }
                    } else if provider.kind == .apple {
                        VStack(alignment: .leading, spacing: 6) {
                            if AppleEngine.isAvailable {
                                Text("使用 macOS 系统离线翻译引擎，无需联网、无需密钥。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text("首次使用需要系统里已下载语言包：系统设置 › 通用 › 语言与地区 › 翻译语言。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                    Text("当前系统（macOS \(AppleEngine.systemVersionText)）没有系统翻译引擎")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text("系统翻译需要 macOS 15 或更新版本。在这之前的系统里没有机器翻译引擎，单词会自动改用本机词典，整句请配置一个大模型服务。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                field("名称", text: bind(\.name))
                                Spacer()
                                if store.settings.providers.count > 1 {
                                    Button("删除", role: .destructive) {
                                        store.removeProvider(provider.id)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("调用「词典.app」里已安装的词库离线查词，新系统通常自带《牛津英汉汉英词典》。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("只处理单个词，不支持整句；不会产生任何网络请求。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                field("名称", text: bind(\.name))
                                Spacer()
                                if store.settings.providers.count > 1 {
                                    Button("删除", role: .destructive) {
                                        store.removeProvider(provider.id)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .onAppear {
            apiKeyDraft = Keychain.get("provider.\(provider.id.uuidString)") ?? ""
        }
        .onChange(of: apiKeyDraft) { newValue in
            guard provider.kind == .openAI else { return }
            let id = provider.id
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if newValue.isEmpty {
                    Keychain.delete("provider.\(id.uuidString)")
                } else {
                    Keychain.set(newValue, for: "provider.\(id.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, hint: String = "") -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            TextField(hint, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}

// MARK: - 词库设置

@MainActor
struct VocabSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var vocab = VocabularyStore.shared
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionCard(title: "自动收录", icon: "tray.and.arrow.down") {
                    Toggle("翻译单词时自动记入词库", isOn: store.bind(\.autoCollectWords))
                    HStack {
                        Text("最短收录长度")
                            .font(.system(size: 12))
                        Spacer()
                        Stepper(value: store.bind(\.minWordLength), in: 1...10) {
                            Text("\(store.settings.minWordLength) 个字符")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("同一个词被反复查询时会自动累加次数，「词库」里可以按查询频次排序，优先复习你真正遇到过的词。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard(title: "统计", icon: "chart.bar") {
                    HStack(spacing: 26) {
                        stat("词库总量", "\(vocab.wordCount)")
                        stat("今日查询", "\(vocab.todayLookups)")
                        stat("累计查询", "\(vocab.totalLookups)")
                        stat("待复习", "\(vocab.dueCount)")
                    }
                }

                SectionCard(title: "导出", icon: "square.and.arrow.up") {
                    HStack(spacing: 10) {
                        Button("导出 CSV") {
                            do {
                                let url = try vocab.exportCSV()
                                toast = "已导出：\(url.path)"
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } catch {
                                toast = "导出失败：\(error.localizedDescription)"
                            }
                        }
                        Button("导出 Anki") {
                            do {
                                let url = try vocab.exportAnki()
                                toast = "已导出：\(url.path)"
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } catch {
                                toast = "导出失败：\(error.localizedDescription)"
                            }
                        }
                    }
                    if let toast {
                        Text(toast)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(20)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 关于

@MainActor
struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("捕词 Catchword").font(.system(size: 18, weight: .semibold))
            Text("版本 1.1.0 · 原生 SwiftUI / AppKit")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("选中即译 · 纯本地优先 · 越查越懂你")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider().frame(width: 240).padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 6) {
                row("兼容系统", "macOS 12 及以上（通用二进制 arm64 + x86_64）")
                row("系统翻译", "macOS 15+ 的离线翻译引擎")
                row("本机词典", "任何版本都能用，查「词典.app」的离线词库")
                row("大模型", "任何 OpenAI 兼容接口，Key 存钥匙串")
                row("数据存储", "~/Library/Application Support/Catchword")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).frame(width: 66, alignment: .leading)
            Text(v).foregroundStyle(.primary.opacity(0.75))
        }
    }
}

// MARK: - 复用卡片

@MainActor
struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}

// MARK: - 快捷键录制

@MainActor
struct ShortcutRecorder: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording.toggle()
            if recording { startMonitor() } else { stopMonitor() }
        } label: {
            Text(recording ? "按下组合键…" : KeyCodeName.display(keyCode: keyCode, modifiers: modifiers))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(recording ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitor() }
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

            if event.keyCode == 53 && carbon == 0 {  // Esc 取消
                recording = false
                stopMonitor()
                return nil
            }
            guard carbon != 0 else { return nil }
            keyCode = UInt32(event.keyCode)
            modifiers = carbon
            recording = false
            stopMonitor()
            AppDelegate.shared?.reregisterHotKey()
            return nil
        }
    }

    private func stopMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
