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

    /// Held so it can be cancelled: a close and reopen inside the settling window would
    /// otherwise have the first open's timer end the second one's grace period.
    private var settleWork: DispatchWorkItem?

    private var keyWindowObserver: NSObjectProtocol?

    /// Whether opening the panel had to bring the app forward, and so whether closing it
    /// should hand the front back.
    private var didActivate = false

    init(inventory: @escaping () -> Inventory) {
        model = SearchModel(inventory: inventory)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        for observer in [deactivationObserver, keyWindowObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        settleWork?.cancel()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        // One pass: clearing the query and scope and *then* rebuilding would filter the
        // previous session's rows twice on the way, against applications that may have quit.
        model.prepare()

        // Rebuilt every time rather than kept around: it costs a few milliseconds and it is
        // the reliable way to have the text field come up focused and empty.
        let panel = makePanel()
        self.panel = panel

        // Activation first, unconditionally.
        //
        // `isKeyWindow` is not the question it looks like: key window is per application, so
        // a panel ordered front by a background app reports true while the window server goes
        // on delivering every keystroke to whatever is actually frontmost — a panel that looks
        // focused and swallows nothing. A `.nonactivatingPanel` can take key without
        // activating, but only when the *user* clicks it; ordering one front from a hotkey is
        // not that. Typing has to work, so the app comes forward, and `hide` hands the front
        // back afterwards.
        // Only counts as ours to give back if we were not already frontmost — otherwise
        // closing the panel would push aside a window of ours that was already in use, the
        // Settings window being the obvious one.
        didActivate = !NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Activation is not finished when it returns. Re-asserted a turn later, together with
        // the focus: a field made first responder while the app is still coming forward ends
        // up with no field editor attached, which is the same symptom — a caret that blinks
        // and a field that never sees a key.
        // Weakly, and only if this is still *the* panel: `hide` can run before these turns —
        // a second hotkey press, or a dismissal delivered in the same pass — and ordering a
        // window front after that would leave one on screen with every monitor already torn
        // down and nothing left that could close it.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }

            panel.makeKeyAndOrderFront(nil)
            let content = panel.contentView as? SearchPanelContentView
            content?.focusField()

            // One more turn if it did not take. Activation timing is not something to be
            // clever about, and the cost of being wrong is a panel that ignores the keyboard.
            guard content?.isFieldFocused == false else { return }
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.panel === panel else { return }
                panel.makeKeyAndOrderFront(nil)
                content?.focusField()
            }
        }

        observeKeys()
        observeDismissal()

        // After a beat, so the rows have drawn at least once. No-op unless the diagnostics
        // default is set.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, self.panel === panel else { return }
                (panel.contentView as? SearchPanelContentView)?.captureDiagnostic()
            }
        }
    }

    func hide() {
        guard panel != nil else { return }

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil

        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil

        for observer in [deactivationObserver, keyWindowObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        deactivationObserver = nil
        keyWindowObserver = nil

        settleWork?.cancel()
        settleWork = nil
        isSettling = false

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
        // Born where it will be shown, rather than created at the origin and moved there.
        // A window created on one display and moved to another with a different backing scale
        // keeps rasterised content from the display it was born on — which is what turned the
        // row icons into fragments of themselves on the second screen.
        let panel = SearchPanel(
            contentRect: frameForCurrentScreen(),
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

    /// Centred on the screen holding the pointer, a sixth of the way down — where Spotlight
    /// and everything like it puts itself, and far enough from the menu bar not to read as
    /// hanging off the icon.
    private func frameForCurrentScreen() -> NSRect {
        let size = NSSize(width: 620, height: 440)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main

        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }

        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.16,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Keys

    /// A local monitor, because the panel is ours and key: every keystroke arrives here before
    /// the text field sees it. Navigation keys are swallowed; everything else falls through so
    /// typing still reaches the field.
    private func observeKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Scoped to the panel's own window. A local monitor sees every key the *app*
            // receives, so without this the panel would go on swallowing arrows and Return
            // typed into the Settings window — and act on them.
            guard let self, let panel = self.panel, event.window === panel else { return event }
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
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.isSettling = false }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)

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

        // Another window of ours taking key — Settings, opened from the menu while the panel
        // is up. Neither of the two above fires for that: the click is a local event, and the
        // app never resigns active.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow,
                    window !== self.panel
                else { return }
                self.dismissUnlessSettling()
            }
        }
    }

    private func dismissUnlessSettling() {
        guard !isSettling else { return }
        hide()
    }
}
