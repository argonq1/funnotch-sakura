import AppKit
import ImageIO

/// Decode only the pixels the notch can display, off the main thread.
/// The long edge leaves room for the full-width Home poster on Retina.
enum MediaArtwork {
    static let maxPixelSize = 1536
    static let maxEncodedBytes = 8 * 1024 * 1024

    static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= maxEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        // NSImage(cgImage:size:) creates a Retina snapshot representation on
        // this Mac. Keep the decoded bitmap itself instead of doubling it.
        let bitmap = NSBitmapImageRep(cgImage: image)
        let result = NSImage(size: NSSize(width: image.width, height: image.height))
        result.addRepresentation(bitmap)
        return result
    }

    static func pixelCost(_ image: NSImage) -> Int {
        image.representations.reduce(0) { total, representation in
            let bytesPerRow = (representation as? NSBitmapImageRep)?.bytesPerRow ?? representation.pixelsWide * 4
            return total + bytesPerRow * representation.pixelsHigh
        }
    }
}
