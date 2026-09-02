import AppKit

/// What the search panel is showing, and what Return does to it.
///
/// Deliberately not an `ObservableObject`: the panel is AppKit, and a plain callback is both
/// the whole of what it needs and one less thing that can silently fail to fire.
@MainActor
final class SearchModel {

    /// Fired after anything the panel draws has changed.
    var onChange: (() -> Void)?

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            refilter()
        }
    }

    private(set) var results: [SearchIndex.Row] = []
    private(set) var applications: [SearchIndex.Application] = []

    /// Set by pressing Return on an application, which narrows the search to it. Not required
    /// for anything — every row is reachable by typing — but it makes browsing one app's menu
    /// possible without knowing what is in it.
    private(set) var scope: SearchIndex.Application?

    var selection = 0 {
        didSet {
            guard selection != oldValue else { return }
            onChange?()
        }
    }

    /// Nothing typed and nothing scoped: the applications, which is the closest thing to the
    /// dropdown's own list and a better starting point than several hundred rows.
    var showsApplications: Bool { scope == nil && query.isEmpty }

    var count: Int { showsApplications ? applications.count : results.count }

    private var allRows: [SearchIndex.Row] = []
    private let inventory: () -> Inventory
    private let preferences = Preferences.shared

    init(inventory: @escaping () -> Inventory) {
        self.inventory = inventory
    }

    /// Rebuilt from the cache every time the panel opens — cheap, and it means a menu that
    /// changed since the last scan is not carried any longer than the dropdown carries it.
    func reload() {
        allRows = SearchIndex.rows(in: inventory(), where: preferences.isVisible)
        applications = SearchIndex.applications(for: allRows)
        refilter()
    }

    func reset() {
        scope = nil
        query = ""
        refilter()
    }

    func move(by offset: Int) {
        guard count > 0 else { return }
        // Clamped rather than wrapped: holding ↓ should come to rest at the end of the list,
        // not cycle back past the row you were aiming at.
        selection = min(max(selection + offset, 0), count - 1)
    }

    func moveToEdge(_ direction: Int) {
        selection = direction < 0 ? 0 : max(count - 1, 0)
    }

    /// Escape and backspace-on-empty both land here.
    ///
    /// Returns false when there was no scope to leave, which is the caller's cue to close.
    func leaveScope() -> Bool {
        guard scope != nil else { return false }
        scope = nil
        query = ""
        refilter()
        return true
    }

    /// Clicking a row is the same as selecting it and pressing Return — the mouse is not the
    /// point here, but a panel that ignored it would be odd.
    func activateSelection(at index: Int) -> Bool {
        selection = index
        return activateSelection()
    }

    /// Returns true when the panel's work is done and it should close.
    func activateSelection() -> Bool {
        if showsApplications {
            guard let app = applications[safe: selection] else { return false }

            let rows = allRows.filter { $0.bundleID == app.bundleID }
            // An application with exactly one row has nothing to browse, so Return does the
            // obvious thing rather than making the user press it twice.
            if let only = rows.first, rows.count == 1 {
                activate(only)
                return true
            }

            scope = app
            query = ""
            refilter()
            return false
        }

        guard let row = results[safe: selection] else { return false }
        activate(row)
        return true
    }

    func activate(_ row: SearchIndex.Row) {
        switch row.target {
        case .item(let item): ItemActivator.press(item)
        case .entry(let entry): ItemActivator.press(entry: entry)
        }
    }

    private func refilter() {
        let pool = scope.map { scope in allRows.filter { $0.bundleID == scope.bundleID } } ?? allRows
        results = SearchIndex.filter(pool, query: query)
        selection = 0
        onChange?()
    }
}

extension Array {
    /// The selection is held separately from the list it indexes, so a stale index can
    /// briefly outlive the list it came from.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
