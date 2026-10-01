import AppKit
import SwiftUI
import Combine

enum HUDState: Equatable {
    case recording
    case transcribing
    case done(String)
    case failed(String)
}

final class HUDModel: ObservableObject {
    @Published var state: HUDState = .recording
    @Published var levels: [Float] = Array(repeating: 0, count: 20)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = Array(repeating: 0, count: levels.count)
    }
}

/// Píldora flotante en la parte inferior de la pantalla, al estilo Wispr Flow.
@MainActor
final class HUDPanel {
    let model = HUDModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ state: HUDState) {
        model.state = state
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
        model.reset()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            indicator
                .frame(width: 18, height: 18)
            content
        }
        .foregroundStyle(.white)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.9))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.state {
        case .recording:
            PulsingDot()
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.5))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording:
            Waveform(levels: model.levels)
                .frame(width: 120, height: 22)
        case .transcribing:
            Text("Transcribiendo…")
        case .done(let preview):
            Text(preview)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
        case .failed(let message):
            Text(message)
                .lineLimit(2)
                .frame(maxWidth: 260)
        }
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: CGFloat(4 + level * 18))
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}

struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.3, blue: 0.3))
            .frame(width: 10, height: 10)
            .scaleEffect(pulse ? 1.25 : 0.9)
            .opacity(pulse ? 1 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
