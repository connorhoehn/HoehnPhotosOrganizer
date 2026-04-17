import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - WatercolorRenderService

/// Actor that applies a watercolor-style stylization to a proxy JPEG using Core Image filters.
///
/// Workflow (procedural approximation, not a full watercolor simulation):
/// 1. Load proxy image (JPEG) from disk as CIImage
/// 2. Apply CIPhotoEffectMono for grayscale base
/// 3. Apply CIMedianFilter to reduce fine detail (simulates watercolor softness)
/// 4. Apply CIUnsharpMask to enhance edges slightly
/// 5. Blend original colors back at the given intensity ratio
/// 6. Return CGImage for display or saving
///
/// The intensity parameter controls the strength of the stylization effect:
///   - 0.0 = original photo (no watercolor effect)
///   - 0.5 = 50% watercolor blend (default, recommended for painting reference)
///   - 1.0 = full watercolor stylization
actor WatercolorRenderService {

    // MARK: - Core Image context

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ])

    // MARK: - Public API

    /// Generate a watercolor-style CGImage from a proxy JPEG.
    ///
    /// - Parameters:
    ///   - proxyImageURL: File URL pointing to a JPEG proxy image.
    ///   - intensity: Blend ratio between watercolor effect and original image (0.0–1.0).
    ///                Defaults to 0.5.
    /// - Returns: A CGImage with the watercolor stylization applied.
    /// - Throws: `RenderingError.invalidImage` if the file cannot be loaded,
    ///           `RenderingError.filterFailed` if the Core Image pipeline fails.
    func generateWatercolor(proxyImageURL: URL, intensity: Float = 0.5) async throws -> CGImage {
        // 1. Load proxy image
        guard let originalImage = CIImage(contentsOf: proxyImageURL) else {
            throw RenderingError.invalidImage("Cannot load image from \(proxyImageURL.lastPathComponent)")
        }

        // 2. Apply watercolor filter chain
        let stylized = try applyWatercolorChain(to: originalImage)

        // 3. Blend watercolor result with original at the given intensity
        let blended = try blendImages(
            watercolor: stylized,
            original: originalImage,
            intensity: intensity
        )

        // 4. Render to CGImage
        guard let cgImage = ciContext.createCGImage(blended, from: blended.extent) else {
            throw RenderingError.filterFailed("CIContext.createCGImage returned nil for watercolor output")
        }

        return cgImage
    }

    // MARK: - Private filter chain

    /// Apply grayscale + softening + edge sharpening for watercolor approximation.
    private func applyWatercolorChain(to input: CIImage) throws -> CIImage {
        // Step 1: CIPhotoEffectMono — convert to grayscale as watercolor base
        // Watercolor paintings often desaturate and simplify tones
        let monoFilter = CIFilter(name: "CIPhotoEffectMono")!
        monoFilter.setValue(input, forKey: kCIInputImageKey)

        guard let monoOutput = monoFilter.outputImage else {
            throw RenderingError.filterFailed("CIPhotoEffectMono returned nil output")
        }

        // Step 2: CIMedianFilter — reduce fine detail, simulate watercolor's soft edges
        // CIMedianFilter replaces each pixel with the median of its 3x3 neighborhood
        let medianFilter = CIFilter(name: "CIMedianFilter")!
        medianFilter.setValue(monoOutput, forKey: kCIInputImageKey)

        guard let medianOutput = medianFilter.outputImage else {
            throw RenderingError.filterFailed("CIMedianFilter returned nil output")
        }

        // Step 3: CIUnsharpMask — sharpen edges slightly to preserve paper-texture feel
        let unsharpFilter = CIFilter(name: "CIUnsharpMask")!
        unsharpFilter.setValue(medianOutput, forKey: kCIInputImageKey)
        unsharpFilter.setValue(2.5, forKey: kCIInputRadiusKey)     // pixel radius for sharpening
        unsharpFilter.setValue(0.5, forKey: kCIInputIntensityKey)  // sharpening intensity

        guard let unsharpOutput = unsharpFilter.outputImage else {
            throw RenderingError.filterFailed("CIUnsharpMask returned nil output")
        }

        return unsharpOutput
    }

    /// Blend watercolor-stylized image with the original using CIBlendWithMask or CIDissolve.
    ///
    /// Uses CIDissolveTransition to blend between original and watercolor at the given intensity.
    /// intensity=0.0 returns original, intensity=1.0 returns watercolor.
    private func blendImages(watercolor: CIImage, original: CIImage, intensity: Float) throws -> CIImage {
        let clampedIntensity = max(0.0, min(1.0, intensity))

        // Use CIDissolveTransition: blends from inputImage to targetImage by time
        // time=0 → inputImage (original), time=1 → targetImage (watercolor)
        let dissolveFilter = CIFilter(name: "CIDissolveTransition")!
        dissolveFilter.setValue(original, forKey: kCIInputImageKey)
        dissolveFilter.setValue(watercolor, forKey: kCIInputTargetImageKey)
        dissolveFilter.setValue(clampedIntensity, forKey: kCIInputTimeKey)

        guard let output = dissolveFilter.outputImage else {
            throw RenderingError.filterFailed("CIDissolveTransition returned nil output")
        }

        return output
    }
}
