import SwiftUI
import AppKit
import AVFoundation

// MARK: - 毛玻璃背景

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = state
    }
}

// MARK: - 内容高度测量（替代 macOS 15 的 onGeometryChange）

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// macOS 12 上可用的几何高度回调
    func onGeometryChangeCompat(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            action(height)
        }
    }
}

// MARK: - 图标按钮

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var tint: Color = .secondary
    var size: CGFloat = 12
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : (hovering ? Color.primary : tint))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - 小徽章

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}

// MARK: - 朗读

final class SpeechKeeper {
    static let shared = SpeechKeeper()
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String, language: String = "en-US") {
        guard !text.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: language)
        u.rate = 0.46
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
