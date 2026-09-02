import AppKit
import ApplicationServices

/// One entry read out of another app's menu, with its nested submenu already read.
///
/// Deliberately a complete tree rather than something loaded on demand. Building it costs
/// one background pass, and it means presenting the menu involves no cross-process calls
/// at all — see `readMenu(for:maxDepth:)` for why that matters.
public struct MirroredEntry {
    public let title: String
    public let isEnabled: Bool
    public let isSeparator: Bool
    public let children: [MirroredEntry]
    public let element: AXUIElement

    public var hasSubmenu: Bool { !children.isEmpty }
}

/// Safe to hand to a background queue, for the same reasons as `StatusItem`.
extension MirroredEntry: @unchecked Sendable {}

/// Invokes menu bar items, and the entries inside their menus, in other applications.
public enum ItemActivator {

    private static let messagingTimeout: Float = 0.3

    // MARK: - Pressing the item itself

    /// Press a status item, exactly as clicking it would.
    ///
    /// Fire-and-forget on a background queue, and that is not an optimisation: a
    /// menu-opening item does not reply to the AX message until the menu it opened is
    /// dismissed, so on the main thread this would freeze the app for as long as the user
    /// leaves that menu open. There is nothing to report back either — whether a menu, a
    /// popover or a window appears is the other app's business.
    ///
    /// The catch is placement. The menu opens anchored to the real item, so for an item
    /// parked off-screen it may land somewhere unusable. Prefer `peekMenu` where possible.
    public static func press(_ item: StatusItem) {
        press(element: item.element)
    }

    /// Activate one mirrored menu entry.
    ///
    /// This works whether or not that menu has ever been opened, which is what makes the
    /// mirroring approach worth having: the item's position on screen never enters into it.
    public static func press(entry: MirroredEntry) {
        press(element: entry.element)
    }

    private static func press(element: AXUIElement) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AX.perform(element, kAXPressAction as String, timeout: messagingTimeout)
        }
    }

    // MARK: - Reading a menu without opening it

    /// Read an item's whole menu tree, without pressing anything.
    ///
    /// An `NSMenu` attached to a status item is exposed as an `AXMenu` child whether or not
    /// it is currently open, so its entries can simply be read — no press, no flash, and no
    /// dependence on where the item sits. Roughly half of items support this; the rest are
    /// popover-backed or build their menu on demand, and must fall back to `press`.
    ///
    /// **Call this from a background queue, never while a menu is open.** Every AX call is
    /// synchronous cross-process IPC that pumps the run loop, and doing that from inside
    /// `NSMenu`'s tracking loop re-enters it and can make AppKit abandon menu tracking — the
    /// visible symptom being the whole dropdown flickering open and immediately shut. That
    /// is the reason this reads the entire tree up front rather than a level at a time:
    /// presenting the menu must involve no AX calls whatsoever.
    ///
    /// Three levels covers every menu observed in practice; a fourth found nothing more.
    ///
    /// Returns nil when there is nothing worth showing, which includes the lazily-populated
    /// case where an unopened menu holds only a placeholder row such as "Loading…".
    public static func readMenu(for element: AXUIElement, maxDepth: Int = 3) -> [MirroredEntry]? {
        guard let menu = attachedMenu(of: element) else { return nil }

        let entries = read(menu, depth: maxDepth)
        guard entries.filter({ !$0.isSeparator }).count > 1 else { return nil }
        return entries
    }

    private static func attachedMenu(of element: AXUIElement) -> AXUIElement? {
        AX.children(element)
            .first { AX.role($0) == (kAXMenuRole as String) }
            .map { AX.bound($0) }
    }

    private static func read(_ menu: AXUIElement, depth: Int) -> [MirroredEntry] {
        AX.children(menu).map { entry in
            AX.bound(entry)
            let title = AX.string(entry, kAXTitleAttribute as String) ?? ""

            var children: [MirroredEntry] = []
            if depth > 1, let submenu = attachedMenu(of: entry) {
                children = read(submenu, depth: depth - 1)
            }

            return MirroredEntry(
                title: title,
                isEnabled: AX.bool(entry, kAXEnabledAttribute as String) ?? true,
                // AppKit models separators as untitled menu items.
                isSeparator: title.isEmpty && children.isEmpty,
                children: children,
                element: entry
            )
        }
    }
}
