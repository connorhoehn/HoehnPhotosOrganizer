import CoreImage
import CoreGraphics
import Foundation

// MARK: - MaskRenderingService

/// Static pure-function service for building grayscale CIImage masks from MaskSourceType
/// and compositing per-layer adjustments over a base image using CIBlendWithMask.
struct MaskRenderingService {

    // MARK: - Public API

    /// Apply all active adjustment layers over a globally-adjusted base image.
    ///
    /// Each layer's adjustments are rendered through `AdjustmentFilterPipeline.applyFilterChain`,
    /// the same Camera Raw-quality pipeline used for global adjustments. This ensures
    /// temperature/tint, clarity, dehaze, vibrance, and the full LUT chain are available
    /// per-layer.
    static func applyAdjustmentLayers(
        _ layers: [AdjustmentLayer],
        base: CIImage,
        sourceCG: CGImage
    ) -> CIImage {
        var result = base
        for layer in layers where layer.isActive {
            guard !layer.adjustments.isIdentity else { continue }

            let sourceCI = CIImage(cgImage: sourceCG)
            let regionCI = AdjustmentFilterPipeline.applyFilterChain(sourceCI, adjustments: layer.adjustments)

            // Build composite mask from all sources
            var maskCI = buildCompositeMask(from: layer.sources, imageExtent: base.extent)

            // Apply layer-level opacity
            if layer.opacity < 0.999 {
                maskCI = applyOpacity(maskCI, opacity: layer.opacity, extent: base.extent)
            }

            // Global layers (no sources) apply everywhere
            if layer.sources.isEmpty {
                result = regionCI
                continue
            }

            guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { continue }
            blendFilter.setValue(regionCI, forKey: kCIInputImageKey)
            blendFilter.setValue(result,   forKey: kCIInputBackgroundImageKey)
            blendFilter.setValue(maskCI,   forKey: kCIInputMaskImageKey)
            result = blendFilter.outputImage ?? result
        }
        return result
    }

    // MARK: - Composite Mask Building

    /// Combine multiple MaskSources into a single grayscale mask.
    static func buildCompositeMask(from sources: [MaskSource], imageExtent: CGRect) -> CIImage {
        guard !sources.isEmpty else {
            return CIImage(color: CIColor.white).cropped(to: imageExtent)
        }

        var composite: CIImage? = nil

        for source in sources {
            // Build raw mask from source type
            var sourceMask = buildMask(sourceType: source.sourceType, imageExtent: imageExtent)

            // Per-source edge refinement
            sourceMask = applyMorphology(sourceMask, erode: source.erode, dilate: source.dilate, extent: imageExtent)
            sourceMask = applyFeather(sourceMask, feather: source.feather, extent: imageExtent)

            // Per-source inversion
            if source.isInverted {
                sourceMask = invertMask(sourceMask, extent: imageExtent)
            }

            // Combine with running composite
            if let existing = composite {
                composite = combineMasks(existing: existing, new: sourceMask,
                                         mode: source.combineMode, extent: imageExtent)
            } else {
                // First source — for intersect mode, start from white
                if source.combineMode == .intersect {
                    let white = CIImage(color: CIColor.white).cropped(to: imageExtent)
                    composite = combineMasks(existing: white, new: sourceMask,
                                             mode: .intersect, extent: imageExtent)
                } else {
                    composite = sourceMask
                }
            }
        }

        return composite ?? CIImage(color: CIColor.black).cropped(to: imageExtent)
    }

    /// Combine two masks using the specified mode.
    private static func combineMasks(existing: CIImage, new: CIImage,
                                     mode: MaskCombineMode, extent: CGRect) -> CIImage {
        switch mode {
        case .add:
            // Union: max of both masks
            guard let f = CIFilter(name: "CIMaximumCompositing") else { return existing }
            f.setValue(new, forKey: kCIInputImageKey)
            f.setValue(existing, forKey: kCIInputBackgroundImageKey)
            return (f.outputImage ?? existing).cropped(to: extent)

        case .subtract:
            // Remove: multiply existing by inverted new
            let invNew = invertMask(new, extent: extent)
            guard let f = CIFilter(name: "CIMultiplyCompositing") else { return existing }
            f.setValue(invNew, forKey: kCIInputImageKey)
            f.setValue(existing, forKey: kCIInputBackgroundImageKey)
            return (f.outputImage ?? existing).cropped(to: extent)

        case .intersect:
            // Overlap: min of both masks
            guard let f = CIFilter(name: "CIMinimumCompositing") else { return existing }
            f.setValue(new, forKey: kCIInputImageKey)
            f.setValue(existing, forKey: kCIInputBackgroundImageKey)
            return (f.outputImage ?? existing).cropped(to: extent)
        }
    }

