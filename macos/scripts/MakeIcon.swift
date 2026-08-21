import AppKit
import Foundation

@main
enum MakeIcon {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            fputs("usage: MakeIcon <source-png> <output-icns>\n", stderr)
            exit(1)
        }

        let sourceURL = URL(fileURLWithPath: arguments[1])
        let icnsURL = URL(fileURLWithPath: arguments[2])

        guard let source = NSImage(contentsOf: sourceURL) else {
            fputs("MakeIcon: failed to load \(sourceURL.path)\n", stderr)
            exit(1)
        }

        let transparent = punchingNearBlack(from: source)
        let padded = compositingOnWhite(transparent, canvas: 1024, logoRatio: 0.72)

        let iconset = icnsURL.deletingLastPathComponent()
            .appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        let sizes: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]

        for entry in sizes {
            let resized = resizing(padded, to: entry.pixels)
            let url = iconset.appendingPathComponent(entry.name)
            try! pngData(from: resized).write(to: url)
        }

        let preview = icnsURL.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png")
        try! pngData(from: padded).write(to: preview)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", "-o", icnsURL.path, iconset.path]
        try! process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            fputs("MakeIcon: iconutil failed\n", stderr)
            exit(1)
        }
    }

    /// Treat near-black pixels as background / belly cutout so they become transparent.
    /// Navy whale (~#000B3F) is kept because its blue channel sits well above this floor.
    private static func punchingNearBlack(from image: NSImage) -> NSImage {
        let width = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        let height = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
        let rep = makeBitmap(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return imageFrom(rep) }
        let stride = rep.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                let r = data[i]
                let g = data[i + 1]
                let b = data[i + 2]
                let a = data[i + 3]
                let isBackdrop = r < 20 && g < 20 && b < 30
                if isBackdrop || a < 12 {
                    data[i] = 0
                    data[i + 1] = 0
                    data[i + 2] = 0
                    data[i + 3] = 0
                } else {
                    data[i + 3] = 255
                }
            }
        }
        return imageFrom(rep)
    }

    private static func compositingOnWhite(_ logo: NSImage, canvas: Int, logoRatio: CGFloat) -> NSImage {
        let rep = makeBitmap(width: canvas, height: canvas)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

        let inset = CGFloat(canvas) * (1 - logoRatio) / 2
        let dest = NSRect(
            x: inset,
            y: inset,
            width: CGFloat(canvas) - inset * 2,
            height: CGFloat(canvas) - inset * 2
        )
        logo.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return imageFrom(rep)
    }

    private static func resizing(_ image: NSImage, to pixels: Int) -> NSImage {
        let rep = makeBitmap(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return imageFrom(rep)
    }

    private static func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
    }

    private static func imageFrom(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    private static func pngData(from image: NSImage) -> Data {
        guard
            let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
            let data = rep.representation(using: .png, properties: [:])
        else {
            fputs("MakeIcon: failed to encode PNG\n", stderr)
            exit(1)
        }
        return data
    }
}
