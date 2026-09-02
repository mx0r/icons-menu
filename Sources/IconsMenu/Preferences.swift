import AppKit

/// Everything the user can change, persisted in `UserDefaults`.
///
/// One object rather than reads scattered across the app: the menu and the Settings window
/// cannot then disagree about what is hidden, and a change has exactly one place to be
/// observed from.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// Applications kept out of the dropdown, by bundle ID. Hides everything the app
    /// contributes, which for Control Center is seven items behind one switch.
    @Published var hiddenBundleIDs: Set<String> {
        didSet {
            guard hiddenBundleIDs != oldValue else { return }
            defaults.set(hiddenBundleIDs.sorted(), forKey: Key.hidden)
        }
    }

    /// Individual items kept out, by `StatusItem.id` — `bundleID#index`.
    ///
    /// That ordinal is the only identity most items have, since they carry no AX label, and
    /// it is stable for as long as the app contributes the same items in the same order. An
    /// app that starts adding or dropping items can shift the ordinals under a saved id, so
    /// this is the granularity to use deliberately; the app-level switch is the robust one.
    @Published var hiddenItemIDs: Set<String> {
        didSet {
            guard hiddenItemIDs != oldValue else { return }
            defaults.set(hiddenItemIDs.sorted(), forKey: Key.hiddenItems)
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

    /// Off means no system-wide shortcut is registered at all, which is the only way to give
    /// a combination back to another application. The shortcut itself is remembered, so
    /// switching it on again does not mean recording it again.
    @Published var isHotkeyEnabled: Bool {
        didSet {
            guard isHotkeyEnabled != oldValue else { return }
            defaults.set(isHotkeyEnabled, forKey: Key.hotkeyEnabled)
        }
    }

    private let defaults: UserDefaults

    /// Writes what the search panel's rows actually drew to the Desktop. Set by hand — there
    /// is no UI for it — and read here rather than off `UserDefaults` at the call site, so
    /// every key this app knows about stays in one place.
    var isDiagnosticsEnabled: Bool { defaults.bool(forKey: Key.diagnostics) }

    private enum Key {
        static let diagnostics = "IconDiagnostics"
        static let hidden = "HiddenBundleIDs"
        static let hiddenItems = "HiddenItemIDs"
        static let hotkeyEnabled = "HotkeyEnabled"
        static let hotkeyKeyCode = "HotkeyKeyCode"
        static let hotkeyModifiers = "HotkeyModifiers"
        static let hotkeyLabel = "HotkeyLabel"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenBundleIDs = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        hiddenItemIDs = Set(defaults.stringArray(forKey: Key.hiddenItems) ?? [])
        // Absent means on: the shortcut is how the app stays reachable when its icon is not.
        isHotkeyEnabled = defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true

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

    func isHidden(app bundleID: String) -> Bool {
        hiddenBundleIDs.contains(bundleID)
    }

    func setHidden(_ hidden: Bool, app bundleID: String) {
        if hidden {
            hiddenBundleIDs.insert(bundleID)
        } else {
            hiddenBundleIDs.remove(bundleID)
        }
    }

    func isHidden(item itemID: String) -> Bool {
        hiddenItemIDs.contains(itemID)
    }

    func setHidden(_ hidden: Bool, item itemID: String) {
        if hidden {
            hiddenItemIDs.insert(itemID)
        } else {
            hiddenItemIDs.remove(itemID)
        }
    }

    /// Whether this item reaches the menu, which takes both switches: an application hidden
    /// as a whole takes its items with it.
    func isVisible(_ item: StatusItem) -> Bool {
        !isHidden(app: item.bundleID) && !isHidden(item: item.id)
    }

    var hiddenCount: Int { hiddenBundleIDs.count + hiddenItemIDs.count }

    /// The only way back for anything belonging to an application that has since quit: it is
    /// not in the inventory, so there is no row to switch back on.
    func showAll() {
        hiddenBundleIDs = []
        hiddenItemIDs = []
    }
}
