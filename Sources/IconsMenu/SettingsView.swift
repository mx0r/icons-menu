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

/// One application's presence in the menu bar — the granularity the dropdown groups at, and
/// the granularity hiding works at.
private struct AppEntry: Identifiable {
    let bundleID: String
    let name: String
    let pid: pid_t
    let itemCount: Int
    let offScreenCount: Int

    var id: String { bundleID }
}

struct SettingsView: View {

    @StateObject private var model = InventoryModel()
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        VStack(spacing: 0) {
            if model.isTrusted {
                appList
            } else {
                permissionNotice
            }
            Divider()
            settings
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 420)
        // Login Items can be changed from System Settings, and nothing tells us when it is.
        .onAppear { launchAtLogin.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in launchAtLogin.refresh() }
    }

    /// One row per application, matching the dropdown, with a switch that keeps it out.
    ///
    /// The switch is the point of this list. What used to be here — an "Open" button per
    /// item, each item's x position, a separate section for off-screen items — was a view of
    /// the same data the menu already presents better, so it has gone. Off-screen is still
    /// worth knowing and survives as a caption.
    private var appList: some View {
        List {
            Section("Show in the menu") {
                ForEach(apps) { row(for: $0) }
            }
        }
    }

    /// Annotated at every step: left to infer, this expression is one the type checker spends
    /// an absurd amount of time on.
    private var apps: [AppEntry] {
        let byApp: [String: [StatusItem]] = Dictionary(
            grouping: model.inventory.items,
            by: \.bundleID
        )
        let entries: [AppEntry] = byApp.map { bundleID, items in
            AppEntry(
                bundleID: bundleID,
                name: Inventory.displayName(for: items[0]),
                pid: items[0].pid,
                itemCount: items.count,
                offScreenCount: items.filter { !$0.isOnScreen }.count
            )
        }
        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func row(for app: AppEntry) -> some View {
        HStack(spacing: 10) {
            if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(subtitle(for: app))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(
                "Show \(app.name) in the menu",
                isOn: Binding(
                    get: { !preferences.isHidden(app.bundleID) },
                    set: { preferences.setHidden(!$0, for: app.bundleID) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for app: AppEntry) -> String {
        var parts = [app.bundleID]
        if app.itemCount > 1 { parts.append("\(app.itemCount) items") }
        if app.offScreenCount > 0 {
            parts.append(
                app.offScreenCount == app.itemCount
                    ? "off-screen"
                    : "\(app.offScreenCount) off-screen"
            )
        }
        return parts.joined(separator: " · ")
    }

    private var permissionNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Accessibility access required")
                .font(.headline)
            Text("Icons Menu reads and presses menu bar items through the Accessibility API. "
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

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Shortcut")
                HotkeyRecorder(shortcut: $preferences.hotkey)
            }

            Toggle(
                "Open Icons Menu at login",
                isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) })
            )

            if let notice = launchAtLogin.notice {
                HStack(spacing: 6) {
                    Text(notice)
                    Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // The only way back for an app that has since quit: hidden but with no row to
            // switch on, it would otherwise stay hidden forever.
            if !preferences.hiddenBundleIDs.isEmpty {
                Button("Show all") { preferences.showAll() }
            }
            Button("Rescan") { model.refresh() }
        }
        .padding(10)
    }

    private var summary: String {
        guard model.isTrusted else { return "Not authorised" }
        let count = apps.count
        let hidden = preferences.hiddenBundleIDs.count
        return hidden == 0
            ? "\(count) applications"
            : "\(count) applications, \(hidden) hidden"
    }
}

/// Plain `NSWindowController` rather than a SwiftUI `Settings` scene — an `LSUIElement` app
/// has no main menu, so the standard Settings scene has no reliable way to be opened.
@MainActor
final class SettingsWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Icons Menu"
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
