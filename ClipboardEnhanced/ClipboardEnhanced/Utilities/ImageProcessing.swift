//
//  ImageProcessing.swift
//  ClipboardEnhanced
//
//  Normalisation PNG, vignettes et icônes fichier.
//

import AppKit

enum ImageProcessing {
    /// Taille max d'une image stockée (octets PNG). Au-delà : ignorée.
    static let maxImageBytes = 10 * 1024 * 1024

    /// Dimension max (px) d'une vignette.
    static let thumbnailMaxDimension: CGFloat = 300

    // MARK: - Images

    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Encode l'image en PNG (format de stockage normalisé).
    static func normalizedPNG(from image: NSImage) -> Data? {
        bitmap(from: image)?.representation(using: .png, properties: [:])
    }

    /// Libellé « L × H » en pixels.
    static func dimensionLabel(from image: NSImage) -> String {
        guard let rep = bitmap(from: image) else { return "Image" }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }

    /// Vignette PNG réduite à `thumbnailMaxDimension`, en conservant le ratio.
    static func thumbnailPNG(from image: NSImage) -> Data? {
        guard let source = bitmap(from: image) else { return nil }
        let width = CGFloat(source.pixelsWide)
        let height = CGFloat(source.pixelsHigh)
        guard width > 0, height > 0 else { return nil }

        let scale = min(1, thumbnailMaxDimension / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))

        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        target.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return target.representation(using: .png, properties: [:])
    }

    // MARK: - Fichiers

    /// Icône système d'un fichier, encodée en PNG (sert de vignette).
    static func fileIconPNG(forPath path: String, size: CGFloat = 64) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: size, height: size)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
