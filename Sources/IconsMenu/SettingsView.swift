import AppKit
import SwiftUI

/// Live view of what is on the menu bar. Rescans on demand and whenever apps come and go.
@MainActor
final class InventoryModel: ObservableObject {

    @Published private(set) var inventory = Inventory(items: [])
    @Published private(set) var isTrusted = AX.isTrusted

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // Items are not registered the instant an app launches.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
                }
            )
        }
        refresh()
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func refresh() {
        isTrusted = AX.isTrusted
        inventory = isTrusted ? StatusItemScanner.scan() : Inventory(items: [])
    }
}

struct SettingsView: View {

    @StateObject private var model = InventoryModel()

    var body: some View {
        VStack(spacing: 0) {
            if model.isTrusted {
                itemList
            } else {
                permissionNotice
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private var itemList: some View {
        List {
            if !model.inventory.unreachable.isEmpty {
                Section("Off-screen — unreachable by clicking") {
                    ForEach(model.inventory.unreachable) { row(for: $0) }
                }
            }
            Section("In the menu bar") {
                ForEach(model.inventory.reachable) { row(for: $0) }
            }
        }
    }

    private func row(for item: StatusItem) -> some View {
        HStack(spacing: 10) {
            if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.inventory.qualifiedName(for: item))
                Text(item.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let frame = item.frame {
                Text("x \(Int(frame.origin.x))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("Open") { ItemActivator.press(item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var permissionNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Accessibility access required")
                .font(.headline)
            Text("IconsMenu reads and presses menu bar items through the Accessibility API. "
                 + "Without this permission it cannot see any of them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy & Security…") { AX.checkTrust(prompt: true) }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Rescan") { model.refresh() }
        }
        .padding(10)
    }

    private var summary: String {
        guard model.isTrusted else { return "Not authorised" }
        let total = model.inventory.items.count
        let hidden = model.inventory.unreachable.count
        return hidden == 0
            ? "\(total) items, all reachable"
            : "\(total) items, \(hidden) off-screen"
    }
}

/// Plain `NSWindowController` rather than a SwiftUI `Settings` scene — an `LSUIElement` app
/// has no main menu, so the standard Settings scene has no reliable way to be opened.
@MainActor
final class SettingsWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IconsMenu"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        // Accessory apps are not activated by default, so the window would open behind
        // whatever the user was using.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
