import Cocoa
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Mode: Equatable { case hidden, listening, handsFree, processing, notice(String) }

    static let barCount = 16

    @Published var mode: Mode = .hidden
    @Published var levels = [CGFloat](repeating: 0, count: barCount)
    @Published var preview = ""
    @Published var showPreview = true
}

/// Never takes key focus, so keystrokes and the paste keep going to the app being dictated into.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating pill at the bottom of the screen.
final class OverlayController {
    let model = OverlayModel()
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private static let size = NSSize(width: 520, height: 160)
    private let panel: OverlayPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let view = OverlayView(model: model,
                               onStop: { [weak self] in self?.onStop?() },
                               onCancel: { [weak self] in self?.onCancel?() })
        panel.contentView = FirstClickHostingView(rootView: view)
    }

    /// Clears the previous dictation's waveform and preview and moves the pill to the active screen.
    func reset(showPreview: Bool) {
        model.levels = [CGFloat](repeating: 0, count: OverlayModel.barCount)
        model.preview = ""
        model.showPreview = showPreview
        position()
    }

    func show(_ mode: OverlayModel.Mode) {
        hideWork?.cancel()
        if !panel.isVisible { position() }
        // Only hands-free mode has buttons; otherwise clicks fall through to the app below.
        panel.ignoresMouseEvents = mode != .handsFree
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { model.mode = mode }
        panel.orderFrontRegardless()
    }

    func flash(_ message: String, seconds: Double = 1.6) {
        show(.notice(message))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { model.mode = .hidden }
        let work = DispatchWorkItem { [weak self] in
            if self?.model.mode == .hidden { self?.panel.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func push(level: Float) {
        var levels = model.levels
        levels.removeFirst()
        levels.append(CGFloat(level))
        model.levels = levels
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 8))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let onStop: () -> Void
    let onCancel: () -> Void

    private var isActive: Bool {
        switch model.mode {
        case .listening, .handsFree, .processing: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if model.showPreview && isActive && !model.preview.isEmpty {
                Text(Self.tail(of: model.preview))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.8)))
                    .frame(maxWidth: 460)
                    .transition(.opacity)
            }
            if model.mode != .hidden {
                pill.transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
    }

    /// The last ~110 characters, cut at a word boundary: as much as fits on two lines.
    static func tail(of text: String, limit: Int = 110) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    private var pill: some View {
        HStack(spacing: 8) {
            if model.mode == .handsFree { roundButton("xmark", tint: .white, action: onCancel) }
            content
            if model.mode == .handsFree { roundButton("stop.fill", tint: Color(red: 1, green: 0.36, blue: 0.36), action: onStop) }
        }
        .padding(.horizontal, model.mode == .handsFree ? 6 : 14)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .listening, .handsFree:
            Waveform(levels: model.levels)
        case .processing:
            ProcessingDots()
        case .notice(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .fixedSize()
        case .hidden:
            EmptyView()
        }
    }

    private func roundButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

private struct Waveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(Color.white).frame(width: 3, height: 3 + level * 19)
            }
        }
        .frame(width: 96, height: 24)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 8 - Double(index) * 0.9)))
                }
            }
            .frame(width: 96, height: 24)
        }
    }
}
