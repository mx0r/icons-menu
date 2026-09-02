import AppKit

/// Another application's icon, sized for a row.
public enum AppIcon {

    /// A copy of the shared icon with a new *nominal* size, and every representation intact.
    ///
    /// The copy is not optional: `NSRunningApplication.icon` is shared, and setting a size on
    /// it changes that icon for everything else in the process.
    ///
    /// What matters more is what this does *not* do — it does not resample. An `.icns` holds
    /// separately drawn representations at 16, 32, 128, 256 and 512 points, each hinted for
    /// its size, and setting `size` only says which point size the image now claims to be.
    /// AppKit then picks the representation matching the device pixels it is about to fill:
    /// 16 points on a 1× display draws the 16-pixel artwork, on a 2× display the 32-pixel one.
    ///
    /// Anything that flattens the image first — drawing it into a bitmap of a chosen scale, or
    /// handing a view the 32-point original and letting the view squeeze it down — throws that
    /// choice away and leaves a resampled 20 pixels of a 32-pixel drawing. It looks passable
    /// on a Retina display, where there are twice as many pixels to hide it in, and obviously
    /// wrong on a 1× one beside it.
    public static func forProcess(_ pid: pid_t, size: CGFloat) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage
        else { return nil }

        icon.size = NSSize(width: size, height: size)
        return icon
    }
}
