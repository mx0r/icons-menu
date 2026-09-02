import AppKit

/// Everything the user can change, persisted in `UserDefaults`.
///
/// One object rather than reads scattered across the app: the menu and the Settings window
/// cannot then disagree about what is hidden, and a change has exactly one place to be
/// observed from.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// Applications kept out of the dropdown, by bundle ID.
    ///
    /// Per application rather than per item, because the menu groups that way and because an
    /// item's ordinal shifts as its app adds or drops items — a set of item ids would quietly
    /// start hiding the wrong thing.
    @Published var hiddenBundleIDs: Set<String> {
        didSet {
            guard hiddenBundleIDs != oldValue else { return }
            defaults.set(hiddenBundleIDs.sorted(), forKey: Key.hidden)
        }
    }

    @Published var hotkey: HotkeyShortcut {
        didSet {
            guard hotkey != oldValue else { return }
            defaults.set(hotkey.keyCode, forKey: Key.hotkeyKeyCode)
            defaults.set(hotkey.modifiers, forKey: Key.hotkeyModifiers)
            defaults.set(hotkey.label, forKey: Key.hotkeyLabel)
        }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let hidden = "HiddenBundleIDs"
        static let hotkeyKeyCode = "HotkeyKeyCode"
        static let hotkeyModifiers = "HotkeyModifiers"
        static let hotkeyLabel = "HotkeyLabel"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenBundleIDs = Set(defaults.stringArray(forKey: Key.hidden) ?? [])

        // All three parts or none: a half-written shortcut would register something the label
        // does not describe, which is worse than falling back to the default.
        if let label = defaults.string(forKey: Key.hotkeyLabel),
           defaults.object(forKey: Key.hotkeyKeyCode) != nil,
           defaults.object(forKey: Key.hotkeyModifiers) != nil {
            hotkey = HotkeyShortcut(
                keyCode: defaults.integer(forKey: Key.hotkeyKeyCode),
                modifiers: defaults.integer(forKey: Key.hotkeyModifiers),
                label: label
            )
        } else {
            hotkey = .default
        }
    }

    func isHidden(_ bundleID: String) -> Bool {
        hiddenBundleIDs.contains(bundleID)
    }

    func setHidden(_ hidden: Bool, for bundleID: String) {
        if hidden {
            hiddenBundleIDs.insert(bundleID)
        } else {
            hiddenBundleIDs.remove(bundleID)
        }
    }

    /// The only way back for an application that has since quit: it is not in the inventory,
    /// so there is no row to switch back on.
    func showAll() {
        hiddenBundleIDs = []
    }
}
