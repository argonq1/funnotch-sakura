import AppKit
import ImageIO
import SwiftUI

/// The installed Codex app's own brand asset, decoded once to 64 pixels.
/// The small notch mark retains 16 KiB of pixels, rather than a 1024px icon.
struct CodexBrandMark: View {
    private static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "CodexBrandMark", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(size: NSSize(width: bitmap.width, height: bitmap.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: bitmap))
        return image
    }()

    var body: some View {
        Group {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else { Image(systemName: "terminal.fill").resizable().aspectRatio(contentMode: .fit) }
        }.accessibilityHidden(true)
    }
}
