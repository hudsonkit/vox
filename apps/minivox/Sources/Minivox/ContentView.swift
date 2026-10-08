import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: MinivoxModel

    @AppStorage("minivox.appearance") private var appearanceRawValue = MinivoxAppearance.system.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var page: Page = .dictation

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch page {
                case .dictation:
                    VStack(spacing: 0) {
                        actionRow
                        transcript
                        footer
                    }
                    .transition(.opacity)

                case .history:
                    MinivoxHistoryView(model: model)
                        .transition(.opacity)

                case .settings:
                    MinivoxSettingsView(model: model)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 336)
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(PopoverWindowConfiguration(colorScheme: effectiveColorScheme))
        .environment(\.colorScheme, effectiveColorScheme)
        .preferredColorScheme(selectedAppearance.colorScheme)
        .animation(.easeOut(duration: 0.14), value: page)
        .task {
            model.loadIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page == .dictation {
                MinivoxLogo(palette: palette, size: 27)

                Text("Minivox")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .tracking(-0.2)
            } else {
                Button {
                    page = .dictation
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 25, height: 25)
                        .background(palette.controlSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back")

                Text(page.title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
            }

            Spacer(minLength: 0)

            if page == .dictation {
                HStack(spacing: 6) {
                    if model.isWorking || model.isWarmingASR {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(palette.accent)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                    }

                    Text(statusTitle)
                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(palette.controlSurface, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 0.5)
                }
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Quit Minivox")
        }
        .padding(.horizontal, 13)
        .frame(height: 52)
        .background(palette.strip)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button(action: model.toggleRecording) {
                ZStack {
                    Circle()
                        .fill(palette.recessed)

                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    palette.accent.opacity(model.isRecording ? 0.9 : 0.42),
                                    Color.primary.opacity(0.06),
                                    palette.accent.opacity(model.isRecording ? 0.48 : 0.12),
                                    Color.primary.opacity(0.12),
                                    palette.accent.opacity(model.isRecording ? 0.9 : 0.42),
                                ],
                                center: .center
                            ),
                            lineWidth: model.isRecording ? 1.2 : 0.8
                        )

                    ForEach(0..<12, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(
                                index.isMultiple(of: 3)
                                    ? palette.accent.opacity(model.isRecording ? 0.72 : 0.3)
                                    : Color.primary.opacity(0.1)
                            )
                            .frame(width: 0.7, height: 2.3)
                            .offset(y: -19.5)
                            .rotationEffect(.degrees(Double(index) * 30))
                    }

                    Circle()
                        .fill(model.isRecording ? palette.accent.opacity(0.075) : palette.card)
                        .frame(width: 35, height: 35)

                    Circle()
                        .strokeBorder(palette.border, lineWidth: 0.5)
                        .frame(width: 35, height: 35)

                    if !model.isRecording && (model.isWorking || model.isWarmingASR) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(palette.accent)
                    } else {
                        Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(model.isRecording ? palette.accent : Color.primary)
                    }
                }
                .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(!model.isRecording && (model.isWorking || model.isWarmingASR))
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isRecording ? "Finish dictation" : "Start dictation")

            VStack(alignment: .leading, spacing: 3) {
                Text(actionTitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))

                Text(actionDetail)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if model.didCopy && !model.transcript.isEmpty {
                Text(model.didPaste ? "Pasted" : "Copied")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(palette.controlSurface, in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 0.5)
                    }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 82)
        .background(palette.card)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if model.transcript.isEmpty {
                    Text("Transcription")
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView(showsIndicators: false) {
                        Text(model.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.system(size: 13.5, weight: .regular, design: .rounded))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 92, alignment: .topLeading)

            if let message = visibleMessage {
                Text(message)
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(model.lastErrorMessage == nil ? Color.secondary : Color.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.background)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.loadHistory()
                page = .history
            } label: {
                Label("History", systemImage: "clock")
            }
            .buttonStyle(MinivoxRailButtonStyle(palette: palette))

            Button {
                page = .settings
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(MinivoxRailButtonStyle(palette: palette))

            Spacer(minLength: 0)

            if !model.asrReadyInMemory {
                Button {
                    model.warmASR()
                } label: {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.isRecording || model.isWorking || model.isWarmingASR)
                .help("Warm up Parakeet")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(palette.strip)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 0.5)
        }
    }

    private var actionTitle: String {
        if model.isRecording { return "Listening" }
        if model.isWarmingASR { return "Warming" }
        if model.isWorking { return "Transcribing" }
        if model.didCopy && !model.transcript.isEmpty { return "Transcribed" }
        return "Ready"
    }

    private var actionDetail: String {
        if model.isRecording { return "Speak" }
        if model.isWarmingASR { return "Loading Parakeet" }
        if model.isWorking { return "Working locally" }
        if model.didPaste { return "Inserted in active app" }
        if model.didCopy && !model.transcript.isEmpty { return "Ready in clipboard" }
        return "Click or press shortcut"
    }

    private var statusTitle: String {
        if model.isRecording { return "Live" }
        if model.isWarmingASR { return "Warm" }
        if model.isWorking { return "Work" }
        if model.asrReadyInMemory { return "Ready" }
        return "Cold"
    }

    private var statusColor: Color {
        if model.isRecording { return .red }
        if model.asrReadyInMemory { return palette.accent }
        return .secondary
    }

    private var visibleMessage: String? {
        if let error = model.lastErrorMessage, !error.isEmpty {
            return error
        }

        let message = model.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private var selectedAppearance: MinivoxAppearance {
        MinivoxAppearance(rawValue: appearanceRawValue) ?? .system
    }

    private var effectiveColorScheme: ColorScheme {
        selectedAppearance.colorScheme ?? systemColorScheme
    }

    private var palette: MinivoxPalette {
        MinivoxPalette(colorScheme: effectiveColorScheme)
    }

    private enum Page: Equatable {
        case dictation
        case history
        case settings

        var title: String {
            switch self {
            case .dictation: "Minivox"
            case .history: "History"
            case .settings: "Settings"
            }
        }
    }
}

private struct PopoverWindowConfiguration: NSViewRepresentable {
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.hasShadow = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.titled)
            window.appearance = NSAppearance(
                named: colorScheme == .dark ? .darkAqua : .aqua
            )

            guard let frameView = window.contentView?.superview else { return }
            frameView.appearance = window.appearance
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.borderWidth = 0
            frameView.layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
