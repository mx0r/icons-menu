import AppKit

/// Another application's icon, sized for a row.
public enum AppIcon {

    /// Two things this deliberately avoids.
    ///
    /// It never hands back `NSRunningApplication.icon` itself: that image is shared, and
    /// setting a size on it changes it for every other user of the same icon in the process.
    ///
    /// And it never bakes a bitmap. The copy is drawn through a block, which makes it an
    /// `NSCustomImageRep` that AppKit re-runs for whatever backing scale it is about to be
    /// drawn at — so the same image is sharp on a Retina display and on a 1× one beside it.
    /// A window that moves between the two, which the search panel does every time it opens
    /// where the pointer is, is exactly where a fixed bitmap turns to mush: the 1024pt master
    /// squeezed into 20pt by the image view, with whatever interpolation happened to be set.
    public static func forProcess(_ pid: pid_t, size: CGFloat) -> NSImage? {
        guard let source = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }

        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
