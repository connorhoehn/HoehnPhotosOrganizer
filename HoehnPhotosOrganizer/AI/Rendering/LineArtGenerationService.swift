import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - RenderingError

/// Errors thrown by generative rendering services.
enum RenderingError: Error, LocalizedError {
    case invalidImage(String)
    case filterFailed(String)
    case ollamaFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage(let detail): return "Invalid image: \(detail)"
        case .filterFailed(let detail): return "Filter failed: \(detail)"
        case .ollamaFailed(let detail): return "Ollama failed: \(detail)"
        }
    }
}

// MARK: - LineArtGenerationService

/// Actor that converts a proxy JPEG into a line-art CGImage using Core Image filters.
///
/// Workflow:
/// 1. Load proxy image (JPEG) from disk as CIImage
/// 2. Apply CILineOverlay for pencil-sketch line extraction
/// 3. Optionally apply CIEdges + CIColorInvert for high-contrast etching look
/// 4. Return CGImage ready for display or saving
///
/// The Ollama VLM "describe as line drawing" prompt path is deferred to Phase 8.
actor LineArtGenerationService {

    // MARK: - Core Image context (reused across calls)

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .highQualityDownsample: true
    ])

    // MARK: - Public API

    /// Generate a line-art CGImage from a proxy JPEG.
    ///
    /// - Parameters:
    ///   - proxyImageURL: File URL pointing to a JPEG proxy image.
    ///   - highContrast: If true, applies CIEdges + CIColorInvert for a high-contrast etching look.
    ///                   If false, uses CILineOverlay for a softer pencil-sketch appearance.
    /// - Returns: A CGImage with the line-art rendering applied.
    /// - Throws: `RenderingError.invalidImage` if the file cannot be loaded,
    ///           `RenderingError.filterFailed` if the Core Image pipeline fails.
    func generateLineArt(proxyImageURL: URL, highContrast: Bool = false) async throws -> CGImage {
        // 1. Load proxy image
        guard let ciImage = CIImage(contentsOf: proxyImageURL) else {
            throw RenderingError.invalidImage("Cannot load image from \(proxyImageURL.lastPathComponent)")
        }

        let output: CIImage

        if highContrast {
            output = try applyHighContrastLineArt(to: ciImage)
        } else {
            output = try applyLineOverlay(to: ciImage)
        }

        // Render to CGImage
        guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
            throw RenderingError.filterFailed("CIContext.createCGImage returned nil for line art output")
        }

        return cgImage
    }

    // MARK: - Private filter chains

    /// CILineOverlay: pencil-sketch line drawing.
    private func applyLineOverlay(to input: CIImage) throws -> CIImage {
        let filter = CIFilter(name: "CILineOverlay")!
        filter.setValue(input, forKey: kCIInputImageKey)
        // NRNoiseLevel: noise reduction before edge detection (0.0–0.1 range)
        filter.setValue(0.07, forKey: "inputNRNoiseLevel")
        // NRSharpness: edge sharpening after noise reduction
        filter.setValue(0.71, forKey: "inputNRSharpness")
        // EdgeIntensity: strength of edge lines
        filter.setValue(1.0, forKey: "inputEdgeIntensity")
        // Threshold: minimum edge strength to include in line art
        filter.setValue(0.1, forKey: "inputThreshold")
        // Contrast: controls tonal contrast in the non-edge areas
        filter.setValue(50.0, forKey: "inputContrast")

        guard let output = filter.outputImage else {
            throw RenderingError.filterFailed("CILineOverlay returned nil output")
        }
        return output
    }

    /// CIEdges + CIColorInvert: high-contrast edge map, useful for etching workflows.
    private func applyHighContrastLineArt(to input: CIImage) throws -> CIImage {
        // Step 1: CIEdges — detect edges in the image
        let edgesFilter = CIFilter(name: "CIEdges")!
        edgesFilter.setValue(input, forKey: kCIInputImageKey)
        // Intensity: edge brightness (higher = bolder lines)
        edgesFilter.setValue(2.0, forKey: kCIInputIntensityKey)

        guard let edgesOutput = edgesFilter.outputImage else {
            throw RenderingError.filterFailed("CIEdges returned nil output")
        }

        // Step 2: CIColorInvert — invert so edges are dark on white background
        let invertFilter = CIFilter(name: "CIColorInvert")!
        invertFilter.setValue(edgesOutput, forKey: kCIInputImageKey)

        guard let invertOutput = invertFilter.outputImage else {
            throw RenderingError.filterFailed("CIColorInvert returned nil output")
        }

        return invertOutput
    }
}
