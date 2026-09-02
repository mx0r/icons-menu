import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The app icon, drawn in code.
///
/// The mark is the menu bar itself — a rounded strip holding three items — with a dropdown
/// panel below it, which is what the app does. Small sizes swap the panel for a chevron,
/// because at 16pt a three-row list is mush.
public enum IconArtwork {

    /// Everything is laid out in this space and scaled, so the proportions hold at 16pt and
    /// at 1024pt alike.
    private static let canvas: CGFloat = 1024

    /// Below this pixel size the detailed dropdown panel stops being legible.
    private static let compactThreshold: CGFloat = 64

    // MARK: - Palette

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static let gradientTop = color(0x4C_6BEF)
    private static let gradientBottom = color(0x6D_3DE0)

    // MARK: - Menu bar glyph

    /// The status item's icon: the app icon's mark, reduced to what reads at 18pt.
    ///
    /// A template image, so macOS tints it — black on a light menu bar, white on a dark one,
    /// inverted while the menu is open. That is why this is drawn monochrome from scratch
    /// rather than scaling down the coloured artwork, which would ignore all of that and
    /// look wrong next to every other item in the bar.
    ///
    /// Carries the app icon's full motif — the strip, its three items, and the dropdown
    /// beneath — rather than the two-shape reduction the icon itself uses below 32pt. At
    /// 18pt the items do still resolve, and dropping them left something close enough to the
    /// stock `ellipsis.rectangle` to defeat the point of drawing it at all.
    public static func menuBarImage(height: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            drawMenuBarGlyph(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "IconsMenu"
        return image
    }

    private static func drawMenuBarGlyph(in rect: NSRect) {
        // Laid out in an 18pt square and scaled, matching the rest of this file.
        let scale = rect.height / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        NSColor.black.setFill()
        NSColor.black.setStroke()

        // Strip with its items knocked out, exactly as in the app icon.
        let strip = NSBezierPath(
            roundedRect: NSRect(
                x: rect.minX + 1 * scale,
                y: rect.minY + 9.5 * scale,
                width: 16 * scale,
                height: 6.5 * scale
            ),
            xRadius: 2.75 * scale,
            yRadius: 2.75 * scale
        )
        let dot = 1.8 * scale
        for x in [5.0, 9.0, 13.0] as [CGFloat] {
            strip.appendOval(in: NSRect(
                x: rect.minX + x * scale - dot / 2,
                y: rect.minY + 12.75 * scale - dot / 2,
                width: dot,
                height: dot
            ))
        }
        strip.windingRule = .evenOdd
        strip.fill()

        // Lighter than the strip, and tucked close so the two read as one mark.
        let dropdown = NSBezierPath()
        dropdown.move(to: point(6, 7))
        dropdown.line(to: point(9, 4))
        dropdown.line(to: point(12, 7))
        dropdown.lineWidth = 1.7 * scale
        dropdown.lineCapStyle = .round
        dropdown.lineJoinStyle = .round
        dropdown.stroke()
    }

    // MARK: - App icon rendering

    public static func cgImage(pixelSize: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        draw(in: context, pixelSize: CGFloat(pixelSize))
        return context.makeImage()
    }

    public static func pngData(pixelSize: Int) -> Data? {
        guard let image = cgImage(pixelSize: pixelSize) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func draw(in context: CGContext, pixelSize: CGFloat) {
        context.scaleBy(x: pixelSize / canvas, y: pixelSize / canvas)

        // Apple's icon grid leaves the rounded square inset from the canvas edge.
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(in: plate)

        context.saveGState()
        context.addPath(shape)
        context.clip()
        fillGradient(in: context, bounds: plate)
        addTopHighlight(in: context, bounds: plate)
        context.restoreGState()

        // A faint inner edge keeps the plate from dissolving into a dark wallpaper.
        context.saveGState()
        context.addPath(shape)
        context.setStrokeColor(color(0xFF_FFFF, alpha: 0.18))
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()

        context.setFillColor(color(0xFF_FFFF, alpha: 0.96))
        if pixelSize <= compactThreshold {
            drawCompactMark(in: context)
        } else {
            drawFullMark(in: context)
        }
    }

    private static func fillGradient(in context: CGContext, bounds: CGRect) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [gradientTop, gradientBottom] as CFArray,
            locations: [0, 1]
        ) else { return }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: bounds.maxY),
            end: CGPoint(x: bounds.midX, y: bounds.minY),
            options: []
        )
    }

    private static func addTopHighlight(in context: CGContext, bounds: CGRect) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(0xFF_FFFF, alpha: 0.14), color(0xFF_FFFF, alpha: 0)] as CFArray,
            locations: [0, 1]
        ) else { return }

        // Confined to the top quarter — any further down and it reads as dated gloss.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.midX, y: bounds.maxY),
            end: CGPoint(x: bounds.midX, y: bounds.maxY - bounds.height * 0.25),
            options: []
        )
    }

    // MARK: - The mark

    /// Menu bar strip above a dropdown panel. Both are filled with `evenOdd` so the items
    /// and rows are knocked out of the white, letting the gradient read through them.
    ///
    /// The group is centred on the plate as a whole rather than each piece being placed
    /// independently, which is what keeps the empty space above and below it even.
    private static func drawFullMark(in context: CGContext) {
        let bar = CGRect(x: 282, y: 592, width: 460, height: 118)
        let path = CGMutablePath()
        path.addRoundedRect(in: bar, cornerWidth: 59, cornerHeight: 59)
        for x in [392.0, 512.0, 632.0] {
            path.addEllipse(in: dot(atX: CGFloat(x), y: bar.midY, radius: 24))
        }

        // A 28pt gap and a panel two thirds the bar's width read as one thing hanging off
        // the other. Wider spacing made them look like two unrelated stacked blocks.
        let panel = CGRect(x: 362, y: 314, width: 300, height: 250)
        path.addRoundedRect(in: panel, cornerWidth: 52, cornerHeight: 52)
        for y in [362.0, 426.0, 490.0] {
            path.addRoundedRect(
                in: CGRect(x: panel.minX + 58, y: CGFloat(y), width: 184, height: 26),
                cornerWidth: 13,
                cornerHeight: 13
            )
        }

        context.addPath(path)
        context.fillPath(using: .evenOdd)
    }

    /// At 16 and 32pt the panel's rows disappear and the bar's three items smear into one
    /// white blob, so the mark drops to two shapes — a solid strip and a chevron — and both
    /// grow. Detail that cannot be resolved is worse than no detail, because it reads as
    /// blur rather than as a smaller version of the same icon.
    private static func drawCompactMark(in context: CGContext) {
        let bar = CGRect(x: 230, y: 594, width: 564, height: 150)
        context.addPath(CGPath(
            roundedRect: bar, cornerWidth: 75, cornerHeight: 75, transform: nil
        ))
        context.fillPath()

        context.saveGState()
        context.setStrokeColor(color(0xFF_FFFF, alpha: 0.96))
        context.setLineWidth(90)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: 330, y: 474))
        context.addLine(to: CGPoint(x: 512, y: 324))
        context.addLine(to: CGPoint(x: 694, y: 474))
        context.strokePath()
        context.restoreGState()
    }

    private static func dot(atX x: CGFloat, y: CGFloat, radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }

    // MARK: - Geometry

    /// A superellipse, which is much closer to the shape macOS uses for app icons than a
    /// plain rounded rectangle — the corners ease in rather than meeting an arc abruptly.
    private static func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
        let path = CGMutablePath()
        let a = Double(rect.width / 2)
        let b = Double(rect.height / 2)
        let power = 2 / exponent
        let steps = 512

        for step in 0...steps {
            let t = Double(step) / Double(steps) * 2 * .pi
            let x = Double(rect.midX) + a * copysign(pow(abs(cos(t)), power), cos(t))
            let y = Double(rect.midY) + b * copysign(pow(abs(sin(t)), power), sin(t))
            let point = CGPoint(x: x, y: y)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }

        path.closeSubpath()
        return path
    }
}
