import AppKit
import Carbon.HIToolbox

/// Carbon's hotkey dispatch cannot carry context, so registered actions live here and are
/// looked up by the id Carbon hands back.
private var registeredActions: [UInt32: () -> Void] = [:]
private var sharedEventHandler: EventHandlerRef?
private var nextHotkeyID: UInt32 = 1

/// Must be a C function: `EventHandlerUPP` is a bare function pointer, so it cannot capture.
private func handleHotkeyEvent(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else { return status }

    registeredActions[hotkeyID.id]?()
    return noErr
}

/// A system-wide hotkey.
///
/// Carbon is the mechanism because there is still no Cocoa equivalent: `NSEvent`'s global
/// monitors only observe events without claiming them, so they cannot stop the keystroke
/// reaching whatever app is frontmost. `RegisterEventHotKey` reserves the combination
/// outright, and needs no permissions of its own.
final class GlobalHotkey {

    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// Returns nil if the combination is already claimed by the system or another app.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        GlobalHotkey.installEventHandlerIfNeeded()

        id = nextHotkeyID
        nextHotkeyID += 1

        let hotkeyID = EventHotKeyID(signature: GlobalHotkey.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotkeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return nil }
        reference = ref
        registeredActions[id] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        registeredActions[id] = nil
    }

    /// 'IMNU' — an arbitrary four-char code identifying this app's hotkeys.
    private static let signature: OSType = 0x494D_4E55

    private static func installEventHandlerIfNeeded() {
        guard sharedEventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            handleHotkeyEvent,
            1,
            &eventType,
            nil,
            &sharedEventHandler
        )
    }
}

extension GlobalHotkey {
    /// Returns nil if the combination is already claimed, exactly as the initialiser does.
    static func register(_ shortcut: HotkeyShortcut, action: @escaping () -> Void) -> GlobalHotkey? {
        GlobalHotkey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: action)
    }

    /// Whether the combination can be claimed right now.
    ///
    /// Answered by actually registering it and letting go again, because Carbon offers no way
    /// to ask. The registration is dropped before returning, so the caller is free to install
    /// the shortcut for real — holding it here would make the caller's attempt fail.
    static func isAvailable(_ shortcut: HotkeyShortcut) -> Bool {
        var probe = GlobalHotkey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {}
        let available = probe != nil
        probe = nil
        return available
    }
}

/// A key combination, in the Carbon terms `RegisterEventHotKey` speaks.
struct HotkeyShortcut: Equatable {

    let keyCode: Int

    /// A Carbon modifier mask (`controlKey`, `optionKey`, …), not `NSEvent.ModifierFlags`.
    let modifiers: Int

    /// How to print it.
    ///
    /// Captured when the shortcut is recorded rather than derived on demand: going from a key
    /// code back to a character means asking the current keyboard layout through
    /// `UCKeyTranslate`, and what the user actually pressed is the honest thing to show.
    let label: String

    /// ⌃⌥M. Chosen because macOS claims no combination in that space, and neither do the
    /// common menu bar utilities.
    static let `default` = HotkeyShortcut(
        keyCode: kVK_ANSI_M,
        modifiers: controlKey | optionKey,
        label: "⌃⌥M"
    )
}
