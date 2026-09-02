import AppKit
// For the `kVK_` key codes, the same ones the hotkey recorder reads.
import Carbon.HIToolbox
import SwiftUI

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
    private var resignObserver: NSObjectProtocol?

    init(inventory: @escaping () -> Inventory) {
        model = SearchModel(inventory: inventory)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
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
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }

        observeKeys()
        observeResignation(of: panel)
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil

        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil

        panel?.orderOut(nil)
        panel = nil
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
        // Follows the user to whatever space they are on, and never shows up in Exposé as a
        // window of its own.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = SearchPanelView(model: model) { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: view)
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

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            if command { model.moveToEdge(1) } else { model.move(by: 1) }
            return true

        case kVK_UpArrow:
            if command { model.moveToEdge(-1) } else { model.move(by: -1) }
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

    private func observeResignation(of panel: NSPanel) {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}