    // MARK: - Mask Building

    /// Build a grayscale mask CIImage from a MaskSourceType.
    static func buildMask(sourceType: MaskSourceType, imageExtent: CGRect) -> CIImage {
        switch sourceType {
        case .rectangle(let normalizedRect):
            let pixelRect = ciImageRect(from: normalizedRect, imageExtent: imageExtent)
            return buildRectMask(rect: pixelRect, imageExtent: imageExtent)

        case .ellipse(let normalizedRect):
            let pixelRect = ciImageRect(from: normalizedRect, imageExtent: imageExtent)
            return buildEllipseMask(
                center: CGPoint(x: pixelRect.midX, y: pixelRect.midY),
                radiusX: pixelRect.width / 2,
                radiusY: pixelRect.height / 2,
                imageExtent: imageExtent
            )

        case .bitmap:
            guard var maskCI = sourceType.toCIImage() else {
                return CIImage(color: CIColor.black).cropped(to: imageExtent)
            }
            let scaleX = imageExtent.width / maskCI.extent.width
            let scaleY = imageExtent.height / maskCI.extent.height
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            maskCI = maskCI.transformed(by: CGAffineTransform(
                translationX: imageExtent.origin.x - maskCI.extent.origin.x,
                y: imageExtent.origin.y - maskCI.extent.origin.y
            ))
            return maskCI.cropped(to: imageExtent)

        case .linearGradient(let startPoint, let endPoint):
            return buildLinearGradientMask(startPoint: startPoint, endPoint: endPoint, imageExtent: imageExtent)

        case .radialGradient(let center, let innerRadius, let outerRadius):
            return buildRadialGradientMask(center: center, innerRadius: innerRadius, outerRadius: outerRadius, imageExtent: imageExtent)
        }
    }

    // MARK: - Shape Masks

