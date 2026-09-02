import AppKit
import ServiceManagement

/// The app's own login item, registered through `SMAppService.mainApp`.
///
/// No helper bundle and no `LaunchAgents` plist: the app registers *itself*, and macOS keys
/// the registration to the bundle it was made from. That is worth knowing — a copy in
/// `/Applications` is the one to switch this on for, because a build in `.build/` registers
/// that path and quietly stops opening once the build is replaced.
@MainActor
final class LaunchAtLogin: ObservableObject {

    @Published private(set) var isEnabled = false

    /// Anything the switch alone cannot convey: approval pending in System Settings, or a
    /// refusal from macOS. Shown rather than swallowed, since the switch snapping back with
    /// no explanation is the worst version of this.
    @Published private(set) var notice: String?

    private let approvalNotice = "Waiting for approval in Login Items."

    init() {
        refresh()
    }

    /// The switch can also be thrown from System Settings, and nothing notifies us when it
    /// is, so the view re-reads on every appearance and activation.
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled

        if status == .requiresApproval {
            notice = approvalNotice
        } else if notice == approvalNotice {
            notice = nil
        }
    }

    func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                // Registering something already registered throws, and the status can sit at
                // `.requiresApproval` while the user has it switched off in Login Items.
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            notice = nil
        } catch {
            notice = "macOS refused: \(error.localizedDescription)"
        }
        // Never trusts the call's success as the new state — `.requiresApproval` is a
        // successful register that did not enable anything.
        refresh()
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
