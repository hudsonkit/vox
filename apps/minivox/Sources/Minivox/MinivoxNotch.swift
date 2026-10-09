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
    private var previewObserver: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    init(model: MinivoxModel) {
        self.model = model
        phaseObserver = model.$dictationPhase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.update(for: phase)
            }
        previewObserver = model.$livePreview
            .combineLatest(model.$hasLivePreview)
            .sink { [presentation] text, hasPreview in
                presentation.words = text
                presentation.hasPreview = hasPreview
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
                // The level is already in dB (-50...0 → 0...1). Gate room noise
                // below about -42 dB and stretch above it, so a quiet room sits
                // near the floor and speech climbs well up the meter.
                let shaped = max(0, min(1, (level - 0.16) / 0.66))
                // Snap up on a syllable, drop quickly between them.
                let rate: CGFloat = shaped > presentation.level ? 0.85 : 0.35
                presentation.level += (shaped - presentation.level) * rate
                let glowRate: CGFloat = shaped > presentation.glow ? 0.3 : 0.1
                presentation.glow += (shaped - presentation.glow) * glowRate

                // One column per frame. Jumps up on a syllable, falls back
                // slowly, and never drops below a low murmur, so words flow
                // into each other instead of standing as separate blocks.
                if isListening {
                    let previous = presentation.history.last ?? 0
                    let envelope = shaped > previous ? previous + (shaped - previous) * 0.9 : previous + (shaped - previous) * 0.3
                    presentation.history.append(max(envelope, CGFloat.random(in: 0.02...0.09)))
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
        presentation.glow = 0
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
    /// A slower, softer copy of `level` for the glow behind the meter.
    @Published var glow: CGFloat = 0
    /// Recent levels, oldest first, one per frame (~60 a second).
    @Published var history: [CGFloat] = []
    static let historyLimit = 240
    @Published var metrics = MinivoxNotchMetrics.island(height: 24)
    /// Running live transcript, newest word last.
    @Published var words = ""
    @Published var hasPreview = false
}

private struct MinivoxNotchMetrics: Equatable {
    /// Width hidden by the camera housing. Zero on displays without one.
    var housingWidth: CGFloat
    var height: CGFloat
    var wingWidth: CGFloat = 165
    var shoulder: CGFloat = 6
    /// The row with cancel, the meter and stop.
    var meterHeight: CGFloat = 19
    /// The clock and streaming words, under the meter.
    var infoHeight: CGFloat = 18
    var bottomPadding: CGFloat = 4
    /// Clear room around the surface for its shadow.
    static let shadowMargin: CGFloat = 16

    static func island(height: CGFloat) -> MinivoxNotchMetrics {
        MinivoxNotchMetrics(housingWidth: 0, height: height, wingWidth: 160)
    }

    /// The REC and clock row: the wings beside the camera housing, or a short
    /// row of its own on an island without one.
    var housingHeight: CGFloat { housingWidth > 0 ? height : 16 }

    func drop(withWords: Bool) -> CGFloat {
        meterHeight + (withWords ? infoHeight : 0) + bottomPadding
    }

    init(housingWidth: CGFloat, height: CGFloat, wingWidth: CGFloat = 165) {
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
        let margin = Self.shadowMargin
        return NSRect(
            x: screen.frame.midX - openWidth / 2 - margin,
            y: screen.frame.maxY - housingHeight - drop(withWords: true) - margin,
            width: openWidth + margin * 2,
            height: housingHeight + drop(withWords: true) + margin
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
    /// Measured width of the running words, to tell when they overflow.
    @State private var wordsWidth: CGFloat = 0

    private static let inset: CGFloat = 9

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

    /// The words row opens once there is something to show, so the notch
    /// stays two lines until the first word lands.
    private var showsWords: Bool {
        presentation.hasPreview && !presentation.words.isEmpty
    }

    private var isListening: Bool {
        if case .listening = presentation.phase { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            surface

            VStack(spacing: 0) {
                // Two lines: REC and the clock in the wings beside the camera,
                // then cancel, the meter and stop in one thin row below.
                HStack(spacing: 0) {
                    rec
                    Spacer(minLength: metrics.housingWidth)
                    clock
                }
                // The REC dot sits right above the center of the cancel control.
                .padding(.leading, Self.inset + NotchTokens.controlSize / 2 - NotchTokens.recDot / 2)
                .padding(.trailing, Self.inset + 2)
                .padding(.bottom, 1)
                // Sit low in the wings, right on top of the meter.
                .frame(height: metrics.housingHeight, alignment: .bottom)

                HStack(spacing: 6) {
                    NotchControl(label: "Cancel", action: onCancel, isShown: isListening) {
                        NotchCross()
                            .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
                            .frame(width: 4, height: 4)
                    }
                    wave
                        .frame(height: 16)
                    NotchControl(label: "Stop and paste", action: onStop, isShown: isListening) {
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(NotchTokens.amber.opacity(0.7))
                            .frame(width: 4, height: 4)
                    }
                }
                .padding(.horizontal, Self.inset)
                .frame(height: metrics.meterHeight)

                if showsWords {
                    words
                        .padding(.horizontal, Self.inset + 3)
                        .frame(height: metrics.infoHeight)
                        .opacity(outcome == nil ? 1 : 0)
                        // Settle in just behind the edge as the notch grows to fit.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -5))
                                .animation(.easeOut(duration: 0.28).delay(0.06)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))
                        ))
                }
            }
            .padding(.horizontal, metrics.shoulder)
            .opacity(isLive ? 1 : 0)
            .blur(radius: isOpen || reduceMotion ? 0 : 3)
            .animation(.easeOut(duration: 0.18).delay(isOpen ? 0.09 : 0), value: isOpen)
        }
        .frame(
            width: isOpen ? metrics.openWidth : metrics.closedWidth,
            height: metrics.housingHeight + (isLive ? metrics.drop(withWords: showsWords) : 0),
            alignment: .top
        )
        .clipped()
        // Outside the clip so the shadow can fall past the edge.
        .background(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(isLive ? 0.45 : 0), radius: 9, y: 4)
                .mask {
                    Rectangle()
                        .padding(-MinivoxNotchMetrics.shadowMargin)
                        .overlay(shape.blendMode(.destinationOut))
                        .compositingGroup()
                }
        }
        .opacity(metrics.housingWidth == 0 && !isOpen ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(openAnimation, value: isOpen)
        .animation(openAnimation, value: isLive)
        // The second line opens with the same soft spring, no overshoot.
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.92), value: showsWords)
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

    private var shape: MinivoxNotchShape {
        MinivoxNotchShape(shoulder: metrics.shoulder, bottomRadius: isLive ? 15 : metrics.height * 0.36)
    }

    /// Pure black where it meets the camera housing, lifting a hair toward
    /// the bottom, with a hairline edge that catches light only below the
    /// housing and a warm glow from the meter that follows the voice.
    private var surface: some View {
        let lit = metrics.housingHeight / max(metrics.housingHeight + metrics.drop(withWords: showsWords), 1)
        return ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(LinearGradient(
                stops: [
                    .init(color: .black, location: lit),
                    .init(color: .black.opacity(0.62), location: min(1, lit + 0.2)),
                    .init(color: NotchTokens.lift.opacity(0.55), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            RadialGradient(
                colors: [NotchTokens.amber.opacity(0.22), NotchTokens.amber.opacity(0)],
                center: .bottom, startRadius: 0, endRadius: metrics.openWidth * 0.42
            )
            .opacity(isListening ? 0.06 + presentation.glow * 0.6 : 0)
            .clipShape(shape)
            shape
                .stroke(lineWidth: 1)
                .fill(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: lit * 0.85),
                        .init(color: .white.opacity(0.07), location: 0.75),
                        .init(color: .white.opacity(0.13), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .opacity(isLive ? 1 : 0)
        }
    }

    private var rec: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(NotchTokens.rec)
                .frame(width: NotchTokens.recDot, height: NotchTokens.recDot)
                .shadow(color: NotchTokens.rec.opacity(0.9), radius: 2.5)
            Text("REC")
                .tracking(0.8)
                .foregroundStyle(NotchTokens.rec.opacity(0.85))
        }
        .font(NotchTokens.label)
        .opacity(isListening ? 1 : 0)
    }

    /// A hundredths clock: "0:03.42".
    @ViewBuilder
    private var clock: some View {
        if case .listening(let since) = presentation.phase {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                Text(Self.elapsed(since: since, now: context.date))
                    .monospacedDigit()
            }
            .font(NotchTokens.mono)
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// The live transcript as a stream that reads left to right: words fill
    /// in from the left edge, and once the row is full the line glides left
    /// to make room, older words dimming and fading out under the left edge.
    private var words: some View {
        let all = presentation.words.split(separator: " ")
        let shown = all.suffix(24)
        let first = all.count - shown.count
        let items = shown.enumerated().map { (id: first + $0.offset, text: String($0.element)) }
        let newest = all.count - 1
        return HStack(spacing: 3.5) {
            ForEach(items, id: \.id) { item in
                let age = newest - item.id
                Text(item.text)
                    .foregroundStyle(.white.opacity(age == 0 ? 1 : max(0.3, 0.78 - Double(age) * 0.045)))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 8)),
                        removal: .opacity
                    ))
            }
        }
        .font(NotchTokens.words)
        .lineLimit(1)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { wordsWidth = $0 }
        // Short lines sit at the left; a full line pins its newest word to the right.
        .frame(minWidth: wordsRowWidth, alignment: .leading)
        // minWidth 0 keeps the row at the notch's width; without it the
        // frame grows to the text and pushes the whole HUD out of shape.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .mask {
            // Fade the left edge only once words are scrolling under it.
            LinearGradient(
                stops: [.init(color: wordsOverflow ? .clear : .black, location: 0), .init(color: .black, location: 0.22)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .opacity(isListening ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9), value: all.count)
    }

    /// The words row's width inside the notch's insets.
    private var wordsRowWidth: CGFloat {
        max(0, metrics.openWidth - metrics.shoulder * 2 - (Self.inset + 3) * 2)
    }

    private var wordsOverflow: Bool { wordsWidth > wordsRowWidth }

    private var openAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        return isOpen
            ? .spring(response: 0.38, dampingFraction: 0.72)
            : .spring(response: 0.3, dampingFraction: 0.95)
    }

    /// Scrolling dot-matrix meter: newest sample at the right edge, one
    /// column per frame, lit outward from the center row. Unlit dots nearly
    /// vanish into the black, with a faint halo just past the lit ones, and
    /// both ends fade out. Dims while transcribing.
    private var wave: some View {
        let history = presentation.history
        let tint = NotchTokens.amber
        return Canvas { context, size in
            let pixel = 1 / max(displayScale, 1)
            let snap = { (value: CGFloat) in (value / pixel).rounded() * pixel }
            let pitch: CGFloat = 2.2
            let dot: CGFloat = 1.15
            let grid: CGFloat = 0.012
            let halo: CGFloat = 0.14
            let fade = size.width * 0.16

            var rows = Int(size.height / pitch)
            if rows.isMultiple(of: 2) { rows -= 1 }
            let half = rows / 2
            let columns = Int(size.width / pitch)
            let top = snap((size.height - CGFloat(rows) * pitch) / 2)

            for column in 0..<columns {
                let x = snap(size.width - CGFloat(column + 1) * pitch)
                let ends = min(1, x / fade, (size.width - x) / fade)
                guard ends > 0 else { continue }
                let has = column < history.count
                let level = has ? history[history.count - 1 - column] : 0
                // Whole dots up to the level, then the next dot partly lit by
                // the remainder, so loudness reads as a gradient, not steps.
                let exact = level * CGFloat(half)
                let lit = has ? Int(exact) : -1
                let tip = has ? exact - CGFloat(lit) : 0
                let age = CGFloat(column) / CGFloat(max(columns, 1))
                let strength = 0.9 - age * 0.7
                for row in 0..<rows {
                    let distance = abs(row - half)
                    let rect = CGRect(x: x, y: snap(top + CGFloat(row) * pitch), width: dot, height: dot)
                    if distance <= lit {
                        // Brightest at the center, softer toward the column's tips.
                        let falloff = 1 - 0.55 * CGFloat(distance) / CGFloat(lit + 1)
                        context.fill(Path(rect), with: .color(tint.opacity(strength * falloff * ends)))
                    } else if distance == lit + 1, tip > 0.05 {
                        let falloff = 1 - 0.55 * CGFloat(distance) / CGFloat(lit + 2)
                        context.fill(Path(rect), with: .color(tint.opacity(strength * falloff * ends * tip)))
                    } else {
                        let glow = has ? halo * strength * max(0, 1 - CGFloat(distance - lit - 1) / 2) : 0
                        context.fill(Path(rect), with: .color(.white.opacity((grid + glow) * ends)))
                    }
                }
            }
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

    /// "0:03.42": hundredths make the clock feel live.
    private static func elapsed(since start: Date, now: Date) -> String {
        let hundredths = max(0, Int(now.timeIntervalSince(start) * 100))
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
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
    /// Cancel and stop, and the REC dot that lines up above cancel.
    static let controlSize: CGFloat = 15
    static let recDot: CGFloat = 4
    /// The surface's lowest edge: black lifted just enough to read as a material.
    static let lift = Color(white: 0.075)
    /// The clock. Light weight, whole point sizes throughout.
    static let mono = Font.system(size: 10, weight: .light, design: .monospaced)
    /// Small caps-style labels such as REC.
    static let label = Font.system(size: 9, weight: .light, design: .monospaced)
    /// Running words read better proportional.
    static let words = Font.system(size: 12, weight: .light)
}

/// A light round control laid over the meter: a hairline ring and a
/// faint dark wash, so the dots stay visible underneath.
private struct NotchControl<Glyph: View>: View {
    let label: String
    let action: () -> Void
    var isShown = true
    @ViewBuilder var glyph: Glyph
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .opacity(isHovering ? 1 : 0.8)
                .frame(width: NotchTokens.controlSize, height: NotchTokens.controlSize)
                .background(Circle().fill(.black.opacity(isHovering ? 0.55 : 0.35)))
                .overlay(Circle().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(isHovering ? 0.32 : 0.16), .white.opacity(isHovering ? 0.1 : 0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.5
                ))
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NotchCross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
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
