import AppKit

/// Another application's icon, sized for a row.
public enum AppIcon {

    /// One source image per application, since decoding is the expensive part and the panel
    /// redraws every row on every keystroke.
    ///
    /// Main thread only, which is where every caller draws.
    private static var sources: [String: NSImage] = [:]

    /// Read from the application's own artwork, and only otherwise from
    /// `NSRunningApplication.icon`.
    ///
    /// The detour exists because of what that property hands back: `NSISIconImageRep`, an
    /// IconServices representation rendered lazily, out of a shared cache, at draw time. On
    /// one rotated 1× display some of those drew as horizontal streaks of the right colours —
    /// never all of them, and never the same ones on another screen — while the same
    /// representations dumped to PNG were provably correct. `NSWorkspace.icon(forFile:)` is no
    /// help here: it returns IconServices representations too.
    ///
    /// Whatever the source, the returned image is a copy — the cached one is shared, and
    /// `NSRunningApplication.icon` is shared process-wide, so setting a size in place would
    /// change that icon everywhere — and it is only ever given a new *nominal* size, never
    /// resampled. An `.icns` holds separately drawn artwork at 16, 32, 128, 256 and 512
    /// points; setting `size` leaves AppKit free to pick the one matching the device pixels it
    /// is about to fill.
    public static func forProcess(_ pid: pid_t, size: CGFloat) -> NSImage? {
        guard
            let app = NSRunningApplication(processIdentifier: pid),
            let source = source(for: app),
            let icon = source.copy() as? NSImage
        else { return nil }

        icon.size = NSSize(width: size, height: size)
        return icon
    }

    private static func source(for app: NSRunningApplication) -> NSImage? {
        let key = app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
        if let cached = sources[key] { return cached }

        guard let source = fromBundle(app) ?? app.icon else { return nil }
        sources[key] = source
        return source
    }

    private static func fromBundle(_ app: NSRunningApplication) -> NSImage? {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return nil }

        // The classic layout: an .icns in Resources, decoded by ImageIO.
        if let declared = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            // CFBundleIconFile is written both with and without the extension.
            let name = declared.lowercased().hasSuffix(".icns") ? declared : declared + ".icns"

            if let file = bundle.url(forResource: name, withExtension: nil),
                let image = NSImage(contentsOf: file)
            {
                return image
            }
        }

        // The modern one: the icon lives in Assets.car, and `Bundle` reads it through AppKit's
        // asset loader, which yields ordinary bitmap representations. Worth having rather than
        // falling through — several menu bar apps ship no .icns at all, `WeatherMenu.app`
        // among them, and it was one of the icons that streaked.
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
            let image = bundle.image(forResource: name)
        {
            return image
        }

        return nil
    }
}
