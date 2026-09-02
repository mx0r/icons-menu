import AppKit

@main
@MainActor
enum IconsMenuApp {
    static func main() {
        let app = NSApplication.shared
        // Menu bar only: no Dock icon, no app switcher entry. LSUIElement in Info.plist
        // covers this too, but setting it here keeps `swift run`-style launches honest.
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication holds its delegate weakly.
        retainedDelegate = delegate

        app.run()
    }

    private static var retainedDelegate: AppDelegate?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = MenuController()

        // Prompting on first launch is the only way to explain why the app looks empty.
        // The menu itself handles the untrusted case, so this is a nudge, not a gate.
        if !AX.isTrusted {
            AX.checkTrust(prompt: true)
            waitForTrust()
        }
    }

    /// The grant arrives without any notification, so poll until it does, then stop.
    ///
    /// Nothing needs rebuilding when it lands — the menu rescans every time it opens — so
    /// this exists only to stop the poller. The run loop retains the timer, hence no stored
    /// reference.
    private func waitForTrust() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard AX.isTrusted else { return }
            timer.invalidate()
        }
    }
}
