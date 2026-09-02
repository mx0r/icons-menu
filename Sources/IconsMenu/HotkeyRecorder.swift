import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that turns into a key trap while it is armed.
///
/// A local `NSEvent` monitor rather than a custom `NSView`: the Settings window is key while
/// recording, so a local monitor sees every keystroke before anything else in the app does,
/// and returning nil from it swallows the keys instead of letting them ring the alert sound.
struct HotkeyRecorder: View {

    @Binding var shortcut: HotkeyShortcut

    /// Owned by the caller's switch. Taken as a value rather than left to `.disabled` at the
    /// call site, because being switched off while armed has to *disarm* the recorder: a
    /// disabled button cannot be pressed to cancel, and the monitor it installed swallows
    /// every keystroke in the app until something takes it down.
    var isEnabled: Bool = true

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(isRecording ? "Press a shortcut…" : shortcut.label) {
                if isRecording { cancel() } else { start() }
            }
            .frame(minWidth: 120)

            if shortcut != .default {
                Button("Reset") {
                    cancel()
                    shortcut = .default
                }
                .buttonStyle(.link)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isRecording {
                Text("Escape to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!isEnabled)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { cancel() }
        }
        .onDisappear(perform: cancel)
    }

    private func start() {
        problem = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func cancel() {
        stop()
        problem = nil
    }

    /// Rejections leave the recorder armed, so a second attempt costs one keystroke rather
    /// than another trip to the button.
    private func handle(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        guard keyCode != kVK_Escape else { return cancel() }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift alone is not enough: a system-wide ⇧A would eat the letter everywhere.
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else {
            problem = "Hold ⌃, ⌥ or ⌘ as well."
            return
        }

        let candidate = HotkeyShortcut(
            keyCode: keyCode,
            modifiers: carbonModifiers(flags),
            label: label(for: event, flags: flags)
        )

        // Re-recording what is already installed: this app holds that registration, so
        // probing it would report a conflict with ourselves.
        guard candidate.keyCode != shortcut.keyCode || candidate.modifiers != shortcut.modifiers
        else {
            stop()
            return
        }

        guard GlobalHotkey.isAvailable(candidate) else {
            problem = "\(candidate.label) is already taken."
            return
        }

        shortcut = candidate
        stop()
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        return carbon
    }

    private func label(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        // The order macOS itself prints them in, regardless of the order they were pressed.
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyName(for: event)
    }

    /// Keys whose `charactersIgnoringModifiers` is a control character, which would otherwise
    /// print as an empty box.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private func keyName(for event: NSEvent) -> String {
        if let named = HotkeyRecorder.namedKeys[Int(event.keyCode)] { return named }

        if let characters = event.charactersIgnoringModifiers?.uppercased(),
           let first = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(first) {
            return characters
        }
        return "Key \(event.keyCode)"
    }
}
