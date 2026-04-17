import AppKit
import SwiftUI

/// Lightweight luminance + RGB histogram drawn from a CGImage.
/// Renders as a semi-transparent overlay suitable for the develop panel sidebar.
struct HistogramView: View {

    let image: CGImage?

    /// Cached bin data (256 bins per channel)
    @State private var bins: HistogramBins = .empty

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
            let maxCount = bins.maxValue
            guard maxCount > 0 else { return }

            let binCount = CGFloat(bins.count)

            // Draw R, G, B channels with additive-style blending
            drawChannel(context: context, bins: bins.red, maxCount: maxCount,
                        color: .red.opacity(0.35), size: size, binCount: binCount)
            drawChannel(context: context, bins: bins.green, maxCount: maxCount,
                        color: .green.opacity(0.35), size: size, binCount: binCount)
            drawChannel(context: context, bins: bins.blue, maxCount: maxCount,
                        color: .blue.opacity(0.35), size: size, binCount: binCount)

            // Luminance overlay (white)
            drawChannel(context: context, bins: bins.luminance, maxCount: maxCount,
                        color: .white.opacity(0.5), size: size, binCount: binCount)
        }
        .frame(height: 80)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: image) { await computeBins() }
    }

    private func drawChannel(context: GraphicsContext, bins: [Int], maxCount: Int,
                              color: Color, size: CGSize, binCount: CGFloat) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))

        for i in bins.indices {
            let x = CGFloat(i) / binCount * size.width
            let h = CGFloat(bins[i]) / CGFloat(maxCount) * size.height
            path.addLine(to: CGPoint(x: x, y: size.height - h))
        }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func computeBins() async {
        guard let cg = image else { bins = .empty; return }
        let result = await Task.detached(priority: .utility) {
            HistogramBins.compute(from: cg)
        }.value
        bins = result
    }
}

// MARK: - Histogram Data

struct HistogramBins {
    let red: [Int]
    let green: [Int]
    let blue: [Int]
    let luminance: [Int]

    var count: Int { 256 }
    var isEmpty: Bool { red.isEmpty }

    var maxValue: Int {
        // Skip first and last bins (pure black / pure white clipping) to avoid spiked display
        let skip = 1
        let range = skip..<(256 - skip)
        let rMax = red[range].max() ?? 0
        let gMax = green[range].max() ?? 0
        let bMax = blue[range].max() ?? 0
        let lMax = luminance[range].max() ?? 0
        return max(rMax, gMax, bMax, lMax)
    }

    static let empty = HistogramBins(red: [], green: [], blue: [], luminance: [])

    /// Sample pixels from a CGImage and bucket into 256 bins per channel.
    static func compute(from image: CGImage) -> HistogramBins {
        // Downsample large images for speed — 200px max edge is plenty for a histogram
        let maxEdge = 200
        let src: CGImage
        if max(image.width, image.height) > maxEdge {
            let ratio = CGFloat(maxEdge) / CGFloat(max(image.width, image.height))
            let nW = Int(CGFloat(image.width) * ratio)
            let nH = Int(CGFloat(image.height) * ratio)
            if let ctx = CGContext(data: nil, width: nW, height: nH, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
                ctx.interpolationQuality = .low
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: nW, height: nH))
                src = ctx.makeImage() ?? image
            } else {
                src = image
            }
        } else {
            src = image
        }

        let w = src.width, h = src.height
        guard w > 0, h > 0 else { return .empty }

        // Render into a known RGBA format
        let bytesPerRow = w * 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return .empty
        }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return .empty }

        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var rBins = [Int](repeating: 0, count: 256)
        var gBins = [Int](repeating: 0, count: 256)
        var bBins = [Int](repeating: 0, count: 256)
        var lBins = [Int](repeating: 0, count: 256)

        let pixelCount = w * h
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Int(ptr[offset])
            let g = Int(ptr[offset + 1])
            let b = Int(ptr[offset + 2])
            rBins[r] += 1
            gBins[g] += 1
            bBins[b] += 1
            // Rec. 709 luminance
            let lum = (r * 2126 + g * 7152 + b * 722) / 10000
            lBins[min(255, lum)] += 1
        }

        return HistogramBins(red: rBins, green: gBins, blue: bBins, luminance: lBins)
    }
}
