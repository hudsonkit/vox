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
    private var levelTask: Task<Void, Never>?

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

        // Clickable only while the stop and cancel controls are showing.
        if case .listening = phase {
            panel?.ignoresMouseEvents = false
        } else {
            panel?.ignoresMouseEvents = true
        }

        switch phase {
        case .listening, .transcribing:
            startMetering()
        case .idle, .finished:
            stopMetering()
        }

        if phase == .idle {
            hide()
        } else {
            show()
        }
    }

    private func startMetering() {
        guard levelTask == nil else { return }
        presentation.history = []
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let presentation = self.presentation
                let isListening: Bool
                if case .listening = presentation.phase { isListening = true } else { isListening = false }

                let level = isListening ? CGFloat(await self.model.currentInputLevel()) : 0
                // Snap up on a syllable, drop quickly between them.
                let shaped = pow(level, 0.45)
                let rate: CGFloat = shaped > presentation.level ? 0.7 : 0.22
                presentation.level += (shaped - presentation.level) * rate

                // One column per frame. Jumps up on a syllable, falls back
                // slowly, and never drops below a low murmur, so words flow
                // into each other instead of standing as separate blocks.
                if isListening {
                    let previous = presentation.history.last ?? 0
                    let envelope = shaped > previous ? previous + (shaped - previous) * 0.65 : previous + (shaped - previous) * 0.09
                    presentation.history.append(max(envelope, CGFloat.random(in: 0.06...0.22)))
                    if presentation.history.count > MinivoxNotchPresentation.historyLimit {
                        presentation.history.removeFirst(presentation.history.count - MinivoxNotchPresentation.historyLimit)
                    }
                }

                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopMetering() {
        levelTask?.cancel()
        levelTask = nil
        presentation.level = 0
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
        if case .listening = presentation.phase {
            panel.ignoresMouseEvents = false
        }
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
        panel.contentView = MinivoxNotchHostingView(rootView: MinivoxNotchView(
            presentation: presentation,
            onStop: { [weak model] in
                if model?.isRecording == true { model?.toggleRecording() }
            },
            onCancel: { [weak model] in model?.cancelRecording() }
        ))
        return panel
    }
}

/// The panel never becomes key, so the first click must reach the controls.
private final class MinivoxNotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    /// Smoothed microphone level, 0...1.
    @Published var level: CGFloat = 0
    /// Recent levels, oldest first, one per frame (~60 a second).
    @Published var history: [CGFloat] = []
    static let historyLimit = 240
    @Published var metrics = MinivoxNotchMetrics.island(height: 24)
}

private struct MinivoxNotchMetrics: Equatable {
    /// Width hidden by the camera housing. Zero on displays without one.
    var housingWidth: CGFloat
    var height: CGFloat
    var wingWidth: CGFloat = 100
    var shoulder: CGFloat = 6
    /// How far the notch drops below the housing to show the wave.
    var drop: CGFloat = 34

    static func island(height: CGFloat) -> MinivoxNotchMetrics {
        MinivoxNotchMetrics(housingWidth: 0, height: height, wingWidth: 106)
    }

    init(housingWidth: CGFloat, height: CGFloat, wingWidth: CGFloat = 100) {
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
            y: screen.frame.maxY - height - drop,
            width: openWidth,
            height: height + drop
        )
    }
}

private struct MinivoxNotchView: View {
    @ObservedObject var presentation: MinivoxNotchPresentation
    var onStop: () -> Void
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    /// 0 → 1 as the finished line draws into a dot.
    @State private var collapse: CGFloat = 0
    /// The dot's presence: in, then eased out.
    @State private var dot: CGFloat = 0

    private static let inset: CGFloat = 12

    private var metrics: MinivoxNotchMetrics { presentation.metrics }

    private var outcome: DictationOutcome? {
        if case .finished(let outcome) = presentation.phase { return outcome }
        return nil
    }
    private var isOpen: Bool { presentation.isOpen }

    /// Listening and transcribing drop a wave below the housing.
    private var isLive: Bool {
        guard isOpen else { return false }
        switch presentation.phase {
        case .listening, .transcribing, .finished: return true
        case .idle: return false
        }
    }

