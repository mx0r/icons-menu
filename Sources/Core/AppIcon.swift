import AppKit

/// Another application's icon, sized for a row.
public enum AppIcon {

    /// Read from the application's own `.icns` where there is one, and only otherwise from
    /// `NSRunningApplication.icon`.
    ///
    /// The detour exists because of what that property hands back: `NSISIconImageRep`, an
    /// IconServices representation that renders lazily, out of a shared cache, at draw time.
    /// Reading the file gives ImageIO-decoded bitmaps instead — the same artwork, resolved
    /// when we ask for it rather than when something else gets round to it.
    ///
    /// The suspicion this addresses: on one rotated 1× display some icons — never all of
    /// them, and never the same ones on another screen — draw as horizontal streaks of the
    /// right colours. The representations themselves are provably fine; dumped to PNG at
    /// their native sizes they are exactly what they should be. What differs is who
    /// rasterises them and when.
    ///
    /// Whatever the source, the image is a copy — `NSRunningApplication.icon` is shared, and
    /// setting a size on it changes that icon everywhere in the process — and it is only ever
    /// given a new *nominal* size, never resampled. An `.icns` holds separately drawn artwork
    /// at 16, 32, 128, 256 and 512 points, and setting `size` leaves AppKit free to pick the
    /// one matching the device pixels it is about to fill.
    public static func forProcess(_ pid: pid_t, size: CGFloat) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard let icon = fromBundle(app) ?? (app.icon?.copy() as? NSImage) else { return nil }

        icon.size = NSSize(width: size, height: size)
        return icon
    }

    private static func fromBundle(_ app: NSRunningApplication) -> NSImage? {
        guard
            let url = app.bundleURL,
            let bundle = Bundle(url: url),
            var name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        else { return nil }

        // CFBundleIconFile is written both ways round.
        if !name.lowercased().hasSuffix(".icns") { name += ".icns" }

        guard
            let file = bundle.url(forResource: name, withExtension: nil),
            let image = NSImage(contentsOf: file)
        else { return nil }

        return image
    }
}
