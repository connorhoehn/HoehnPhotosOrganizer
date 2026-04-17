import Foundation
import AppKit
import CoreGraphics

// MARK: - SoftProofService

/// Renders a soft-proof preview of an NSImage through a printer ICC profile.
///
/// Pipeline:
///   NSImage (sRGB) → CGImage → CGContext(space: printerICC, intent: X)
///   → CGImage tagged printerICC → NSImage
///
/// The resulting NSImage is tagged with the printer ICC profile.
/// macOS display compositor then converts printerICC → display profile automatically,
/// completing the classic two-hop soft-proof chain without any manual compose step.
actor SoftProofService {

    enum SoftProofError: Error, LocalizedError {
        case invalidProfile(URL)
        case invalidImage
        case renderFailed

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let url):
                return "Cannot load ICC profile: \(url.lastPathComponent)"
            case .invalidImage:
                return "Cannot convert source image for soft proofing"
            case .renderFailed:
                return "CGContext render failed — profile may be incompatible"
            }
        }
    }

    // MARK: - Public

    /// Render source image through the printer ICC profile.
    /// - Parameters:
    ///   - image: The canvas source image (treated as sRGB if untagged).
    ///   - profileURL: Path to the .icc / .icm file.
    ///   - intent: ColorSync rendering intent.
    ///   - blackPointCompensation: Passed through for future ColorSync C-API path;
    ///     currently CGContext uses the system-default BPC behaviour for the intent.
    func renderSoftProof(
        image: NSImage,
        profileURL: URL,
        intent: CGColorRenderingIntent,
        blackPointCompensation: Bool
    ) async throws -> NSImage {

        // 1. Load ICC data
        let iccData = try Data(contentsOf: profileURL)
        guard let printerCS = CGColorSpace(iccData: iccData as CFData) else {
            throw SoftProofError.invalidProfile(profileURL)
        }

        // 2. Convert NSImage → CGImage
        guard let tiff      = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiff),
              let sourceCG  = bitmapRep.cgImage else {
            throw SoftProofError.invalidImage
        }

        let w = sourceCG.width
        let h = sourceCG.height

        // 3. Draw source into a CGContext that targets the printer ICC space.
        //    CGContext.draw applies ColorSync (sRGB → printerICC) with the given intent.
        //    The output CGImage is tagged as printerICC; macOS display then converts
        //    printerICC → display profile transparently, completing the soft proof.
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: printerCS,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SoftProofError.renderFailed
        }

        ctx.setRenderingIntent(intent)
        ctx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        guard let result = ctx.makeImage() else {
            throw SoftProofError.renderFailed
        }

        return NSImage(cgImage: result, size: image.size)
    }
}
