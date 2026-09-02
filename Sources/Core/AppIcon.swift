import AppKit

/// Another application's icon, sized for a row.
public enum AppIcon {

    /// A copy with one bitmap per attached display scale.
    ///
    /// Three things this is working around, all of which look the same on screen — a garbled
    /// icon that is really a fragment of one drawn at the wrong scale:
    ///
    /// - `NSRunningApplication.icon` is *shared*. Setting a size on it changes it for every
    ///   other user of that icon in the process.
    /// - Handing a view the 1024pt master and letting it squeeze that into 20pt leaves the
    ///   choice of representation, and the scale it is rasterised at, to whatever the view
    ///   happens to know at the time.
    /// - A drawing-handler image (`NSCustomImageRep`) is supposed to be re-run per scale, and
    ///   is not reliably re-run when a window moves between displays of different scale.
    ///
    /// Explicit bitmaps sidestep all of it: the image carries a representation for each scale
    /// in use, and AppKit picks between them the way it does for any ordinary image.
    public static func forProcess(_ pid: pid_t, size: CGFloat) -> NSImage? {
        guard let source = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        return resized(source, to: size)
    }

    static func resized(_ source: NSImage, to size: CGFloat) -> NSImage {
        let points = NSSize(width: size, height: size)
        let image = NSImage(size: points)

        for scale in scalesInUse() {
            guard let rep = bitmap(of: source, points: points, scale: scale) else { continue }
            image.addRepresentation(rep)
        }

        // Nothing was drawn — no displays, or a source that refuses to draw. A blurry icon
        // beats none.
        if image.representations.isEmpty {
            let copy = source.copy() as! NSImage
            copy.size = points
            return copy
        }
        return image
    }

    /// Every backing scale currently attached, so an icon made on the laptop still has a 1×
    /// representation for the external display next to it. 2× is always included: displays
    /// come and go, and the panel outlives the moment it was built in.
    private static func scalesInUse() -> [CGFloat] {
        let attached = NSScreen.screens.map(\.backingScaleFactor)
        return Array(Set(attached + [2])).sorted()
    }

    private static func bitmap(
        of source: NSImage,
        points: NSSize,
        scale: CGFloat
    ) -> NSBitmapImageRep? {
        let pixels = NSSize(width: points.width * scale, height: points.height * scale)

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixels.width),
                pixelsHigh: Int(pixels.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }

        // The point size is what makes this a `scale`× representation rather than a larger
        // 1× one; without it AppKit would draw the 2× bitmap at twice the size.
        rep.size = points

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: points),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }
}