    private var isListening: Bool {
        if case .listening = presentation.phase { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Frosted and see-through, except over the camera housing, which
            // stays solid so the surface still reads as the notch.
            let shape = MinivoxNotchShape(shoulder: metrics.shoulder, bottomRadius: (isLive ? 14 : metrics.height * 0.36))
            shape.fill(.ultraThinMaterial)
            shape.fill(.black.opacity(0.58))
            Rectangle()
                .fill(.black)
                .frame(width: metrics.housingWidth, height: metrics.height)

            VStack(spacing: 0) {
                // Shares the wave row's inset, so text edges meet the control edges.
                HStack(spacing: 0) {
                    leading
                        .frame(width: metrics.wingWidth - Self.inset, alignment: .leading)
                    Spacer(minLength: metrics.housingWidth)
                    trailing
                        .frame(width: metrics.wingWidth - Self.inset, alignment: .trailing)
                }
                .padding(.horizontal, Self.inset)
                .frame(height: metrics.height)

                HStack(spacing: 12) {
                    NotchControl(symbol: "xmark", label: "Cancel", tint: .white.opacity(0.6), action: onCancel)
                        .opacity(isListening ? 1 : 0)
                    wave
                    NotchControl(symbol: "stop.fill", label: "Stop", tint: NotchTokens.amber, action: onStop)
                        .opacity(isListening ? 1 : 0)
                }
                .frame(height: metrics.drop)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, 4)
                .opacity(isLive ? 1 : 0)
            }
            .padding(.horizontal, metrics.shoulder)
            .opacity(isOpen ? 1 : 0)
            .blur(radius: isOpen || reduceMotion ? 0 : 3)
            .animation(.easeOut(duration: 0.18).delay(isOpen ? 0.09 : 0), value: isOpen)
        }
        .frame(
            width: isOpen ? metrics.openWidth : metrics.closedWidth,
            height: metrics.height + (isLive ? metrics.drop : 0),
            alignment: .top
        )
        .clipped()
        .opacity(metrics.housingWidth == 0 && !isOpen ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(openAnimation, value: isOpen)
        .animation(openAnimation, value: isLive)
        .animation(.easeInOut(duration: 0.18), value: presentation.phase)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: outcome) { _, outcome in
            guard outcome != nil else {
                collapse = 0
                dot = 0
                return
            }
            // The line draws into the center, becomes a dot, and the dot eases out.
            withAnimation(.easeIn(duration: reduceMotion ? 0.01 : 0.34)) { collapse = 1 }
            withAnimation(.easeOut(duration: 0.12).delay(0.26)) { dot = 1 }
            withAnimation(.easeOut(duration: 0.55).delay(0.62)) { dot = 2 }
        }
    }

    private var openAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return isOpen
            ? .spring(response: 0.38, dampingFraction: 0.72)
            : .spring(response: 0.3, dampingFraction: 0.95)
    }

    /// Scrolling dot-matrix meter: newest sample at the right edge, one
    /// column per frame, lit outward from the center row. Unlit dots stay
    /// faintly visible so the grid always reads. Dims while transcribing.
    private var wave: some View {
        let history = presentation.history
        let tint = NotchTokens.amber
        return Canvas { context, size in
            let pixel = 1 / max(displayScale, 1)
            let snap = { (value: CGFloat) in (value / pixel).rounded() * pixel }
            let pitch: CGFloat = 3
            let dot: CGFloat = 1.5

            var rows = Int(size.height / pitch)
            if rows.isMultiple(of: 2) { rows -= 1 }
            let half = rows / 2
            let columns = Int(size.width / pitch)
            let top = snap((size.height - CGFloat(rows) * pitch) / 2)

            func cell(_ column: Int, _ row: Int) -> CGRect {
                CGRect(
                    x: snap(size.width - CGFloat(column + 1) * pitch),
                    y: snap(top + CGFloat(row) * pitch),
                    width: dot,
                    height: dot
                )
            }

            var unlit = Path()
            for column in 0..<columns {
                let level = column < history.count ? history[history.count - 1 - column] : 0
                let lit = column < history.count ? Int((level * CGFloat(half)).rounded()) : -1
                let age = CGFloat(column) / CGFloat(max(columns, 1))
                let strength = 0.9 - age * 0.7
                for row in 0..<rows {
                    let distance = abs(row - half)
                    if distance <= lit {
                        // Brightest at the center, softer toward the column's tips.
                        let falloff = 1 - 0.55 * CGFloat(distance) / CGFloat(lit + 1)
                        context.fill(Path(cell(column, row)), with: .color(tint.opacity(strength * falloff)))
                    } else {
                        unlit.addRect(cell(column, row))
                    }
                }
            }
            context.fill(unlit, with: .color(.white.opacity(0.06)))
        }
        .opacity(isListening ? 1 : 0.35)
        .scaleEffect(x: max(0.001, 1 - collapse), y: 1)
        .opacity(1 - collapse)
        .overlay {
            Circle()
                .fill(outcome?.dotColor ?? tint)
                .frame(width: 3.5, height: 3.5)
                .scaleEffect(dot <= 1 ? 0.4 + dot * 0.6 : 1 - (dot - 1) * 0.5)
                .opacity(dot <= 1 ? dot : 2 - dot)
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch presentation.phase {
        case .idle, .listening:
            HStack(spacing: 5) {
                Circle()
                    .fill(NotchTokens.rec)
                    .frame(width: 5, height: 5)
                    .shadow(color: NotchTokens.rec.opacity(0.3 + presentation.level * 0.5), radius: 1 + presentation.level * 2)
                Text("REC")
                    .foregroundStyle(NotchTokens.rec.opacity(0.8))
            }
            .font(NotchTokens.mono)
        case .transcribing:
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(NotchTokens.amber.opacity(0.55))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        Group {
            switch presentation.phase {
            case .idle:
                EmptyView()
            case .listening(let since):
                TimelineView(.animation(minimumInterval: 0.1)) { context in
                    Text(Self.elapsed(since: since, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            case .transcribing:
                Text("…")
                    .foregroundStyle(.white.opacity(0.45))
            case .finished:
                EmptyView()
            }
        }
        .font(NotchTokens.mono)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// "0:03.4": tenths make the clock feel live.
    private static func elapsed(since start: Date, now: Date) -> String {
        let tenths = max(0, Int(now.timeIntervalSince(start) * 10))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
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

private enum NotchTokens {
    static let amber = Color(red: 232 / 255, green: 154 / 255, blue: 60 / 255)
    static let rec = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let mono = Font.system(size: 10.5, weight: .thin, design: .monospaced)
}

/// A flowing sum of sines, tapered to zero at both ends.
/// A small round button in the notch's lower band.
private struct NotchControl: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 6.5, weight: .medium))
                .foregroundStyle(tint.opacity(isHovering ? 1 : 0.7))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(isHovering ? 0.12 : 0.04)))
                .overlay(Circle().strokeBorder(.white.opacity(isHovering ? 0.22 : 0.08), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
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

    var dotColor: Color {
        switch self {
        case .pasted, .copied: NotchTokens.amber
        case .noSpeech: .white.opacity(0.45)
        case .failed: NotchTokens.rec
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
