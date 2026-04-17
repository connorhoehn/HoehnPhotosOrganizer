import CoreGraphics
import Foundation

// MARK: - Constants

/// Standard 35 mm film image gate: 36 mm wide × 24 mm high → aspect ratio ≈ 1.50.
let k35mmAspectRatio: Double = 36.0 / 24.0

// MARK: - Result types

struct FrameBorderThicknesses: Sendable {
    let top: Double
    let bottom: Double
    let left: Double
    let right: Double
}

/// The outcome of trimming one frame's dark rebate border.
struct FrameTrimResult: Sendable {
    /// 1-based frame index.
    let frameIndex: Int
    /// Final rect to use for export, in **strip** pixel coordinates.
    let trimmedRect: CGRect
    /// Trim confidence 0–1. Values below `Configuration.minimumConfidence` keep the original rect.
    let confidence: Double
    /// Aspect ratio of the trimmed content region (width ÷ height).
    let detectedAspectRatio: Double
    /// Fractional deviation from k35mmAspectRatio: |detected − 1.5| / 1.5.
    let aspectDeviation: Double
    /// Pixel thicknesses of detected rebate on each side (in full-res coordinates).
    let borders: FrameBorderThicknesses
    /// Human-readable notes produced during validation.
    let validationNotes: [String]
    /// `true` when confidence ≥ minimumConfidence and all statistical checks passed.
    let passed: Bool
}

enum FilmFrameTrimmerError: Error, LocalizedError {
    case failedToCreateContext
    case frameTooSmall
    var errorDescription: String? {
        switch self {
        case .failedToCreateContext: return "Failed to create trim analysis rendering context."
        case .frameTooSmall:         return "Frame is too small for rebate detection (< 16 px)."
        }
    }
}

// MARK: - Trimmer

/// Detects and removes the dark film-rebate border on all four sides of an already-cropped frame.
///
/// All analysis runs on a small thumbnail (≤ `Configuration.analysisSize` px wide) so even large
/// 21 000 × 2 000 strip crops are processed in milliseconds. Results are scaled back to full-res
/// coordinates before being returned.
struct FilmFrameTrimmer: Sendable {

    struct Configuration: Sendable {
        /// Longest side of the analysis thumbnail in pixels. Smaller = faster; 320 is plenty.
        var analysisSize: Int = 320
        /// Maximum fraction of any dimension that can be trimmed per side.
        var maxBorderFraction: Double = 0.28
        /// Minimum fraction of the original dimension that must remain as content.
        var minContentFraction: Double = 0.50
        /// Mean column/row brightness (0–1) above which pixels are treated as "content, not rebate".
        var contentBrightnessThreshold: Double = 0.09
        /// Minimum consecutive content-level columns/rows required to confirm an edge position.
        var consecutiveContentRequired: Int = 4
        /// Trim result confidence below this threshold causes the original rect to be returned.
        var minimumConfidence: Double = 0.38
        /// Fractional deviation from expectedAspectRatio beyond which confidence is penalised.
        var aspectRatioPenaltyThreshold: Double = 0.22
        /// Expected film frame aspect ratio (width / height). 35 mm full-frame ≈ 1.50.
        var expectedAspectRatio: Double = k35mmAspectRatio

        nonisolated static let `default` = Configuration()
    }

    let configuration: Configuration

    nonisolated init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: Public API

