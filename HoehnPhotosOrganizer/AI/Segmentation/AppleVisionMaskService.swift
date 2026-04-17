import AppKit
import CoreGraphics
import CoreImage
import Vision
import Foundation

// MARK: - AppleVisionSegment

struct AppleVisionSegment: Identifiable {
    let id: Int
    let label: String                    // "Person", "Person (face)", "Background", "Sky", "Foreground"
    let kind: SegmentKind
    let maskPixels: [UInt8]              // Raw grayscale pixels (0 or 255)
    let width: Int
    let height: Int
    let coverage: Float                  // 0-1, fraction of image covered

    enum SegmentKind: String {
        case person
        case personFace
        case foreground
        case background                  // inverse of all people
        case sky                         // top region heuristic + saliency
        case salientObject
    }

    /// Render as blue-tinted overlay image.
    func renderOverlay(isSelected: Bool, color: (UInt8, UInt8, UInt8)? = nil) -> NSImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let alpha: UInt8 = isSelected ? 150 : 90
        let c = color ?? colorForKind

        for i in 0..<(width * height) {
            if maskPixels[i] > 0 {
                rgba[i * 4 + 0] = c.0
                rgba[i * 4 + 1] = c.1
                rgba[i * 4 + 2] = c.2
                rgba[i * 4 + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Convert to AdjustmentLayer for the adjustment pipeline.
    func toAdjustmentLayer() -> AdjustmentLayer {
        AdjustmentLayer(
            label: label,
            sources: [MaskSource(sourceType: .bitmap(rle: Data(maskPixels), width: width, height: height))]
        )
    }

    /// Default color per segment kind.
    private var colorForKind: (UInt8, UInt8, UInt8) {
        switch kind {
        case .person:       return (60, 120, 255)    // blue
        case .personFace:   return (255, 180, 60)    // orange
        case .foreground:   return (60, 200, 120)    // green
        case .background:   return (180, 60, 180)    // purple
        case .sky:          return (60, 200, 255)    // cyan
        case .salientObject: return (255, 255, 60)   // yellow
        }
    }
}

// MARK: - AppleVisionMaskService

/// Generates segmentation masks using Apple's built-in Vision framework.
/// No models to bundle — runs on Neural Engine via the OS.
///
/// Capabilities:
/// - Person segmentation (VNGeneratePersonSegmentationRequest)
/// - Foreground instance masks (VNGenerateForegroundInstanceMaskRequest, macOS 14+)
/// - Face detection (VNDetectFaceRectanglesRequest) → face-region masks
/// - Background mask (inverse of all people)
/// - Saliency detection (VNGenerateAttentionBasedSaliencyImageRequest)
actor AppleVisionMaskService {

    // MARK: - Public API

    /// Generate all available segments for an image.
    /// Returns: person masks, face masks, background, foreground instances, salient regions.
    func generateSegments(from cgImage: CGImage) async throws -> [AppleVisionSegment] {
        let w = cgImage.width
        let h = cgImage.height
        var segments = [AppleVisionSegment]()
        var segmentId = 0

        // 1. Person segmentation (full body)
        let personMask = try await generatePersonMask(from: cgImage)
        if let pixels = personMask {
            let coverage = Float(pixels.filter { $0 > 0 }.count) / Float(w * h)
            if coverage > 0.01 {  // at least 1% coverage
                segments.append(AppleVisionSegment(
                    id: segmentId, label: "People", kind: .person,
                    maskPixels: pixels, width: w, height: h, coverage: coverage
                ))
                segmentId += 1

                // Background = inverse of people
                let bgPixels = pixels.map { $0 > 0 ? UInt8(0) : UInt8(255) }
                let bgCoverage = 1.0 - coverage
                segments.append(AppleVisionSegment(
                    id: segmentId, label: "Background", kind: .background,
                    maskPixels: bgPixels, width: w, height: h, coverage: bgCoverage
                ))
                segmentId += 1
            }
        }

        // 2. Face detection → elliptical face masks intersected with person silhouette
        let faces = try await detectFaces(from: cgImage)
        for (i, faceRect) in faces.enumerated() {
            var facePixels = [UInt8](repeating: 0, count: w * h)
            // Convert normalized face rect (bottom-left origin) to pixel rect (top-left)
            let fx = CGFloat(faceRect.origin.x) * CGFloat(w)
            let fy = (1.0 - faceRect.origin.y - faceRect.height) * CGFloat(h)
            let fw = faceRect.width * CGFloat(w)
            let fh = faceRect.height * CGFloat(h)

            // Ellipse center and radii (expand 30% for natural face boundary)
            let cx = fx + fw / 2
            let cy = fy + fh / 2
            let rx = fw * 0.65  // slightly wider than bbox
            let ry = fh * 0.65  // slightly taller for forehead

            var pixelCount = 0
            for y in 0..<h {
                for x in 0..<w {
                    let dx = (CGFloat(x) - cx) / rx
                    let dy = (CGFloat(y) - cy) / ry
                    if dx * dx + dy * dy <= 1.0 {
                        // Inside ellipse — also require inside person mask if available
                        if let pm = personMask, pm[y * w + x] > 0 {
                            facePixels[y * w + x] = 255
                            pixelCount += 1
                        } else if personMask == nil {
                            facePixels[y * w + x] = 255
                            pixelCount += 1
                        }
                    }
                }
            }

            let coverage = Float(pixelCount) / Float(w * h)
            if coverage > 0.001 {
                segments.append(AppleVisionSegment(
                    id: segmentId, label: "Face \(i + 1)", kind: .personFace,
                    maskPixels: facePixels, width: w, height: h, coverage: coverage
                ))
                segmentId += 1
            }
        }

        // 3. Foreground instance masks (macOS 14+)
        if #available(macOS 14.0, *) {
            let instances = try await generateForegroundInstances(from: cgImage)
            for (i, instancePixels) in instances.enumerated() {
                let coverage = Float(instancePixels.filter { $0 > 0 }.count) / Float(w * h)
                if coverage > 0.005 {
                    segments.append(AppleVisionSegment(
                        id: segmentId, label: "Object \(i + 1)", kind: .foreground,
                        maskPixels: instancePixels, width: w, height: h, coverage: coverage
                    ))
                    segmentId += 1
                }
            }
        }

        // 4. Saliency-based attention detection
        let salientMask = try await generateSaliencyMask(from: cgImage)
        if let pixels = salientMask {
            let coverage = Float(pixels.filter { $0 > 0 }.count) / Float(w * h)
            if coverage > 0.01 && coverage < 0.9 {  // meaningful saliency
                segments.append(AppleVisionSegment(
                    id: segmentId, label: "Subject", kind: .salientObject,
                    maskPixels: pixels, width: w, height: h, coverage: coverage
                ))
                segmentId += 1
            }
        }

        print("[AppleVisionMask] Generated \(segments.count) segments from \(w)×\(h) image")
        for seg in segments {
            print("  [\(seg.id)] \(seg.label) (\(seg.kind.rawValue)): \(String(format: "%.1f", seg.coverage * 100))% coverage")
        }

        return segments
    }

    // MARK: - Person Segmentation

    private func generatePersonMask(from cgImage: CGImage) async throws -> [UInt8]? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else { return nil }
        return pixelBufferToMask(result.pixelBuffer, targetWidth: cgImage.width, targetHeight: cgImage.height)
    }

    // MARK: - Face Detection

    private func detectFaces(from cgImage: CGImage) async throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return request.results?.map { $0.boundingBox } ?? []
    }

