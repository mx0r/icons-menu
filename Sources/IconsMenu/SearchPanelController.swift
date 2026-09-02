import AppKit
// For the `kVK_` key codes, the same ones the hotkey recorder reads.
import Carbon.HIToolbox

/// Borderless windows refuse key focus unless they say otherwise, and without key focus
/// there is nothing to type into.
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The hotkey's destination: a search field over the whole menu bar tree.
///
/// Separate from the dropdown on purpose. `NSMenu` owns its own tracking loop — keystrokes go
/// to the menu rather than to us, and mutating a menu that is on screen is what made this app
/// flicker in the first place — so filtering lives in a panel of our own, built from the same
/// cache the dropdown is built from.
@MainActor
final class SearchPanelController {

    private let model: SearchModel
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    /// True for a moment after opening, while activation settles. See `observeDismissal`.
    private var isSettling = false

    /// Whether opening the panel had to bring the app forward, and so whether closing it
    /// should hand the front back.
    private var didActivate = false

    init(inventory: @escaping () -> Inventory) {
        model = SearchModel(inventory: inventory)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.reset()
        model.reload()

        // Rebuilt every time rather than kept around: it costs a few milliseconds and it is
        // the reliable way to have the text field come up focused and empty.
        let panel = makePanel()
        self.panel = panel

        position(panel)

        // A `.nonactivatingPanel` can take key focus without bringing the app forward, which
        // is what keeps the app you were using from losing its own focus ring. If the window
        // server declines, take the visible activation rather than a panel nobody can type
        // into.
        panel.makeKeyAndOrderFront(nil)
        didActivate = false
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            didActivate = true
        }

        // Only now: a text field cannot become first responder before its window is on screen.
        (panel.contentView as? SearchPanelContentView)?.focusField()

        observeKeys()
        observeDismissal()
    }

    func hide() {
        guard panel != nil else { return }

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil

        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil

        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
        deactivationObserver = nil

        panel?.orderOut(nil)
        panel = nil

        // Hand the front back to whatever the user was in. Only when opening took it: an
        // accessory app that stays active after its panel closes leaves the previous app
        // looking focused while its keystrokes go nowhere.
        if didActivate {
            didActivate = false
            NSApp.deactivate()
        }
    }

    // MARK: - The panel

    private func makePanel() -> NSPanel {
        let panel = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        // Follows the user to whatever space they are on, and works over a full-screen app.
        // Explicitly *not* `.transient`, which asks AppKit to hide the window whenever the app
        // is not active — a promise it can keep in the middle of the app becoming active.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.contentView = SearchPanelContentView(model: model) { [weak self] in self?.hide() }
        return panel
    }

    /// Centred on the screen holding the pointer, a third of the way down — where Spotlight
    /// and everything like it puts itself, and far enough from the menu bar not to read as
    /// hanging off the icon.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - visible.height * 0.16
            )
        )
    }

    // MARK: - Keys

    /// A local monitor, because the panel is ours and key: every keystroke arrives here before
    /// the text field sees it. Navigation keys are swallowed; everything else falls through so
    /// typing still reaches the field.
    private func observeKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)

        if command, let action = editingAction(for: event) {
            // An LSUIElement app has no main menu, and ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z are menu key
            // equivalents rather than key bindings — with no menu to carry them, AppKit never
            // dispatches them and the field appears to ignore the standard shortcuts. Sending
            // them to the responder chain by hand is what a menu would have done.
            NSApp.sendAction(action, to: nil, from: nil)
            return true
        }

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            if command { model.moveToEdge(1) } else { model.move(by: 1, wrapping: true) }
            return true

        case kVK_UpArrow:
            if command { model.moveToEdge(-1) } else { model.move(by: -1, wrapping: true) }
            return true

        case kVK_PageDown:
            model.move(by: 8)
            return true

        case kVK_PageUp:
            model.move(by: -8)
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.activateSelection() { hide() }
            return true

        case kVK_Escape:
            // Out of the application first, out of the panel second: one key, one step back
            // each time, which is what Escape means everywhere else.
            if !model.leaveScope() { hide() }
            return true

        case kVK_Delete where model.query.isEmpty:
            _ = model.leaveScope()
            return true

        default:
            return false
        }
    }

    /// The field editor implements all of these; they just need something to deliver them.
    /// Selectors by name because `#selector(NSText.copy(_:))` collides with `NSObject.copy()`.
    private func editingAction(for event: NSEvent) -> Selector? {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": return Selector(("selectAll:"))
        case "c": return Selector(("copy:"))
        case "v": return Selector(("paste:"))
        case "x": return Selector(("cut:"))
        case "z": return event.modifierFlags.contains(.shift)
            ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    /// Closing on a click elsewhere or on the app losing the front — deliberately *not* on the
    /// panel resigning key.
    ///
    /// Bringing an accessory app forward churns key status for a moment after the panel opens,
    /// and a resign delivered during that churn shut the panel the instant it appeared. It
    /// only ever happened on the first press of the hotkey, because the second one found the
    /// app already active with nothing left to settle — the same shape as the dropdown's old
    /// open-and-shut flicker, and the same lesson: do not act on state that is still moving.
    ///
    /// The settling window covers the other half of it: activation itself can arrive as a
    /// deactivation first.
    private func observeDismissal() {
        isSettling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.isSettling = false }
        }

        // Global monitors see only what happens in *other* applications, which is exactly the
        // "clicked somewhere else" the panel should close for. Clicks inside it are local
        // events and never arrive here.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUnlessSettling() }
        }

        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUnlessSettling() }
        }
    }

    private func dismissUnlessSettling() {
        guard !isSettling else { return }
        hide()
    }
}
