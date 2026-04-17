import CoreImage
import ImageIO

/// Validates image file properties before running a pipeline.
/// Does NOT transform the image — returns input unchanged if all checks pass.
/// Reads properties from the file on disk via CGImageSource.
///
/// Params:
///   - filePath: Absolute path to the source image file (required)
///   - minimumDPI: Minimum DPI required (optional). Images without DPI metadata default to 72.
///   - requiresNoAlpha: If "true", throws if image has an alpha channel (optional)
struct ValidationPreflightStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .validationPreflight

    nonisolated init() {}

    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage {
        guard let filePath = params["filePath"],
              let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: filePath) as CFURL, nil
              ),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
            throw ValidationError.unreadableImage
        }

        // DPI check — images without DPI metadata default to 72 DPI
        if let minDPIStr = params["minimumDPI"], let minDPI = Double(minDPIStr) {
            let dpi = (props[kCGImagePropertyDPIWidth as String] as? Double) ?? 72.0
            if dpi < minDPI {
                throw ValidationError.insufficientDPI(found: dpi, required: minDPI)
            }
        }

        // Alpha channel check
        if params["requiresNoAlpha"] == "true" {
            let hasAlpha = (props[kCGImagePropertyHasAlpha as String] as? Bool) ?? false
            if hasAlpha {
                throw ValidationError.unexpectedAlphaChannel
            }
        }

        // Return input unchanged — preflight does not transform the image
        return input
    }
}
