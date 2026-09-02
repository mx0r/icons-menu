import AppKit

/// Owns this app's own menu bar item and the dropdown hanging off it.
///
/// The entire tree is built in one pass from `cachedInventory`, which a background scan
/// keeps current. Nothing here touches the Accessibility API, and nothing changes a menu
/// that is already on screen — see `menuNeedsUpdate` for why both matter.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var inventory = Inventory(items: [])
    private var settingsWindowController: SettingsWindowController?
    private var hotkey: GlobalHotkey?

    /// Last completed scan, including every item's full menu tree.
    ///
    /// Everything shown in the dropdown comes from here, so presenting it makes no
    /// cross-process calls. That is not just about speed: AX calls are synchronous IPC that
    /// pump the run loop, and making them from inside `NSMenu`'s tracking loop can cause
    /// AppKit to abandon tracking — the dropdown visibly flickering open and shut.
    ///
    /// Refreshed on a background queue after every open and whenever apps come or go.
    private var cachedInventory = Inventory(items: [])
    private var cachedTrust = AX.isTrusted
    private var rescanning = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var warmUpTimer: Timer?

    /// Links this item to `NSStatusItem Preferred Position IconsMenu` in our own defaults,
    /// which is how AppKit remembers where the user dragged it.
    private static let autosaveName = "IconsMenu"

    /// Carries a value type through `NSMenuItem.representedObject`, which needs an object.
    private final class Payload<Value>: NSObject {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    override init() {
        // Must precede creating the item — AppKit reads the stored position when
        // `autosaveName` is assigned, not later.
        MenuController.claimRightmostPositionOnFirstLaunch()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = MenuController.autosaveName
        statusItem.button?.image = IconArtwork.menuBarImage()
        statusItem.button?.toolTip =
            "Icons Menu — reach any menu bar item (\(GlobalHotkey.defaultShortcutDescription))"

        menu.delegate = self
        statusItem.menu = menu

        installHotkey()
        observeRunningApplications()
        startWarmUp()
    }

    deinit {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        warmUpTimer?.invalidate()
    }

    // MARK: - Inventory cache

    private func observeRunningApplications() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // A status item is not registered the instant its app launches.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated { self?.refreshInventoryInBackground() }
                    }
                }
            )
        }
    }

    /// Keeps retrying until there is something in the cache, then stops.
    ///
    /// The menu can no longer scan on demand, so the cache has to be warm before the user
    /// can open it. One attempt at launch is not enough: Accessibility may not be granted
    /// yet, in which case the scan finds nothing and there is no notification when the grant
    /// eventually arrives. Once warm, `menuDidClose` and the workspace notifications keep it
    /// current and this stops firing.
    private func startWarmUp() {
        refreshInventoryInBackground()

        warmUpTimer?.invalidate()
        warmUpTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }

                if self.cachedTrust, !self.cachedInventory.items.isEmpty {
                    timer.invalidate()
                    self.warmUpTimer = nil
                    return
                }
                self.refreshInventoryInBackground()
            }
        }
    }

    private func refreshInventoryInBackground() {
        cachedTrust = AX.isTrusted
        guard !rescanning, cachedTrust else { return }
        rescanning = true

        DispatchQueue.global(qos: .utility).async {
            let fresh = StatusItemScanner.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.cachedInventory = fresh
                    self.rescanning = false
                }
            }
        }
    }

    // MARK: - Staying reachable

    /// Sit as far right as the menu bar allows, so this app is the last thing to be pushed
    /// off when the bar overflows.
    ///
    /// `NSStatusItem Preferred Position` is a distance from a fixed right-hand anchor —
    /// measured across the running items, x + position is constant — so 0 means rightmost.
    /// Only seeded when absent: once the user has dragged the item somewhere, that is their
    /// decision and overwriting it every launch would be obnoxious.
    private static func claimRightmostPositionOnFirstLaunch() {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(0, forKey: key)
    }

    /// Being rightmost makes the icon unlikely to be pushed off-screen, but on a narrow or
    /// notched display it is still possible — and an unreachable IconsMenu defeats the
    /// entire point. The hotkey is the actual guarantee, since it pops the menu at the
    /// pointer where the icon's position is irrelevant.
    private func installHotkey() {
        hotkey = GlobalHotkey.defaultShortcut { [weak self] in
            MainActor.assumeIsolated { self?.popUpMenuAtPointer() }
        }
    }

    private func popUpMenuAtPointer() {
        // `popUp` refuses to run while the menu belongs to a status item, so hand it back
        // in `menuDidClose`.
        statusItem.menu = nil
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Menu construction

    /// The whole tree is built here, in one pass, from already-cached data.
    ///
    /// Two rules hold everything together, and violating either made the dropdown flicker
    /// open and shut: nothing mutates a menu that is already displayed, and nothing touches
    /// AX while a menu is open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildTopLevel(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }

        // Reclaim the menu after a hotkey-triggered pop-up detached it.
        if statusItem.menu == nil { statusItem.menu = menu }

        // Refreshed here rather than while building, so the scan is nowhere near the
        // tracking loop. Bounced through the next run loop turn because AppKit is still
        // tearing the menu down at this point.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.refreshInventoryInBackground() }
        }
    }

    /// Rebuilt on every open, so the menu can never show an item whose app has since quit.
    private func rebuildTopLevel(_ menu: NSMenu) {
        menu.removeAllItems()

        guard cachedTrust else {
            addPermissionPrompt(to: menu)
            addFooter(to: menu)
            return
        }

        // Strictly the cache — this must never scan. Scanning here is what made the first
        // open of a session flicker shut: a cold cache meant ~250ms of AX IPC inside the
        // tracking loop, and the open that blinked would warm the cache, so the second press
        // then worked. A warm-up timer keeps the cache populated instead.
        inventory = cachedInventory

        if inventory.items.isEmpty {
            menu.addItem(disabledItem(rescanning ? "Scanning menu bar…" : "No menu bar items found"))
        } else {
            // One flat alphabetical list. Splitting off-screen items into their own section
            // sounds useful but is not: every row works identically whether or not you can
            // see the icon, so the distinction tells you nothing actionable and costs two
            // headings plus a separator.
            addRows(for: inventory.items, to: menu)
        }

        addFooter(to: menu)
    }

    /// One row per application, not per item.
    ///
    /// Apps contributing several items get a single row with the items inside it — Control
    /// Center alone accounts for seven, which flat would fill a third of the dropdown.
    private func addRows(for items: [StatusItem], to menu: NSMenu) {
        let byApp = Dictionary(grouping: items, by: \.bundleID)
        var placed: Set<String> = []

        // Driven off `items` rather than the dictionary so bar order is preserved.
        for item in items where !placed.contains(item.bundleID) {
            placed.insert(item.bundleID)
            let group = byApp[item.bundleID] ?? [item]
            menu.addItem(group.count == 1 ? makeItem(for: item) : makeGroup(group))
        }
    }

    private func makeGroup(_ items: [StatusItem]) -> NSMenuItem {
        let first = items[0]
        let row = NSMenuItem(title: Inventory.displayName(for: first), action: nil, keyEquivalent: "")
        row.image = icon(forPID: first.pid)

        let submenu = newMenu()
        items.forEach { submenu.addItem(makeRow(for: $0, title: Inventory.itemName(for: $0))) }

        // No action on the group row itself: with several items behind it there is no single
        // thing "Control Center" could mean pressing.
        row.submenu = submenu
        return row
    }

    private func makeItem(for item: StatusItem) -> NSMenuItem {
        let menuItem = makeRow(for: item, title: Inventory.displayName(for: item))
        menuItem.image = icon(forPID: item.pid)
        return menuItem
    }

    /// A row is either a submenu of the item's mirrored menu, or — when it has none — a
    /// single click that presses the item.
    ///
    /// AppKit will happily deliver an action for a row that also has a submenu, so both were
    /// possible at once, but a row that acts on click *and* opens on hover is a confusing
    /// thing to aim at.
    private func makeRow(for item: StatusItem, title: String) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")

        if let entries = item.menu {
            row.submenu = makeSubmenu(entries)
        } else {
            row.action = #selector(activateItem(_:))
            row.target = self
            row.representedObject = Payload(item)
        }
        return row
    }

    /// Mirrors the source menu and nothing else — no synthesised rows of our own, so what
    /// you see is exactly what the application offers.
    ///
    /// The trade-off is that an item with a mirrorable menu no longer has a path to a plain
    /// press, which is the only thing that behaves *identically* to clicking the real icon.
    /// That matters for any item that does more on click than its menu implies.
    private func makeSubmenu(_ entries: [MirroredEntry]) -> NSMenu {
        let submenu = newMenu()
        append(entries, to: submenu)
        return submenu
    }

    /// Mirrors one level and recurses into any nested submenus. All of it comes from the
    /// cached tree, so this is pure local work — no IPC, nothing that can disturb tracking.
    private func append(_ entries: [MirroredEntry], to menu: NSMenu) {
        for entry in entries {
            guard !entry.isSeparator else {
                menu.addItem(.separator())
                continue
            }

            let menuItem = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = entry.isEnabled

            if entry.hasSubmenu {
                let nested = newMenu()
                append(entry.children, to: nested)
                menuItem.submenu = nested
            } else {
                menuItem.action = #selector(activateEntry(_:))
                menuItem.target = self
                menuItem.representedObject = Payload(entry)
            }

            menu.addItem(menuItem)
        }
    }

    /// Submenus get no delegate: there is nothing left to do when they open, and being
    /// called back during tracking is exactly what caused trouble before. `autoenablesItems`
    /// is off so the source menu's own enabled state is honoured rather than inferred from
    /// whether our selector exists.
    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    // MARK: - Chrome

    /// The owning application's icon, not a picture of the menu bar item itself — which is
    /// what keeps this app clear of needing Screen Recording permission.
    private func icon(forPID pid: pid_t) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        let sized = icon.copy() as! NSImage
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func addPermissionPrompt(to menu: NSMenu) {
        menu.addItem(disabledItem("Icons Menu needs Accessibility access"))

        let grant = NSMenuItem(
            title: "Open Privacy & Security…",
            action: #selector(requestAccessibilityAccess),
            keyEquivalent: ""
        )
        grant.target = self
        menu.addItem(grant)
    }

    private func addFooter(to menu: NSMenu) {
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Icons Menu", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Quit sits on its own, the way every other menu bar app separates it — it is the one
        // row here with a consequence.
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Icons Menu", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func activateItem(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload<StatusItem> else { return }
        ItemActivator.press(payload.value)
    }

    @objc private func activateEntry(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload<MirroredEntry> else { return }
        ItemActivator.press(entry: payload.value)
    }

    @objc private func requestAccessibilityAccess() {
        AX.checkTrust(prompt: true)
    }

    /// The standard About panel plus a credits line — name, version, icon and copyright all
    /// come from the bundle.
    ///
    /// Activating first is what an accessory app has to do: nothing else brings this process
    /// forward, so the panel would otherwise open behind whatever the user was looking at.
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "With help from Claude.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        ])
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
