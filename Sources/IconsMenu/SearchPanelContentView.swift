import AppKit

/// The panel's insides: a search field, a table of matches, and a hint bar.
///
/// AppKit rather than SwiftUI. A plain `NSTextField` is a real text field — selection,
/// double-click-to-select-a-word, the standard editing key bindings and an undo stack all
/// come with it — and an `NSTableView` needs no persuading to keep a keyboard selection in
/// view.
final class SearchPanelContentView: NSVisualEffectView {

    private let model: SearchModel
    private let onActivate: () -> Void

    private let magnifier = NSImageView()
    private let field = NSTextField()
    private let scopeChip = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")

    private var chipGap: NSLayoutConstraint!
    private var fieldGap: NSLayoutConstraint!

    private enum Metrics {
        static let rowHeight: CGFloat = 38
        static let headerHeight: CGFloat = 54
        static let footerHeight: CGFloat = 30
        static let inset: CGFloat = 14
        static let icon: CGFloat = 20
        static let gap: CGFloat = 9
    }

    init(model: SearchModel, onActivate: @escaping () -> Void) {
        self.model = model
        self.onActivate = onActivate
        super.init(frame: .zero)

        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        buildField()
        buildTable()
        buildFooter()
        layOut()

        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called after the panel is on screen and the app is forward: a field cannot become first
    /// responder before its window exists, and the field editor it types into is only attached
    /// once it has.
    func focusField() {
        guard let window else { return }
        window.makeFirstResponder(field)
        // Caret at the end rather than a full selection, so the first keystroke adds to the
        // query instead of replacing it.
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }

    /// Whether the field is genuinely taking keystrokes, as opposed to merely looking focused.
    var isFieldFocused: Bool {
        window?.firstResponder === field.currentEditor()
    }

    /// Rows hold rasterised application icons, so a move to a display with a different scale
    /// means drawing them again — otherwise what is on screen is a bitmap made for the other
    /// display, stretched or cropped into the same 20 points.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        table.reloadData()
    }

    /// Writes what the rows actually drew to the Desktop, along with the display they drew on.
    ///
    /// Off unless `defaults write info.hudak.macos.IconsMenu IconDiagnostics -bool true`.
    /// `cacheDisplay` captures the view's own drawing, before the window server composites it
    /// — so a capture that looks right beside a screenshot that looks wrong says the fault is
    /// downstream of this app, and one that looks wrong says it is ours.
    func captureDiagnostic() {
        guard UserDefaults.standard.bool(forKey: "IconDiagnostics"), let window else { return }

        let view = scroll
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = window.backingScaleFactor
        let name = window.screen?.localizedName.replacingOccurrences(of: " ", with: "-") ?? "none"
        let path = NSString(string: "~/Desktop/iconsmenu-diag-\(name)-\(scale)x.png")
            .expandingTildeInPath

        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))

        NSLog(
            "IconsMenu diagnostics: screen=%@ scale=%@ frame=%@ wrote %@",
            name,
            "\(scale)",
            "\(window.frame)",
            path
        )
    }

    // MARK: - Building

    private func buildField() {
        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )
        magnifier.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19, weight: .regular)
        // Not "every": what is searched is what Settings has left switched on.
        field.placeholderString = "Search menu bar items"
        field.delegate = self
        // Return is handled by the panel's key monitor, well before the field's action would
        // fire; this only stops AppKit beeping if it ever gets that far.
        field.target = nil
        field.action = nil

        scopeChip.font = .systemFont(ofSize: 12, weight: .medium)
        scopeChip.wantsLayer = true
        scopeChip.layer?.cornerRadius = 5
        scopeChip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        scopeChip.isHidden = true
    }

    private func buildTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.headerView = nil
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        // `.plain` so rows start where the field's text starts; `.inset` adds a margin of its
        // own and pushes the icon column out of line with the magnifier above it.
        table.style = .plain
        // AppKit's own highlight greys out whenever the table is not first responder, and the
        // field holds focus for the whole life of the panel — so the selection is drawn by the
        // row instead.
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        // The field keeps focus for the whole life of the panel; the table is driven from the
        // model, never from its own first-responder state.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
    }

    private func buildFooter() {
        for label in [hint, counter] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        counter.alignment = .right
    }

    private func layOut() {
        let divider = NSBox()
        divider.boxType = .separator
        let footerDivider = NSBox()
        footerDivider.boxType = .separator

        for view in [magnifier, field, scopeChip, scroll, divider, footerDivider, hint, counter] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // A layout guide rather than a tall text field: a single-line `NSTextField` draws its
        // text at the top of its frame, so stretching it to the header's height leaves the
        // text high and everything aligned to it visibly low.
        let header = NSLayoutGuide()
        addLayoutGuide(header)

        // Held on to because the gaps around the scope chip close up when there is no chip —
        // a hidden view still takes part in Auto Layout, spacing and all.
        chipGap = scopeChip.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor)
        fieldGap = field.leadingAnchor.constraint(
            equalTo: scopeChip.trailingAnchor,
            constant: Metrics.gap
        )

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),

            // The magnifier occupies the same column as the rows' application icons, so the
            // query and the results it produces line up.
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            magnifier.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: Metrics.icon),

            chipGap,
            scopeChip.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            fieldGap,
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            field.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerDivider.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Metrics.footerHeight
            ),

            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            counter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            counter.bottomAnchor.constraint(equalTo: hint.bottomAnchor),
        ])
    }

    // MARK: - Drawing what the model says

    private func refresh() {
        if field.stringValue != model.query { field.stringValue = model.query }

        if let scope = model.scope {
            scopeChip.stringValue = " \(scope.name) "
            scopeChip.isHidden = false
            chipGap.constant = Metrics.gap
            fieldGap.constant = 6
            field.placeholderString = "Search \(scope.name)"
        } else {
            scopeChip.stringValue = ""
            scopeChip.isHidden = true
            chipGap.constant = 0
            fieldGap.constant = Metrics.gap
            field.placeholderString = "Search menu bar items"
        }

        table.reloadData()

        if model.count > 0, model.selection < model.count {
            table.selectRowIndexes([model.selection], byExtendingSelection: false)
            table.scrollRowToVisible(model.selection)
        } else {
            table.deselectAll(nil)
        }

        hint.stringValue = [
            "↑↓ move",
            model.showsApplications ? "↩ open or narrow" : "↩ activate",
            model.scope == nil ? "esc close" : "esc back",
        ].joined(separator: "   ·   ")

        counter.stringValue = model.count == 0 ? "no matches" : "\(model.count)"
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        if model.activateSelection(at: row) { onActivate() }
    }
}

