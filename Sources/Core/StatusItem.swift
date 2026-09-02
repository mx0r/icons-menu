import AppKit
import ApplicationServices

/// One menu bar item ("menu bar extra") belonging to one running application.
public struct StatusItem: Identifiable {

    /// Ordinal within its own app's extras menu bar. Combined with the bundle ID this is
    /// the only stable identity available, because most items carry no AX label.
    public let index: Int
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public let label: String?
    public let frame: CGRect?
    public let element: AXUIElement

    /// This item's whole menu tree, or nil if it has none worth mirroring.
    ///
    /// Read during the scan, on a background queue, precisely so that nothing has to touch
    /// AX while a menu is on screen — see `ItemActivator.readMenu(for:maxDepth:)`.
    public let menu: [MirroredEntry]?

    public var hasMirrorableMenu: Bool { menu != nil }

    /// Stable across relaunches, so it can key persisted preferences.
    /// Deliberately excludes the pid, which changes every launch.
    public var id: String { "\(bundleID)#\(index)" }

    public init(
        index: Int,
        pid: pid_t,
        bundleID: String,
        appName: String,
        label: String?,
        frame: CGRect?,
        element: AXUIElement,
        menu: [MirroredEntry]? = nil
    ) {
        self.index = index
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.label = label
        self.frame = frame
        self.element = element
        self.menu = menu
    }

    /// Whether the item currently sits within some attached display.
    ///
    /// False means macOS has parked it: pushed past the left edge because the bar
    /// overflowed, tucked behind the notch, or hidden by another menu bar utility. Such an
    /// item is still perfectly pressable — that is the whole premise of this app.
    public var isOnScreen: Bool {
        guard let frame else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    /// Items with no area are placeholders rather than real menu bar items.
    ///
    /// Control Center reports one of these for every module you have *not* enabled —
    /// 13 of its 19 children on the development machine — all sized 0×0. They are not
    /// hidden items and must never reach the menu.
    public var isPlaceholder: Bool {
        guard let frame else { return true }
        return frame.width < 1 || frame.height < 1
    }
}

/// Safe to hand to a background queue. Every stored property is immutable, and
/// `AXUIElement` is a CFType whose client API is explicitly usable from any thread — each
/// call is a round trip to another process, which is exactly why these reads belong off the
/// main thread in the first place.
extension StatusItem: @unchecked Sendable {}

extension StatusItem: Equatable, Hashable {
    // Identity only. AXUIElement has no useful value equality, and frames change constantly
    // as the bar relayouts, so including either would make these useless as dictionary keys.
    public static func == (lhs: StatusItem, rhs: StatusItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
