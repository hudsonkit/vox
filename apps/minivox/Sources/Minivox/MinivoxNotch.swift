import AppKit
import Combine
import SwiftUI

/// A small black surface around the camera housing that follows a dictation:
/// listening, transcribing, then a short result before it tucks away.
/// On a display without a notch it hangs from the top edge as a tab.
@MainActor
final class MinivoxNotchController {
    private let model: MinivoxModel
    private let presentation = MinivoxNotchPresentation()
    private var panel: MinivoxNotchPanel?
    private var phaseObserver: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init(model: MinivoxModel) {
        self.model = model
        phaseObserver = model.$dictationPhase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.update(for: phase)
            }
    }

    private func update(for phase: DictationPhase) {
        presentation.phase = phase

        if phase == .idle {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil

        if panel?.isVisible == true {
            presentation.isOpen = true
            return
        }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let metrics = MinivoxNotchMetrics(screen: screen)
        let panel = panel ?? makePanel()
        presentation.metrics = metrics
        panel.setFrame(metrics.panelFrame(on: screen), display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        // Let the panel land collapsed, then open it so the spring is visible.
        DispatchQueue.main.async { [presentation] in
            presentation.isOpen = true
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        presentation.isOpen = false

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> MinivoxNotchPanel {
        let panel = MinivoxNotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MinivoxNotchView(presentation: presentation))
        return panel
    }
}

private final class MinivoxNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class MinivoxNotchPresentation: ObservableObject {
    @Published var phase: DictationPhase = .idle
    @Published var isOpen = false
    @Published var metrics = MinivoxNotchMetrics.island(height: 24)
}

private struct MinivoxNotchMetrics: Equatable {
    /// Width hidden by the camera housing. Zero on displays without one.
    var housingWidth: CGFloat
    var height: CGFloat
    var wingWidth: CGFloat = 62
    var shoulder: CGFloat = 6

    static func island(height: CGFloat) -> MinivoxNotchMetrics {
        MinivoxNotchMetrics(housingWidth: 0, height: height, wingWidth: 66)
    }

    init(housingWidth: CGFloat, height: CGFloat, wingWidth: CGFloat = 62) {
        self.housingWidth = housingWidth
        self.height = height
        self.wingWidth = wingWidth
    }

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            self.init(
                housingWidth: screen.frame.width - left.width - right.width,
                height: screen.safeAreaInsets.top
            )
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            self = .island(height: max(24, min(menuBarHeight, 32)))
        }
    }

    var openWidth: CGFloat { housingWidth + wingWidth * 2 + shoulder * 2 }
    var closedWidth: CGFloat { housingWidth > 0 ? housingWidth + shoulder * 2 : 0 }

    func panelFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - openWidth / 2,
            y: screen.frame.maxY - height,
            width: openWidth,
            height: height
        )
    }
}

private struct MinivoxNotchView: View {
    @ObservedObject var presentation: MinivoxNotchPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: MinivoxNotchMetrics { presentation.metrics }
    private var isOpen: Bool { presentation.isOpen }

    var body: some View {
        ZStack {
            MinivoxNotchShape(shoulder: metrics.shoulder, bottomRadius: metrics.height * 0.36)
                .fill(.black)

            HStack(spacing: 0) {
                leading
                    .frame(width: metrics.wingWidth)
                Spacer(minLength: metrics.housingWidth)
                trailing
                    .frame(width: metrics.wingWidth)
            }
            .padding(.horizontal, metrics.shoulder)
            .opacity(isOpen ? 1 : 0)
            .blur(radius: isOpen || reduceMotion ? 0 : 3)
            .animation(.easeOut(duration: 0.18).delay(isOpen ? 0.09 : 0), value: isOpen)
        }
        .frame(width: isOpen ? metrics.openWidth : metrics.closedWidth, height: metrics.height)
        .opacity(metrics.housingWidth == 0 && !isOpen ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(openAnimation, value: isOpen)
        .animation(.easeInOut(duration: 0.18), value: presentation.phase)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var openAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return isOpen
            ? .spring(response: 0.38, dampingFraction: 0.72)
            : .spring(response: 0.3, dampingFraction: 0.95)
    }

    @ViewBuilder
    private var leading: some View {
        switch presentation.phase {
        case .idle, .listening:
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
        case .transcribing:
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .finished(let outcome):
            Image(systemName: outcome.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(outcome.tint)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        Group {
            switch presentation.phase {
            case .idle:
                EmptyView()
            case .listening(let since):
                Text(since, style: .timer)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            case .transcribing:
                Text("…")
                    .foregroundStyle(.white.opacity(0.55))
            case .finished(let outcome):
                Text(outcome.title)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var accessibilityLabel: String {
        switch presentation.phase {
        case .idle: return ""
        case .listening: return "Minivox is listening"
        case .transcribing: return "Minivox is transcribing"
        case .finished(let outcome): return "Minivox: \(outcome.title)"
        }
    }
}

private extension DictationOutcome {
    var title: String {
        switch self {
        case .pasted: "Pasted"
        case .copied: "Copied"
        case .noSpeech: "No speech"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .pasted, .copied: "checkmark"
        case .noSpeech: "minus"
        case .failed: "exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .pasted, .copied: .white
        case .noSpeech: .white.opacity(0.55)
        case .failed: .orange
        }
    }
}

/// The notch silhouette: flush with the top edge, concave shoulders where it
/// meets the menu bar, rounded where it hangs below.
private struct MinivoxNotchShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4)
        let r = min(bottomRadius, rect.height - s, (rect.width - s * 2) / 2)
        guard r >= 0, rect.width > s * 2 else { return Path() }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s, y: rect.minY + s),
            control: CGPoint(x: rect.minX + s, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + s + r, y: rect.maxY),
            control: CGPoint(x: rect.minX + s, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.maxY - r),
            control: CGPoint(x: rect.maxX - s, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - s, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
