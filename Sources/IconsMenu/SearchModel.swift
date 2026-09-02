import AppKit

/// What the search panel is showing, and what Return does to it.
@MainActor
final class SearchModel: ObservableObject {

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refilter()
        }
    }

    @Published private(set) var results: [SearchIndex.Row] = []
    @Published private(set) var applications: [SearchIndex.Application] = []

    /// Set by pressing Return on an application, which narrows the search to it. Not required
    /// for anything — every row is reachable by typing — but it makes browsing one app's menu
    /// possible without knowing what is in it.
    @Published private(set) var scope: SearchIndex.Application?

    @Published var selection = 0

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
    /// changed since the last scan is not carried over any longer than the dropdown carries
    /// it either.
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
        // not cycle back to the top past the row you were aiming at.
        selection = min(max(selection + offset, 0), count - 1)
    }

    func moveToEdge(_ offset: Int) {
        selection = offset < 0 ? 0 : max(count - 1, 0)
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
    /// point here, but a panel that ignores it would be odd.
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
            // obvious thing instead of making the user press it twice.
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
    }
}

extension Array {
    /// Selection and the list it indexes are published separately, so a stale index can
    /// briefly outlive the list it came from.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
