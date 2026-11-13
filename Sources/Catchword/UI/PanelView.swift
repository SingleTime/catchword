import SwiftUI
import AppKit

@MainActor
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var settingsStore: SettingsStore
    @State private var sourceHeight: CGFloat = 20

    var onHeightChange: (CGFloat) -> Void

    init(model: PanelModel, onHeightChange: @escaping (CGFloat) -> Void) {
        self.model = model
        self._settingsStore = ObservedObject(wrappedValue: SettingsStore.shared)
        self.onHeightChange = onHeightChange
    }

    private var s: AppSettings { settingsStore.settings }
    private var fontSize: CGFloat { CGFloat(s.fontSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            sourceBlock

            if hasResult {
                Divider().opacity(0.55)
                resultBlock
            }

            if let w = model.word, !w.isEmpty {
                wordBlock(w)
            }

            if let notice = model.noticeText {
                noticeBar(notice)
            }

            footer
        }
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: CGFloat(s.panelWidth))
        .background(
            ZStack {
                VisualEffectView(material: .popover, blending: .behindWindow)
                Color(nsColor: .windowBackgroundColor).opacity(0.78)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
        )
        .onGeometryChangeCompat { height in
            onHeightChange(height)
        }
    }

    private var hasResult: Bool {
        model.isTranslating || !model.translation.isEmpty || model.errorText != nil || model.word != nil
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 5) {
            Text(model.sourceLabel.isEmpty ? "自动检测" : model.sourceLabel)
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(model.targetLabel.isEmpty ? "—" : model.targetLabel)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(metaLine)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            IconButton(symbol: model.isPinned ? "pin.fill" : "pin",
                       help: "钉住窗口（点击外部不隐藏）",
                       active: model.isPinned,
                       size: 10) {
                NotificationCenter.default.post(name: .lingoTogglePin, object: nil)
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private var metaLine: String {
        var parts: [String] = []
        if !model.providerName.isEmpty { parts.append(model.providerName) }
        if model.elapsed > 0 { parts.append(String(format: "%.2fs", model.elapsed)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 原文

    private var sourceBlock: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty {
                    Text("输入或粘贴要翻译的内容")
                        .font(.system(size: fontSize + 1))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                SourceTextView(text: $model.sourceText,
                               fontSize: fontSize + 1,
                               focusToken: model.focusToken,
                               maxHeight: (fontSize + 4) * 5.4,
                               onSubmit: { model.translate() },
                               onEscape: { PanelController.shared.hide() },
                               onHeightChange: { height in
                                   if abs(height - sourceHeight) > 0.5 { sourceHeight = height }
                               })
                    .frame(height: sourceHeight)
            }

            if !model.sourceText.isEmpty {
                IconButton(symbol: "arrow.right.circle.fill", help: "翻译（Enter）", tint: .accentColor, size: 13) {
                    model.translate()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    // MARK: - 译文

    @ViewBuilder
    private var resultBlock: some View {
        if let error = model.errorText {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button("重试") { model.translate() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Button("打开设置") {
                        NotificationCenter.default.post(name: .lingoRequestSettings, object: nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.translation.isEmpty && model.isTranslating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("翻译中…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: 20)
        } else {
            Text(model.translation)
                .font(.system(size: fontSize))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(model.isTranslating ? 0.92 : 1)
        }
    }

    // MARK: - 词条

    private func wordBlock(_ w: WordInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if !w.phonetic.isEmpty {
                    Text("/\(w.phonetic)/")
                        .font(.system(size: CGFloat(s.fontSize) - 2, design: .serif))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !w.pos.isEmpty { Badge(text: w.pos) }
                if model.frequency > 1 && s.showFrequencyInPanel {
                    Badge(text: "第 \(model.frequency) 次查询", color: .accentColor)
                }
                Spacer()
            }

            if !w.example.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.example)
                        .font(.system(size: CGFloat(s.fontSize) - 3))
                        .italic()
                        .foregroundStyle(.secondary)
                    if !w.exampleTranslation.isEmpty {
                        Text(w.exampleTranslation)
                            .font(.system(size: CGFloat(s.fontSize) - 3))
                            .foregroundStyle(.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }

            if !w.synonyms.isEmpty {
                Text("近义：" + w.synonyms.prefix(4).joined(separator: " · "))
                    .font(.system(size: CGFloat(s.fontSize) - 4))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - 提示条

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "doc.on.doc", help: "复制译文") { model.copyResult() }
            IconButton(symbol: "speaker.wave.2", help: "朗读") { model.speak() }
            IconButton(symbol: model.isStarred ? "star.fill" : "star",
                       help: "收藏 / 取消收藏",
                       active: model.isStarred) { model.toggleStar() }
            IconButton(symbol: "arrow.left.arrow.right", help: "中英互换") { model.swapDirection() }

            providerMenu

            Spacer(minLength: 4)

            if !model.sourceAppName.isEmpty {
                Text(model.sourceAppName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            IconButton(symbol: "books.vertical", help: "词库") {
                NotificationCenter.default.post(name: .lingoRequestVocabulary, object: nil)
            }
            IconButton(symbol: "gearshape", help: "设置") {
                NotificationCenter.default.post(name: .lingoRequestSettings, object: nil)
            }
        }
        .padding(.top, 1)
    }

    private var providerMenu: some View {
        Menu {
            ForEach(s.providers.filter { $0.enabled }) { p in
                Button {
                    model.retranslate(with: p)
                } label: {
                    if p.id == s.primaryProviderID {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .help("换一个翻译服务")
    }
}