    /// Detect and remove the dark rebate border from a cropped frame image.
    ///
    /// - Parameters:
    ///   - frame:        The already-cropped CGImage for this frame.
    ///   - originalRect: The strip-space rect this frame was cut from (used to offset the result).
    ///   - index:        1-based frame index for labelling.
    /// - Returns: A `FrameTrimResult` whose `trimmedRect` is in **strip** pixel coordinates.
    nonisolated func trim(
        frame: CGImage,
        originalRect: CGRect,
        index: Int
    ) throws -> FrameTrimResult {
        guard frame.width >= 16, frame.height >= 16 else {
            throw FilmFrameTrimmerError.frameTooSmall
        }

        let (thumb, scale) = try renderThumbnail(frame)
        let colProfile = columnBrightnessProfile(thumb)
        let rowProfile  = rowBrightnessProfile(thumb)

        let leftCol   = detectInnerEdge(profile: colProfile, fromStart: true)
        let rightCol  = detectInnerEdge(profile: colProfile, fromStart: false)
        let topRow    = detectInnerEdge(profile: rowProfile,  fromStart: true)
        let bottomRow = detectBottomEdge(rowProfile: rowProfile, thumb: thumb)

        let thumbW = Double(thumb.width)
        let thumbH = Double(thumb.height)

        // Clamp to maxBorderFraction so we can never trim away the whole frame.
        let safeLeft   = min(Double(leftCol),   thumbW * configuration.maxBorderFraction)
        let safeRight  = max(Double(rightCol),  thumbW * (1.0 - configuration.maxBorderFraction))
        let safeTop    = min(Double(topRow),    thumbH * configuration.maxBorderFraction)
        let safeBottom = max(Double(bottomRow), thumbH * (1.0 - configuration.maxBorderFraction))

        let contentW = safeRight  - safeLeft
        let contentH = safeBottom - safeTop

        var notes: [String]  = []
        var confidence: Double = 1.0

        // ── Validation 1: minimum content fraction ───────────────────────────
        let coverageW = contentW / max(thumbW, 1)
        let coverageH = contentH / max(thumbH, 1)
        if coverageW < configuration.minContentFraction || coverageH < configuration.minContentFraction {
            confidence *= 0.45
            notes.append("[WARN] Trim reduced content below \(Int(configuration.minContentFraction * 100))% — holding conservative margins.")
        }

        // ── Validation 2: aspect ratio vs 35mm prior ─────────────────────────
        let detectedAspect = contentW / max(contentH, 1)
        let aspectDev = abs(detectedAspect - configuration.expectedAspectRatio) / configuration.expectedAspectRatio
        if aspectDev > configuration.aspectRatioPenaltyThreshold {
            let penalty = min((aspectDev - configuration.aspectRatioPenaltyThreshold) * 1.5, 0.55)
            confidence -= penalty
            notes.append(String(format: "[WARN] Aspect %.2f deviates %.0f%% from 35mm prior (%.2f).",
                                detectedAspect, aspectDev * 100, configuration.expectedAspectRatio))
        } else {
            notes.append(String(format: "[OK] Aspect %.2f within %.0f%% of 35mm prior.",
                                detectedAspect, configuration.aspectRatioPenaltyThreshold * 100))
        }

        // ── Validation 3: border symmetry sanity ─────────────────────────────
        let leftBorder  = safeLeft
        let rightBorder = thumbW - safeRight
        let topBorder   = safeTop
        let botBorder   = thumbH - safeBottom

        let hAsymmetry = abs(leftBorder - rightBorder) / max(leftBorder + rightBorder, 1)
        if hAsymmetry > 0.70 && (leftBorder + rightBorder) > thumbW * 0.08 {
            confidence -= 0.15
            notes.append(String(format: "[WARN] Horizontal border asymmetry %.0f%%.", hAsymmetry * 100))
        }

        if leftBorder  > 2 { notes.append(String(format: "Left rebate:   %.0fpx (%.1f%%)", leftBorder  / scale, leftBorder  / thumbW * 100)) }
        if rightBorder > 2 { notes.append(String(format: "Right rebate:  %.0fpx (%.1f%%)", rightBorder / scale, rightBorder / thumbW * 100)) }
        if topBorder   > 2 { notes.append(String(format: "Top rebate:    %.0fpx (%.1f%%)", topBorder   / scale, topBorder   / thumbH * 100)) }
        if botBorder   > 2 { notes.append(String(format: "Bottom rebate: %.0fpx (%.1f%%)", botBorder   / scale, botBorder   / thumbH * 100)) }

        confidence = max(0, min(1, confidence))
        let passed = confidence >= configuration.minimumConfidence

        let borders = FrameBorderThicknesses(
            top:    topBorder    / scale,
            bottom: botBorder    / scale,
            left:   leftBorder   / scale,
            right:  rightBorder  / scale
        )

        let trimmedRectInStrip: CGRect
        if passed {
            trimmedRectInStrip = CGRect(
                x: originalRect.minX + (safeLeft / scale),
                y: originalRect.minY + (safeTop  / scale),
                width:  contentW / scale,
                height: contentH / scale
            )
        } else {
            notes.append(String(format: "[SKIP] Confidence %.2f below threshold — original rect kept.", confidence))
            trimmedRectInStrip = originalRect
        }

        return FrameTrimResult(
            frameIndex: index,
            trimmedRect: trimmedRectInStrip,
            confidence: confidence,
            detectedAspectRatio: detectedAspect,
            aspectDeviation: aspectDev,
            borders: borders,
            validationNotes: notes,
            passed: passed
        )
    }

    // MARK: - Thumbnail

