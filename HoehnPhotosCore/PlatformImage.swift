import Foundation

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

// MARK: - Cross-Platform Image Helpers

public extension PlatformImage {

    /// Create a CGImage from the platform image.
    public var cgImageRepresentation: CGImage? {
        #if os(macOS)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }

    /// Create a platform image from CGImage.
    public convenience init?(cgImageSource: CGImage) {
        #if os(macOS)
        self.init(cgImage: cgImageSource, size: NSSize(width: cgImageSource.width, height: cgImageSource.height))
        #else
        self.init(cgImage: cgImageSource)
        #endif
    }

    /// JPEG data representation.
    public func jpegData(compressionQuality: CGFloat = 0.85) -> Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #else
        return self.jpegData(compressionQuality: compressionQuality)
        #endif
    }

    /// Image dimensions.
    public var pixelSize: CGSize {
        #if os(macOS)
        guard let rep = representations.first else { return size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        #else
        return CGSize(width: size.width * scale, height: size.height * scale)
        #endif
    }
}
