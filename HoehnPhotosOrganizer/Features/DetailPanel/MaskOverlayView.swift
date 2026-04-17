import AppKit
import SwiftUI

// MARK: - MaskOverlayView

/// Renders mask overlays over the image for visual feedback on adjustment layers.
/// When a layer is selected, its mask is shown as a red/pink overlay at 40% opacity.
/// When no layer is selected, the overlay is hidden.
/// Only the selected layer's mask is shown — other layers' masks are not displayed.
struct MaskOverlayView: View {

    @Binding var maskLayers: [AdjustmentLayer]
    @Binding var selectedMaskId: String?
    /// The actual rect of the rendered image within this view (accounts for letterboxing/padding).
    let displayedImageRect: CGRect

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let selectedId = selectedMaskId,
                   let selectedIndex = maskLayers.firstIndex(where: { $0.id == selectedId }) {
                    let layer = maskLayers[selectedIndex]
                    if layer.isActive {
                        // Bitmap mask overlays for selected layer
                        ForEach(layer.sources) { source in
                            if case .bitmap = source.sourceType {
                                bitmapOverlay(for: source, feather: source.feather)
                            }
                        }

                        // Shape and gradient overlays via Canvas for selected layer
                        Canvas { context, size in
                            for source in layer.sources {
                                switch source.sourceType {
                                case .ellipse(let r):
                                    let rect = viewRect(from: r)
                                    let path = Path(ellipseIn: rect)
                                    context.fill(path, with: .color(Color.red.opacity(0.4)))
                                    context.stroke(path, with: .color(Color.white.opacity(0.7)),
                                                   lineWidth: 1.5)

                                case .rectangle(let r):
                                    let rect = viewRect(from: r)
                                    let path = Path(rect)
                                    context.fill(path, with: .color(Color.red.opacity(0.4)))
                                    context.stroke(path, with: .color(Color.white.opacity(0.7)),
                                                   lineWidth: 1.5)

                                case .linearGradient(let start, let end):
                                    let p0 = viewPoint(from: start)
                                    let p1 = viewPoint(from: end)

                                    // Feather visualization — gradient band
                                    let dx = p1.x - p0.x
                                    let dy = p1.y - p0.y
                                    let length = sqrt(dx * dx + dy * dy)
                                    if length > 2 {
                                        let perpX = -dy / length
                                        let perpY = dx / length
                                        let bandHalf: CGFloat = max(length * 0.5, 30)

                                        var featherPath = Path()
                                        featherPath.move(to: CGPoint(x: p0.x + perpX * bandHalf, y: p0.y + perpY * bandHalf))
                                        featherPath.addLine(to: CGPoint(x: p1.x + perpX * bandHalf, y: p1.y + perpY * bandHalf))
                                        featherPath.addLine(to: CGPoint(x: p1.x - perpX * bandHalf, y: p1.y - perpY * bandHalf))
                                        featherPath.addLine(to: CGPoint(x: p0.x - perpX * bandHalf, y: p0.y - perpY * bandHalf))
                                        featherPath.closeSubpath()

                                        context.fill(featherPath, with: .linearGradient(
                                            Gradient(colors: [Color.red.opacity(0.3), Color.red.opacity(0.0)]),
                                            startPoint: p0, endPoint: p1
                                        ))
                                    }

                                    // Gradient line
                                    var linePath = Path()
                                    linePath.move(to: p0)
                                    linePath.addLine(to: p1)
                                    context.stroke(linePath, with: .color(Color.white.opacity(0.6)),
                                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                                    // Endpoints
                                    context.fill(Path(ellipseIn: CGRect(x: p0.x - 4, y: p0.y - 4, width: 8, height: 8)),
                                                 with: .color(.white))
                                    context.fill(Path(ellipseIn: CGRect(x: p1.x - 4, y: p1.y - 4, width: 8, height: 8)),
                                                 with: .color(.white.opacity(0.5)))

                                case .radialGradient(let center, let innerRadius, let outerRadius):
                                    let c = viewPoint(from: center)
                                    let r = outerRadius * displayedImageRect.width
                                    let innerR = innerRadius * displayedImageRect.width

                                    // Feather zone
                                    let outerCircle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                                    context.fill(outerCircle, with: .radialGradient(
                                        Gradient(colors: [Color.red.opacity(0.3), Color.red.opacity(0.0)]),
                                        center: c, startRadius: innerR, endRadius: r
                                    ))

                                    // Rings
                                    context.stroke(outerCircle, with: .color(Color.white.opacity(0.6)),
                                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

                                case .bitmap:
                                    break  // Rendered as overlay images above
                                }
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bitmap Mask Overlay

    @ViewBuilder
    private func bitmapOverlay(for source: MaskSource, feather: Double) -> some View {
        if case .bitmap(let rawData, let width, let height) = source.sourceType,
           let nsImage = Self.renderMaskAsOverlay(rawData: rawData, width: width, height: height) {
            let overlayBlur = feather * (displayedImageRect.width / 1000.0)
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: displayedImageRect.width, height: displayedImageRect.height)
                .blur(radius: overlayBlur)
                .position(x: displayedImageRect.midX, y: displayedImageRect.midY)
                .allowsHitTesting(false)
        }
    }

    /// Creates an NSImage with red/pink tinted mask pixels at 40% opacity.
    private static func renderMaskAsOverlay(rawData: Data, width: Int, height: Int) -> NSImage? {
        let pixels: [UInt8]
        if rawData.count == width * height {
            pixels = Array(rawData)
        } else {
            pixels = rleDecode(rawData, count: width * height)
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let alpha: UInt8 = 102  // ~40% of 255

        for i in 0..<(width * height) {
            if pixels[i] > 0 {
                rgba[i * 4 + 0] = 230  // Red
                rgba[i * 4 + 1] = 60   // Green (pinkish-red)
                rgba[i * 4 + 2] = 80   // Blue
                rgba[i * 4 + 3] = alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Coordinate Helpers

    private func viewRect(from normalizedRect: CGRect) -> CGRect {
        CGRect(
            x: displayedImageRect.origin.x + normalizedRect.origin.x * displayedImageRect.width,
            y: displayedImageRect.origin.y + normalizedRect.origin.y * displayedImageRect.height,
            width: normalizedRect.width * displayedImageRect.width,
            height: normalizedRect.height * displayedImageRect.height
        )
    }

    private func viewPoint(from normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: displayedImageRect.origin.x + normalizedPoint.x * displayedImageRect.width,
            y: displayedImageRect.origin.y + normalizedPoint.y * displayedImageRect.height
        )
    }
}