// MARK: - Text

extension SearchPanelContentView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        model.query = field.stringValue
    }
}

// MARK: - Rows

extension SearchPanelContentView: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.count
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int)
        -> NSView?
    {
        let view =
            tableView.makeView(withIdentifier: SearchRowView.identifier, owner: self)
            as? SearchRowView ?? SearchRowView()

        if model.showsApplications {
            guard let app = model.applications[safe: index] else { return view }
            view.show(
                pid: app.pid,
                title: app.name,
                subtitle: app.rowCount == 1 ? nil : "\(app.rowCount) entries",
                trailing: app.rowCount == 1 ? nil : "↩ narrows",
                isEnabled: true,
                isSelected: index == model.selection
            )
        } else {
            guard let result = model.results[safe: index] else { return view }
            view.show(
                pid: result.pid,
                title: result.title,
                // Inside a scope every row belongs to the same application, so naming it on
                // each one is noise. What is left is the submenu path, where there is one.
                subtitle: result.subtitle(includingApp: model.scope == nil),
                trailing: nil,
                isEnabled: result.isEnabled,
                isSelected: index == model.selection
            )
        }
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

/// One row: the owning application's icon, what the row does, and where it lives.
private final class SearchRowView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("SearchRowView")

    private let highlight = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    /// Laid out by hand, in `layout()`, and flipped so y grows downward.
    ///
    /// The stack views this replaces looked identical until the table started recycling rows:
    /// a row that had had a subtitle kept the space for it after the subtitle was hidden, so
    /// everything without one sat visibly high from the first scroll onwards. Two frames
    /// computed from the row's own height cannot drift out of step with the content.
    override var isFlipped: Bool { true }

    private enum Metrics {
        static let inset: CGFloat = 14
        static let icon: CGFloat = 20
        static let gap: CGFloat = 9
    }

    init() {
        super.init(frame: .zero)
        identifier = SearchRowView.identifier

        title.font = .systemFont(ofSize: 13.5)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        trailing.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        trailing.textColor = .tertiaryLabelColor

        // The image is already the size of its frame, so this only guards against a source
        // that has no representation at that size at all.
        icon.imageScaling = .scaleProportionallyUpOrDown

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true

        for view in [highlight, icon, title, subtitle, trailing] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()

        highlight.frame = bounds.insetBy(dx: 6, dy: 1)
        icon.frame = NSRect(
            x: Metrics.inset,
            y: ((bounds.height - Metrics.icon) / 2).rounded(),
            width: Metrics.icon,
            height: Metrics.icon
        )

        let textX = Metrics.inset + Metrics.icon + Metrics.gap
        var textRight = bounds.maxX - Metrics.inset

        if !trailing.isHidden {
            let size = trailing.intrinsicContentSize
            trailing.frame = NSRect(
                x: bounds.maxX - Metrics.inset - size.width,
                y: ((bounds.height - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            textRight = trailing.frame.minX - Metrics.gap
        }

        let width = max(0, textRight - textX)
        let titleHeight = ceil(title.intrinsicContentSize.height)

        guard !subtitle.isHidden else {
            title.frame = NSRect(
                x: textX,
                y: ((bounds.height - titleHeight) / 2).rounded(),
                width: width,
                height: titleHeight
            )
            return
        }

        let subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let top = ((bounds.height - titleHeight - subtitleHeight) / 2).rounded()
        title.frame = NSRect(x: textX, y: top, width: width, height: titleHeight)
        subtitle.frame = NSRect(
            x: textX,
            y: top + titleHeight,
            width: width,
            height: subtitleHeight
        )
    }

    func show(
        pid: pid_t,
        title: String,
        subtitle: String?,
        trailing: String?,
        isEnabled: Bool,
        isSelected: Bool
    ) {
        icon.image = AppIcon.forProcess(pid, size: Metrics.icon)
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle ?? ""
        self.subtitle.isHidden = subtitle == nil
        self.trailing.stringValue = trailing ?? ""
        self.trailing.isHidden = trailing == nil || !isSelected
        alphaValue = isEnabled ? 1 : 0.45

        highlight.isHidden = !isSelected
        highlight.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor

        // A recycled row arrives with the previous row's geometry.
        needsLayout = true
    }
}