    static func buildRectMask(rect: CGRect, imageExtent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: rect)
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: imageExtent))
    }

    static func buildEllipseMask(
        center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, imageExtent: CGRect
    ) -> CIImage {
        guard let gradient = CIFilter(name: "CIRadialGradient") else {
            return CIImage(color: CIColor.black).cropped(to: imageExtent)
        }
        let radius = max(radiusX, radiusY)
        gradient.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
        gradient.setValue(radius * 0.6,  forKey: "inputRadius0")
        gradient.setValue(radius,        forKey: "inputRadius1")
        gradient.setValue(CIColor.white, forKey: "inputColor0")
        gradient.setValue(CIColor.black, forKey: "inputColor1")
        guard let mask = gradient.outputImage else {
            return CIImage(color: CIColor.black).cropped(to: imageExtent)
        }
        var result = mask
        if abs(radiusX - radiusY) > 1 {
            let yScale = radiusY / max(radiusX, 1)
            let transform = CGAffineTransform(translationX: 0, y: center.y)
                .scaledBy(x: 1.0, y: yScale)
                .translatedBy(x: 0, y: -center.y)
            result = result.transformed(by: transform)
        }
        return result.cropped(to: imageExtent)
    }

    // MARK: - Gradient Masks

    /// Linear gradient mask: white at startPoint, fading to black at endPoint.
    /// Points are in normalized coordinates (0-1, top-left origin).
    static func buildLinearGradientMask(startPoint: CGPoint, endPoint: CGPoint, imageExtent: CGRect) -> CIImage {
        guard let gradient = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: CIColor.black).cropped(to: imageExtent)
        }
        // Convert normalized coords to CIImage pixel coords (flip Y)
        let p0 = CGPoint(
            x: imageExtent.origin.x + startPoint.x * imageExtent.width,
            y: imageExtent.origin.y + (1.0 - startPoint.y) * imageExtent.height
        )
        let p1 = CGPoint(
            x: imageExtent.origin.x + endPoint.x * imageExtent.width,
            y: imageExtent.origin.y + (1.0 - endPoint.y) * imageExtent.height
        )
        gradient.setValue(CIVector(x: p0.x, y: p0.y), forKey: "inputPoint0")
        gradient.setValue(CIVector(x: p1.x, y: p1.y), forKey: "inputPoint1")
        gradient.setValue(CIColor.white, forKey: "inputColor0")
        gradient.setValue(CIColor.black, forKey: "inputColor1")
        return (gradient.outputImage ?? CIImage(color: CIColor.black)).cropped(to: imageExtent)
    }

    /// Radial gradient mask: white inside innerRadius, fading to black at outerRadius.
    /// Center and radii are in normalized coordinates.
    static func buildRadialGradientMask(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat, imageExtent: CGRect) -> CIImage {
        guard let gradient = CIFilter(name: "CIRadialGradient") else {
            return CIImage(color: CIColor.black).cropped(to: imageExtent)
        }
        let c = CGPoint(
            x: imageExtent.origin.x + center.x * imageExtent.width,
            y: imageExtent.origin.y + (1.0 - center.y) * imageExtent.height
        )
        let r0 = innerRadius * imageExtent.width
        let r1 = outerRadius * imageExtent.width
        gradient.setValue(CIVector(x: c.x, y: c.y), forKey: "inputCenter")
        gradient.setValue(r0, forKey: "inputRadius0")
        gradient.setValue(r1, forKey: "inputRadius1")
        gradient.setValue(CIColor.white, forKey: "inputColor0")
        gradient.setValue(CIColor.black, forKey: "inputColor1")
        return (gradient.outputImage ?? CIImage(color: CIColor.black)).cropped(to: imageExtent)
    }

    // MARK: - Edge Refinement

    static func applyFeather(_ mask: CIImage, feather: Double, extent: CGRect) -> CIImage {
        guard feather > 0.1 else { return mask }
        let blurRadius = feather * (extent.width / 1000.0)
        return mask.applyingGaussianBlur(sigma: blurRadius).cropped(to: extent)
    }

    static func applyOpacity(_ mask: CIImage, opacity: Double, extent: CGRect) -> CIImage {
        guard opacity < 0.999 else { return mask }
        let opacityOverlay = CIImage(color: CIColor(red: CGFloat(opacity), green: CGFloat(opacity), blue: CGFloat(opacity)))
            .cropped(to: extent)
        guard let multiply = CIFilter(name: "CIMultiplyCompositing") else { return mask }
        multiply.setValue(mask, forKey: kCIInputImageKey)
        multiply.setValue(opacityOverlay, forKey: kCIInputBackgroundImageKey)
        return (multiply.outputImage ?? mask).cropped(to: extent)
    }

    static func applyMorphology(_ mask: CIImage, erode: Double, dilate: Double, extent: CGRect) -> CIImage {
        var result = mask
        if erode > 0.1 {
            let radius = erode * (extent.width / 2000.0)
            if let f = CIFilter(name: "CIMorphologyMinimum") {
                f.setValue(result, forKey: kCIInputImageKey)
                f.setValue(radius, forKey: kCIInputRadiusKey)
                result = (f.outputImage ?? result).cropped(to: extent)
            }
        }
        if dilate > 0.1 {
            let radius = dilate * (extent.width / 2000.0)
            if let f = CIFilter(name: "CIMorphologyMaximum") {
                f.setValue(result, forKey: kCIInputImageKey)
                f.setValue(radius, forKey: kCIInputRadiusKey)
                result = (f.outputImage ?? result).cropped(to: extent)
            }
        }
        return result
    }

    static func invertMask(_ mask: CIImage, extent: CGRect) -> CIImage {
        guard let invert = CIFilter(name: "CIColorInvert") else { return mask }
        invert.setValue(mask, forKey: kCIInputImageKey)
        return (invert.outputImage ?? mask).cropped(to: extent)
    }

    // MARK: - Coordinate Conversion

    static func ciImageRect(from normalizedRect: CGRect, imageExtent: CGRect) -> CGRect {
        let x = imageExtent.origin.x + normalizedRect.origin.x * imageExtent.width
        let y = imageExtent.origin.y
            + (1.0 - normalizedRect.origin.y - normalizedRect.height) * imageExtent.height
        let w = normalizedRect.width * imageExtent.width
        let h = normalizedRect.height * imageExtent.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