    // MARK: - Foreground Instance Masks (macOS 14+)

    @available(macOS 14.0, *)
    private func generateForegroundInstances(from cgImage: CGImage) async throws -> [[UInt8]] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else { return [] }

        var instanceMasks = [[UInt8]]()
        let allInstances = result.allInstances

        for instance in allInstances {
            do {
                let maskBuffer = try result.generateMaskedImage(
                    ofInstances: IndexSet(integer: instance),
                    from: handler,
                    croppedToInstancesExtent: false
                )
                if let pixels = pixelBufferToMask(maskBuffer, targetWidth: cgImage.width, targetHeight: cgImage.height) {
                    instanceMasks.append(pixels)
                }
            } catch {
                print("[AppleVisionMask] Failed to generate instance mask: \(error)")
            }
        }

        return instanceMasks
    }

    // MARK: - Saliency Detection

    private func generateSaliencyMask(from cgImage: CGImage) async throws -> [UInt8]? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else { return nil }
        let salientPixelBuffer = result.pixelBuffer

        return pixelBufferToMask(salientPixelBuffer, targetWidth: cgImage.width, targetHeight: cgImage.height, threshold: 0.3)
    }

    // MARK: - CVPixelBuffer → Mask Conversion

    /// Convert a CVPixelBuffer (grayscale or one-hot) to a binary mask pixel array.
    /// Resizes to target dimensions if needed.
    private func pixelBufferToMask(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        threshold: Float = 0.5
    ) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let bufW = CVPixelBufferGetWidth(pixelBuffer)
        let bufH = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        // Read source mask at buffer resolution
        var sourceMask = [Float](repeating: 0, count: bufW * bufH)

        if pixelFormat == kCVPixelFormatType_OneComponent8 {
            let ptr = baseAddress.bindMemory(to: UInt8.self, capacity: bufH * bytesPerRow)
            for y in 0..<bufH {
                for x in 0..<bufW {
                    sourceMask[y * bufW + x] = Float(ptr[y * bytesPerRow + x]) / 255.0
                }
            }
        } else if pixelFormat == kCVPixelFormatType_OneComponent32Float {
            let ptr = baseAddress.bindMemory(to: Float.self, capacity: bufH * bufW)
            let floatBytesPerRow = bytesPerRow / 4
            for y in 0..<bufH {
                for x in 0..<bufW {
                    sourceMask[y * bufW + x] = ptr[y * floatBytesPerRow + x]
                }
            }
        } else if pixelFormat == kCVPixelFormatType_OneComponent16Half {
            let ptr = baseAddress.bindMemory(to: UInt16.self, capacity: bufH * bufW)
            let halfBytesPerRow = bytesPerRow / 2
            for y in 0..<bufH {
                for x in 0..<bufW {
                    let raw = ptr[y * halfBytesPerRow + x]
                    sourceMask[y * bufW + x] = float16ToFloat32(raw)
                }
            }
        } else {
            // Unknown format — try treating as UInt8
            let ptr = baseAddress.bindMemory(to: UInt8.self, capacity: bufH * bytesPerRow)
            for y in 0..<bufH {
                for x in 0..<bufW {
                    sourceMask[y * bufW + x] = Float(ptr[y * bytesPerRow + x]) / 255.0
                }
            }
        }

        // Resize to target dimensions using bilinear interpolation, preserve soft alpha
        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let scaleX = Float(bufW) / Float(targetWidth)
        let scaleY = Float(bufH) / Float(targetHeight)

        for y in 0..<targetHeight {
            let srcYf = (Float(y) + 0.5) * scaleY - 0.5
            let y0 = max(0, min(bufH - 1, Int(srcYf)))
            let y1 = min(bufH - 1, y0 + 1)
            let fy = srcYf - Float(y0)

            for x in 0..<targetWidth {
                let srcXf = (Float(x) + 0.5) * scaleX - 0.5
                let x0 = max(0, min(bufW - 1, Int(srcXf)))
                let x1 = min(bufW - 1, x0 + 1)
                let fx = srcXf - Float(x0)

                // Bilinear interpolation
                let v00 = sourceMask[y0 * bufW + x0]
                let v10 = sourceMask[y0 * bufW + x1]
                let v01 = sourceMask[y1 * bufW + x0]
                let v11 = sourceMask[y1 * bufW + x1]
                let val = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy)
                        + v01 * (1 - fx) * fy + v11 * fx * fy

                // Soft alpha: keep gradient values for smooth edges
                // Apply a gentle curve to sharpen the core while preserving edge softness
                let curved = val < threshold * 0.5 ? 0.0 : min(1.0, val * 1.1)
                result[y * targetWidth + x] = UInt8(max(0, min(255, curved * 255)))
            }
        }

        return result
    }

    private func float16ToFloat32(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 1
        let exp = (h >> 10) & 0x1F
        let frac = h & 0x3FF
        if exp == 0 {
            if frac == 0 { return sign == 1 ? -0.0 : 0.0 }
            let f = Float(frac) / 1024.0 * pow(2.0, -14.0)
            return sign == 1 ? -f : f
        } else if exp == 31 {
            return frac == 0 ? (sign == 1 ? -Float.infinity : Float.infinity) : Float.nan
        }
        let f = (1.0 + Float(frac) / 1024.0) * pow(2.0, Float(Int(exp) - 15))
        return sign == 1 ? -f : f
    }
}
