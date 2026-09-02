import AppKit

/// The menu bar's whole tree, flattened into one list of things that can be activated.
///
/// Built from the same cached inventory the dropdown is built from, so typing costs no
/// cross-process calls — the entire point of reading each menu up front. Nothing here touches
/// the Accessibility API.
public enum SearchIndex {

    /// One activatable row: a leaf of some application's mirrored menu, or a status item that
    /// has no mirrorable menu and can only be pressed.
    ///
    /// Rows that merely *contain* other rows are not listed. Their children already are, with
    /// the container's title in their path, which is the whole idea of a flat search: no
    /// descending, and one query reaches the third level as easily as the first.
    public struct Row: Identifiable {

        public enum Target {
            case item(StatusItem)
            case entry(MirroredEntry)
        }

        public let id: String
        public let title: String

        /// The owning application, named as the dropdown names it.
        public let app: String

        /// Submenu titles above this row, excluding the application: ["Settings"] for
        /// Docker Desktop › Settings › Kubernetes.
        public let path: [String]

        public let bundleID: String
        public let pid: pid_t
        public let isEnabled: Bool
        public let target: Target

        /// Application, path and title, lowercased, built once — filtering runs on every
        /// keystroke and this is the string every keystroke searches.
        let haystack: String

        /// What to show under the title. Nil when it would only repeat it — an application
        /// contributing a single unmirrorable item, or a top-level entry listed inside a
        /// scope that already names the application.
        public func subtitle(includingApp: Bool = true) -> String? {
            let trail = includingApp ? [app] + path : path
            guard !trail.isEmpty, !(path.isEmpty && title == app && includingApp) else {
                return nil
            }
            return trail.joined(separator: " › ")
        }
    }

    /// An application, as listed when nothing has been typed yet.
    public struct Application: Identifiable {
        public let bundleID: String
        public let name: String
        public let pid: pid_t
        public let rowCount: Int

        public var id: String { bundleID }
    }

    // MARK: - Building

    public static func rows(
        in inventory: Inventory,
        where include: (StatusItem) -> Bool = { _ in true }
    ) -> [Row] {
        var rows: [Row] = []

        for item in inventory.items where include(item) {
            let app = Inventory.displayName(for: item)

            if let entries = item.menu {
                append(entries, of: item, app: app, path: [], idPrefix: item.id, into: &rows)
            } else {
                // Nothing to mirror, so the item itself is the row — exactly the one case
                // where the dropdown offers a plain press too.
                let siblings = inventory.siblings(of: item).count
                rows.append(
                    make(
                        id: item.id,
                        title: siblings > 1 ? Inventory.itemName(for: item) : app,
                        app: app,
                        path: [],
                        item: item,
                        isEnabled: true,
                        target: .item(item)
                    )
                )
            }
        }
        return rows
    }

    private static func append(
        _ entries: [MirroredEntry],
        of item: StatusItem,
        app: String,
        path: [String],
        idPrefix: String,
        into rows: inout [Row]
    ) {
        for (index, entry) in entries.enumerated() where !entry.isSeparator {
            let id = "\(idPrefix)/\(index)"

            if entry.hasSubmenu {
                append(
                    entry.children,
                    of: item,
                    app: app,
                    path: path + [entry.title],
                    idPrefix: id,
                    into: &rows
                )
            } else {
                rows.append(
                    make(
                        id: id,
                        title: entry.title,
                        app: app,
                        path: path,
                        item: item,
                        isEnabled: entry.isEnabled,
                        target: .entry(entry)
                    )
                )
            }
        }
    }

    private static func make(
        id: String,
        title: String,
        app: String,
        path: [String],
        item: StatusItem,
        isEnabled: Bool,
        target: Row.Target
    ) -> Row {
        Row(
            id: id,
            title: title,
            app: app,
            path: path,
            bundleID: item.bundleID,
            pid: item.pid,
            isEnabled: isEnabled,
            target: target,
            haystack: ([app] + path + [title]).joined(separator: " ").lowercased()
        )
    }

    /// One entry per application, in the order their items appear in the bar.
    public static func applications(for rows: [Row]) -> [Application] {
        var seen: Set<String> = []
        var apps: [Application] = []

        for row in rows where !seen.contains(row.bundleID) {
            seen.insert(row.bundleID)
            apps.append(
                Application(
                    bundleID: row.bundleID,
                    name: row.app,
                    pid: row.pid,
                    rowCount: rows.count { $0.bundleID == row.bundleID }
                )
            )
        }
        return apps
    }

    // MARK: - Filtering

    /// Every whitespace-separated token has to appear somewhere in the row — application,
    /// path or title — so "doc kub" finds Docker Desktop's Kubernetes entries without
    /// caring which order they were typed in or how deep the entry sits.
    ///
    /// Substring rather than fuzzy matching, deliberately: a fuzzy index would rank "Sound"
    /// above nothing for "snd", but it also matches things the user cannot see the reason
    /// for, and a menu bar full of near-identical entry names is where that goes wrong.
    public static func filter(_ rows: [Row], query: String) -> [Row] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return rows }

        let matches = rows.enumerated().filter { _, row in
            tokens.allSatisfy { row.haystack.contains($0) }
        }

        // Ranked by where the *first* token lands: a title that starts with it beats a title
        // that merely contains it, which beats a match somewhere in the path. Original order
        // breaks ties, so the list never reshuffles for reasons the user cannot see.
        return matches
            .map { (order: $0.offset, row: $0.element, rank: rank($0.element, for: tokens[0])) }
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .map(\.row)
    }

    private static func rank(_ row: Row, for token: String) -> Int {
        let title = row.title.lowercased()
        if title.hasPrefix(token) { return 0 }
        if title.contains(token) { return 1 }
        return 2
    }
}
