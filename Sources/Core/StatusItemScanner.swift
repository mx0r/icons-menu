import AppKit
import ApplicationServices

/// The set of menu bar items present at one moment, plus the display naming that depends
/// on knowing an item's siblings.
///
/// Handed between threads — scans run in the background and the result is published to the
/// main actor — which is sound for the same reason as `StatusItem`: immutable throughout,
/// and AX elements are usable from any thread.
public struct Inventory: @unchecked Sendable {

    public let items: [StatusItem]

    /// Item ids that are not currently within any display, and so are unreachable by
    /// clicking. These are the reason this app exists, so they sort first.
    public var unreachable: [StatusItem] { items.filter { !$0.isOnScreen } }
    public var reachable: [StatusItem] { items.filter(\.isOnScreen) }

    private let itemCountByBundleID: [String: Int]

    public init(items: [StatusItem]) {
        self.items = items
        self.itemCountByBundleID = items.reduce(into: [:]) { counts, item in
            counts[item.bundleID, default: 0] += 1
        }
    }

    /// What to show in the menu: the application name, per the brief.
    ///
    /// A label is appended only when the owning app contributes more than one item, since
    /// "Docker Desktop" alone is clearer than "Docker Desktop — Docker Desktop is running".
    /// Static because it depends only on the item — which lets the scanner sort by exactly
    /// the strings that will be displayed, rather than by an approximation of them.
    public static func displayName(for item: StatusItem) -> String {
        tidiedAppName(item.appName, bundleID: item.bundleID)
    }

    /// How to name one item *within* its application's group, where the app name is already
    /// the heading and repeating it would only add noise.
    ///
    /// Control Center is the case that motivates grouping: it alone contributes seven items,
    /// which flat would fill a third of the dropdown with rows all beginning
    /// "Control Center".
    public static func itemName(for item: StatusItem) -> String {
        guard let label = item.label, !label.isEmpty else { return "Item \(item.index + 1)" }
        return truncate(label)
    }

    /// Fully qualified name, for flat lists that have no grouping to lean on.
    public func qualifiedName(for item: StatusItem) -> String {
        let base = Inventory.displayName(for: item)
        guard (itemCountByBundleID[item.bundleID] ?? 1) > 1 else { return base }

        // A label that merely repeats the app name reads as a stutter —
        // "Control Center — Control Center" — so fall through to the ordinal instead.
        if let label = item.label, !label.isEmpty,
           label.caseInsensitiveCompare(base) != .orderedSame,
           label.caseInsensitiveCompare(item.appName) != .orderedSame {
            return "\(base) — \(Inventory.truncate(label))"
        }
        return "\(base) (\(item.index + 1))"
    }

    /// Every item belonging to the same app as `item`, in bar order.
    public func siblings(of item: StatusItem) -> [StatusItem] {
        items.filter { $0.bundleID == item.bundleID }
    }

    /// Apple's menu bar agents name themselves for the process list rather than for humans:
    /// "WeatherMenu", "TextInputMenuAgent", "iStat Menus Menubar".
    ///
    /// Stripping a bare "Menu" is only safe for Apple's own bundles. Third-party apps put
    /// it in the actual product name, where removing it mangles them — this app itself was
    /// being listed as "Icons".
    static func tidiedAppName(_ name: String, bundleID: String) -> String {
        // Longest first, so "TextInputMenuAgent" loses "MenuAgent" and not just " Agent".
        var suffixes = [" Menu Bar", " Menubar", " Helper", " Agent"]
        if bundleID.hasPrefix("com.apple.") {
            suffixes = ["MenuAgent"] + suffixes + ["Menu"]
        }

        for suffix in suffixes where name.hasSuffix(suffix) {
            let trimmed = String(name.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespaces)
            // Never strip an app down to nothing, or to something unrecognisable.
            if trimmed.count >= 3 { return trimmed }
        }
        return name
    }

    static func truncate(_ text: String, limit: Int = 40) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

public enum StatusItemScanner {

    /// Enumerate every running app's menu bar items via `AXExtrasMenuBar`.
    ///
    /// Requires Accessibility permission; without it every app reports no extras menu bar
    /// and this returns empty, which is why callers must gate on `AX.isTrusted` and say so
    /// rather than showing an empty menu.
    public static func scan() -> Inventory {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Note that background-only apps are *not* filtered out. It is tempting, since
        // around 60 of the ~150 running processes are `.prohibited` and none of them look
        // like they could own a menu bar item — but one of them does, and skipping them
        // loses it.
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier > 0 && app.processIdentifier != ownPID && app.bundleIdentifier != nil
        }

        // Queried concurrently: these are round trips to ~150 separate processes, so the
        // cost is almost entirely waiting. One slot per app, so no worker shares state.
        var perApp = [[StatusItem]](repeating: [], count: apps.count)
        perApp.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: apps.count) { index in
                buffer[index] = items(of: apps[index])
            }
        }

        return Inventory(items: sorted(perApp.flatMap { $0 }))
    }

    private static func items(of app: NSRunningApplication) -> [StatusItem] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        let pid = app.processIdentifier

        guard let extras = AX.copyAttribute(AX.application(pid: pid), "AXExtrasMenuBar") else {
            return []
        }

        return AX.children(extras as! AXUIElement).enumerated().compactMap { index, element in
            // Elements out of a children array inherit no timeout, so bound them too before
            // anything reads their menus later.
            AX.bound(element)

            let item = StatusItem(
                index: index,
                pid: pid,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                label: AX.label(element),
                frame: AX.frame(element),
                element: element,
                // Read here, on the concurrent sweep, so that presenting the dropdown needs
                // no AX calls at all. Doing this while a menu is open destabilises AppKit's
                // menu tracking.
                menu: ItemActivator.readMenu(for: element)
            )
            // Drops Control Center's disabled-module placeholders.
            return item.isPlaceholder ? nil : item
        }
    }

    /// Alphabetical by application, then by item within an application.
    ///
    /// Sorted on the displayed strings and with `localizedStandardCompare`, so the order
    /// matches what is on screen and handles case, digits and diacritics the way the Finder
    /// does rather than by raw code point.
    ///
    /// The off-screen items still appear first in the menu; that split comes from
    /// `unreachable`/`reachable`, not from this ordering.
    private static func sorted(_ items: [StatusItem]) -> [StatusItem] {
        items.sorted { lhs, rhs in
            let byApp = Inventory.displayName(for: lhs)
                .localizedStandardCompare(Inventory.displayName(for: rhs))
            if byApp != .orderedSame { return byApp == .orderedAscending }

            let byItem = Inventory.itemName(for: lhs)
                .localizedStandardCompare(Inventory.itemName(for: rhs))
            if byItem != .orderedSame { return byItem == .orderedAscending }

            return lhs.index < rhs.index
        }
    }
}
