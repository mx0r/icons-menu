// iconforge — renders Resources/AppIcon.icns from IconArtwork.
//
// Run via `make icon`. Committed output, so a normal build never needs this target; it only
// runs when the artwork changes.

import AppKit
import Foundation

/// The exact set `iconutil` expects, and the filenames it matches on.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources")

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
let icns = outputDirectory.appendingPathComponent("AppIcon.icns")

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
// Stale variants would survive into the .icns, so start from an empty iconset.
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    guard let png = IconArtwork.pngData(pixelSize: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
    print("  \(variant.name).png  \(variant.pixels)px  \(png.count / 1024)KB")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", icns.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// The iconset is an intermediate; only the .icns is referenced by the bundle.
try? FileManager.default.removeItem(at: iconset)

let attributes = try? FileManager.default.attributesOfItem(atPath: icns.path)
let bytes = (attributes?[.size] as? Int) ?? 0
print("wrote \(icns.path)  \(bytes / 1024)KB")
