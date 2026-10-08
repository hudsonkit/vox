import Carbon.HIToolbox
import AppKit
import SwiftUI

enum MinivoxAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct DictationShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String
    /// Only the right Command key triggers it, so the left-hand chord keeps
    /// its usual meaning (⌘M still minimizes).
    let rightCommandOnly: Bool

    init(keyCode: UInt32, modifiers: UInt32, title: String, rightCommandOnly: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.title = title
        self.rightCommandOnly = rightCommandOnly && modifiers & UInt32(cmdKey) != 0
    }

    static let rightCommandM = DictationShortcut(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: UInt32(cmdKey),
        title: "Right ⌘M",
        rightCommandOnly: true
    )

    static let optionSpace = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        title: "⌥Space"
    )

    static let controlSpace = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey),
        title: "⌃Space"
    )

    static let optionShiftSpace = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey | shiftKey),
        title: "⌥⇧Space"
    )

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        var modifierTitle = ""

        if flags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
            modifierTitle += "⌃"
        }
        if flags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
            modifierTitle += "⌥"
        }
        if flags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
            modifierTitle += "⇧"
        }
        if flags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
            modifierTitle += "⌘"
        }

        guard let keyTitle = Self.keyTitle(for: event),
              carbonModifiers != 0 || Self.isFunctionKey(event.keyCode) else {
            return nil
        }

        let deviceFlags = UInt(event.modifierFlags.rawValue)
        let rightCommandOnly = flags.contains(.command)
            && deviceFlags & RightCommandShortcutTap.rightCommandMask != 0
            && deviceFlags & RightCommandShortcutTap.leftCommandMask == 0

        keyCode = UInt32(event.keyCode)
        modifiers = carbonModifiers
        self.rightCommandOnly = rightCommandOnly
        title = (rightCommandOnly ? "Right " : "") + modifierTitle + keyTitle
    }

    private static func keyTitle(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            let value = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return value?.isEmpty == false ? value : nil
        }
    }

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
             kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return true
        default:
            return false
        }
    }
}

enum ShortcutRegistration: Equatable {
    case registered
    case taken
    case needsAccessibility
}

@MainActor
final class GlobalShortcutController {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var rightCommandTap: RightCommandShortcutTap?
    private var tapRetryTimer: Timer?
    private let action: @MainActor @Sendable () -> Void

    /// Called when a right-⌘ shortcut that was waiting on Accessibility goes live.
    var onDeferredRegistration: (@MainActor () -> Void)?

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<GlobalShortcutController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                Task { @MainActor in
                    controller.performAction()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    isolated deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        tapRetryTimer?.invalidate()
    }

    @discardableResult
    func register(_ shortcut: DictationShortcut?) -> ShortcutRegistration {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        rightCommandTap = nil
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil

        guard let shortcut else { return .registered }

        if shortcut.rightCommandOnly {
            return registerRightCommand(shortcut)
        }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4D_56_4F_58, id: 1) // MVOX
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr else { return .taken }
        hotKey = reference
        return .registered
    }

    /// Carbon hot keys can't tell left from right Command, so a right-⌘
    /// shortcut is caught with an event tap, which needs Accessibility.
    private func registerRightCommand(_ shortcut: DictationShortcut) -> ShortcutRegistration {
        if let tap = RightCommandShortcutTap(shortcut: shortcut, action: { [weak self] in self?.performAction() }) {
            rightCommandTap = tap
            return .registered
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions(options)

        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let tap = RightCommandShortcutTap(shortcut: shortcut, action: { [weak self] in self?.performAction() })
                else { return }
                self.rightCommandTap = tap
                self.tapRetryTimer?.invalidate()
                self.tapRetryTimer = nil
                self.onDeferredRegistration?()
            }
        }
        return .needsAccessibility
    }

    private func performAction() {
        action()
    }
}

/// Swallows one key chord pressed with the right Command key and lets every
/// other event, including the same chord on the left Command key, through.
@MainActor
final class RightCommandShortcutTap {
    nonisolated static let leftCommandMask: UInt = 0x08  // NX_DEVICELCMDKEYMASK
    nonisolated static let rightCommandMask: UInt = 0x10 // NX_DEVICERCMDKEYMASK

    private let keyCode: Int64
    private let modifiers: CGEventFlags
    private let action: @MainActor @Sendable () -> Void
    // Set once in init; the tap callback runs on the main run loop.
    nonisolated(unsafe) private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init?(shortcut: DictationShortcut, action: @escaping @MainActor @Sendable () -> Void) {
        keyCode = Int64(shortcut.keyCode)
        modifiers = Self.eventFlags(forCarbon: shortcut.modifiers)
        self.action = action

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let handler = Unmanaged<RightCommandShortcutTap>.fromOpaque(userInfo).takeUnretainedValue()
                return handler.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return nil
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    isolated deinit {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    nonisolated private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let device = UInt(flags.rawValue)

        guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode,
              flags.intersection(relevant) == modifiers,
              device & Self.rightCommandMask != 0,
              device & Self.leftCommandMask == 0 else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let action = action
            MainActor.assumeIsolated { action() }
        }
        return nil
    }

    private static func eventFlags(forCarbon modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }
}