    nonisolated private func renderThumbnail(_ image: CGImage) throws -> (CGImage, Double) {
        let origW = image.width
        let origH = image.height
        let scale = min(1.0, Double(configuration.analysisSize) / Double(max(origW, origH)))
        let tw = max(1, Int((Double(origW) * scale).rounded()))
        let th = max(1, Int((Double(origH) * scale).rounded()))
        let bpr = tw * 4
        guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue),
              let thumb = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th)); return ctx.makeImage() }()
        else { throw FilmFrameTrimmerError.failedToCreateContext }
        return (thumb, scale)
    }

    // MARK: - Brightness Profiles

    nonisolated private func extractPixelBuffer(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let w = image.width, h = image.height, bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, w, h)
    }

    nonisolated private func lum(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        (0.299 * Double(r)) + (0.587 * Double(g)) + (0.114 * Double(b))
    }

    /// Mean normalised brightness per column (0–1).
    nonisolated private func columnBrightnessProfile(_ image: CGImage) -> [Double] {
        guard let (buf, w, h) = extractPixelBuffer(image) else { return Array(repeating: 0.5, count: image.width) }
        return (0..<w).map { x in
            var sum = 0.0
            for y in 0..<h { let i = (y * w + x) * 4; sum += lum(buf[i], buf[i+1], buf[i+2]) }
            return (sum / Double(h)) / 255.0
        }
    }

    /// Mean normalised brightness per row (0–1).
    nonisolated private func rowBrightnessProfile(_ image: CGImage) -> [Double] {
        guard let (buf, w, h) = extractPixelBuffer(image) else { return Array(repeating: 0.5, count: image.height) }
        return (0..<h).map { y in
            var sum = 0.0
            let off = y * w * 4
            for x in 0..<w { let i = off + x * 4; sum += lum(buf[i], buf[i+1], buf[i+2]) }
            return (sum / Double(w)) / 255.0
        }
    }

    // MARK: - Edge Detection

    /// Scan from one end of a brightness profile until `consecutiveContentRequired` consecutive
    /// positions are all above `contentBrightnessThreshold`. Returns the index of the first such
    /// run minus a small back-off margin.
    nonisolated private func detectInnerEdge(profile: [Double], fromStart: Bool) -> Int {
        let n = profile.count
        let threshold = configuration.contentBrightnessThreshold
        let required  = configuration.consecutiveContentRequired
        let smoothed  = boxSmooth(profile, radius: 3)
        let indices   = fromStart ? Array(0..<n) : Array((0..<n).reversed())
        var run = 0
        for idx in indices {
            if smoothed[idx] > threshold {
                run += 1
                if run >= required {
                    let backoff = required / 2
                    return fromStart
                        ? max(0,     idx - backoff)
                        : min(n - 1, idx + backoff)
                }
            } else {
                run = 0
            }
        }
        return fromStart ? 0 : n - 1
    }

    /// Bottom edge detection with sprocket-hole awareness.
    ///
    /// 35 mm film has sprocket holes along one or both edges. They appear as locally bright
    /// semi-circular blobs inside the dark rebate band. We scan up from the bottom, and if we find
    /// a strongly isolated bright region within the lower 30 % of rows, we clip *above* it.
    nonisolated private func detectBottomEdge(rowProfile: [Double], thumb: CGImage) -> Int {
        let n = rowProfile.count
        let threshold = configuration.contentBrightnessThreshold
        let required  = configuration.consecutiveContentRequired
        let smoothed  = boxSmooth(rowProfile, radius: 2)

        // --- standard upward scan ---
        var run = 0
        var standardEdge = n - 1
        for idx in (0..<n).reversed() {
            if smoothed[idx] > threshold {
                run += 1
                if run >= required {
                    standardEdge = min(n - 1, idx + (required / 2))
                    break
                }
            } else {
                run = 0
            }
        }

        // --- sprocket-hole check in lower 30 % ---
        let lowerStart = Int(Double(n) * 0.70)
        let lowerRows  = Array(smoothed[lowerStart...])
        if lowerRows.count > 4 {
            let lMean = lowerRows.reduce(0, +) / Double(lowerRows.count)
            let lMax  = lowerRows.max() ?? 0
            // A sprocket shows as a local max that is clearly brighter than its surrounding rebate.
            if lMax > max(lMean * 1.9, 0.25) {
                // Find the transition from scene content into this bright rebate pocket.
                for idx in (lowerStart..<n).reversed() {
                    if smoothed[idx] < lMean * 1.2 {
                        // Back off by 2 to stay just inside the content boundary.
                        return min(n - 1, idx + 2)
                    }
                }
            }
        }

        return standardEdge
    }

    nonisolated private func boxSmooth(_ values: [Double], radius: Int) -> [Double] {
        let n = values.count
        guard n > 2 * radius else { return values }
        return (0..<n).map { i in
            let lo = max(0, i - radius), hi = min(n - 1, i + radius)
            return values[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}
