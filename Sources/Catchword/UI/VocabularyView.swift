import SwiftUI
import AppKit
import AVFoundation

@MainActor
struct VocabularyView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var selectedID: Int?
    @State private var reviewMode = false
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if reviewMode {
                ReviewPane(onExit: { reviewMode = false })
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 240, idealWidth: 310)
                    detail
                        .frame(minWidth: 330)
                }
            }
            if let toast {
                Divider()
                HStack {
                    Text(toast).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { store.reload() }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索单词或释义", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 180)
                .onSubmit { store.reload() }
                .onChange(of: store.searchText) { _ in store.reload() }

            Divider().frame(height: 16)

            Picker("", selection: $store.sort) {
                ForEach(VocabSort.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: store.sort) { _ in store.reload() }

            Toggle(isOn: $store.onlyStarred) {
                Label("收藏", systemImage: "star.fill")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .onChange(of: store.onlyStarred) { _ in store.reload() }

            Spacer()

            if store.dueCount > 0 {
                Button {
                    reviewMode = true
                } label: {
                    Label("复习 \(store.dueCount)", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }

            Text("\(store.entries.count) 词")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: 列表

    private var list: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("还没有收录单词")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("选中文字按快捷键翻译，单词会自动进来")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            row(entry)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: VocabEntry) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.term)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if entry.starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    if entry.lookupCount >= 3 {
                        Badge(text: "×\(entry.lookupCount)", color: .accentColor)
                    }
                }
                Text(entry.translation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StrengthDots(level: entry.strength)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedID == entry.id ? Color.accentColor.opacity(0.14) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = entry.id }
        .contextMenu {
            Button(entry.starred ? "取消收藏" : "收藏") { store.toggleStar(entry) }
            Button(entry.mastered ? "标记为未掌握" : "标记为已掌握") { store.toggleMastered(entry) }
            Divider()
            Button("删除", role: .destructive) {
                store.delete(entry)
                if selectedID == entry.id { selectedID = nil }
            }
        }
    }

    // MARK: 详情

    @ViewBuilder
    private var detail: some View {
        if let entry = store.entries.first(where: { $0.id == selectedID }) {
            detailPane(entry)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "hand.point.left")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("选择一个词查看详情")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailPane(_ e: VocabEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.term).font(.system(size: 24, weight: .semibold))
                    HStack(spacing: 8) {
                        if !e.phonetic.isEmpty {
                            Text("/\(e.phonetic)/")
                                .font(.system(size: 12, design: .serif))
                                .foregroundStyle(.secondary)
                        }
                        if !e.pos.isEmpty { Badge(text: e.pos) }
                        if e.isDue { Badge(text: "待复习", color: .orange) }
                    }
                }

                Text(e.translation)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !e.example.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("例句").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        Text(e.example)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                if !e.context.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("原文上下文").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        Text(e.context)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                // macOS 12 没有 Grid/GridRow，用固定栏宽的两列布局等效实现
                VStack(alignment: .leading, spacing: 6) {
                    metaRow("查询次数", "\(e.lookupCount)")
                    metaRow("复习次数", "\(e.reviewCount)")
                    metaRow("下次复习", nextReviewText(e))
                    metaRow("来源应用", e.sourceApp.isEmpty ? "—" : e.sourceApp)
                    metaRow("翻译服务", e.provider.isEmpty ? "—" : e.provider)
                    metaRow("收录时间", dateText(e.createdAt))
                }
                .font(.system(size: 11))

                // 窄栏里一行放不下 5 个带文字的按钮，拆成两行
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        actionButton("朗读", "speaker.wave.2") { speak(e.term) }
                        actionButton("复制", "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(e.term)\t\(e.translation)", forType: .string)
                            toast = "已复制"
                        }
                        actionButton(e.starred ? "取消收藏" : "收藏", e.starred ? "star.slash" : "star") {
                            store.toggleStar(e)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        actionButton(e.mastered ? "取消掌握" : "已掌握", "checkmark.seal") {
                            store.toggleMastered(e)
                        }
                        Spacer(minLength: 0)
                        deleteButton(e)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .fixedSize()
        }
        .controlSize(.small)
    }

    private func deleteButton(_ e: VocabEntry) -> some View {
        Button(role: .destructive) {
            store.delete(e)
            selectedID = nil
        } label: {
            Label("删除", systemImage: "trash")
                .font(.system(size: 11))
                .fixedSize()
        }
        .controlSize(.small)
    }

    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(key)
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func nextReviewText(_ e: VocabEntry) -> String {
        if e.mastered { return "已掌握" }
        let interval = e.dueAt.timeIntervalSinceNow
        if interval <= 0 { return "现在" }
        let days = Int(interval / 86_400)
        if days >= 1 { return "\(days) 天后" }
        let hours = Int(interval / 3600)
        if hours >= 1 { return "\(hours) 小时后" }
        return "\(max(1, Int(interval / 60))) 分钟后"
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    private func speak(_ text: String) {
        SpeechKeeper.shared.speak(text)
    }
}

// MARK: - 熟练度

struct StrengthDots: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < level ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

// MARK: - 复习

@MainActor
struct ReviewPane: View {
    let onExit: () -> Void
    @ObservedObject private var store = VocabularyStore.shared

    @State private var queue: [VocabEntry] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var done = 0

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("复习模式").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(min(index, queue.count)) / \(queue.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("退出") { onExit() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if index >= queue.count {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("本轮复习完成").font(.system(size: 16, weight: .medium))
                    Text("复习了 \(done) 个词").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("再来一轮") { start() }
                        .controlSize(.regular)
                        .padding(.top, 6)
                }
            } else {
                let entry = queue[index]
                VStack(spacing: 16) {
                    Text(entry.term)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    if !entry.phonetic.isEmpty {
                        Text("/\(entry.phonetic)/")
                            .font(.system(size: 13, design: .serif))
                            .foregroundStyle(.secondary)
                    }

                    if revealed {
                        VStack(spacing: 10) {
                            Text(entry.translation)
                                .font(.system(size: 18))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            if !entry.example.isEmpty {
                                Text(entry.example)
                                    .font(.system(size: 12))
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: 420)
                        .padding(.top, 6)

                        HStack(spacing: 12) {
                            reviewButton("忘了", color: .red, quality: 0)
                            reviewButton("模糊", color: .orange, quality: 1)
                            reviewButton("记得", color: .green, quality: 2)
                        }
                        .padding(.top, 8)
                    } else {
                        Button("显示答案") {
                            withAnimation(.easeOut(duration: 0.15)) { revealed = true }
                        }
                        .controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()
        }
        .onAppear { start() }
    }

    private func reviewButton(_ title: String, color: Color, quality: Int) -> some View {
        Button {
            let entry = queue[index]
            store.review(entry, quality: quality)
            done += 1
            withAnimation {
                index += 1
                revealed = false
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 76, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.15)))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    private func start() {
        queue = store.entries.filter { $0.isDue }.shuffled()
        if queue.isEmpty { queue = store.entries.shuffled().prefix(15).map { $0 } }
        index = 0
        revealed = false
        done = 0
    }
}
