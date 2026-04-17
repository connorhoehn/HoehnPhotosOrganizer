import SwiftUI

// MARK: - InpaintMaskOverlay

/// Transparent overlay for painting inpainting masks with an airbrush.
/// Renders existing strokes as a red-tinted mask and tracks new strokes.
struct InpaintMaskOverlay: View {

    let displayedImageRect: CGRect
    @Binding var strokes: [[CGPoint]]
    @Binding var currentStroke: [CGPoint]
    @Binding var brushSize: CGFloat
    @Binding var brushSoftness: CGFloat

    @State private var cursorPosition: CGPoint? = nil
    @State private var isPainting = false

    var body: some View {
        ZStack {
            // Rendered mask strokes
            Canvas { context, size in
                // Draw completed strokes
                for stroke in strokes {
                    drawStroke(stroke, in: context, size: size)
                }
                // Draw in-progress stroke
                if !currentStroke.isEmpty {
                    drawStroke(currentStroke, in: context, size: size)
                }
            }
            .allowsHitTesting(false)

            // Interaction layer
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pt = value.location
                            // Only paint within the image rect
                            guard displayedImageRect.contains(pt) else { return }
                            if !isPainting {
                                isPainting = true
                                currentStroke = [pt]
                            } else {
                                currentStroke.append(pt)
                            }
                            cursorPosition = pt
                        }
                        .onEnded { _ in
                            if !currentStroke.isEmpty {
                                strokes.append(currentStroke)
                                currentStroke = []
                            }
                            isPainting = false
                        }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        cursorPosition = pt
                    case .ended:
                        cursorPosition = nil
                    }
                }

            // Brush cursor
            if let pos = cursorPosition, displayedImageRect.contains(pos) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                    .frame(width: brushSize, height: brushSize)
                    .position(pos)
                    .allowsHitTesting(false)
                    .shadow(color: .black.opacity(0.4), radius: 1)

                // Inner soft indicator
                Circle()
                    .fill(Color.red.opacity(0.2 * (1.0 - brushSoftness * 0.5)))
                    .frame(width: brushSize * (1.0 - brushSoftness * 0.5), height: brushSize * (1.0 - brushSoftness * 0.5))
                    .position(pos)
                    .allowsHitTesting(false)

                // Brush size label — offset below the ring
                Text("\(Int(brushSize)) px")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                    .position(x: pos.x, y: pos.y + brushSize / 2 + 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stroke Rendering

    private func drawStroke(_ points: [CGPoint], in context: GraphicsContext, size: CGSize) {
        guard points.count >= 2 else {
            // Single point — draw a dot
            if let pt = points.first {
                let rect = CGRect(
                    x: pt.x - brushSize / 2,
                    y: pt.y - brushSize / 2,
                    width: brushSize,
                    height: brushSize
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(Color.red.opacity(0.4))
                )
            }
            return
        }

        // Draw overlapping circles along the stroke path for airbrush effect
        let spacing = max(brushSize * 0.15, 1)
        var lastDrawn: CGPoint? = nil

        for point in points {
            if let last = lastDrawn {
                let dist = hypot(point.x - last.x, point.y - last.y)
                if dist < spacing { continue }
            }

            let rect = CGRect(
                x: point.x - brushSize / 2,
                y: point.y - brushSize / 2,
                width: brushSize,
                height: brushSize
            )

            // Airbrush: softer edges with lower opacity
            let alpha = 0.15 + (1.0 - brushSoftness) * 0.25
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color.red.opacity(alpha))
            )

            // Soft edge ring
            if brushSoftness > 0.2 {
                let outerRect = rect.insetBy(dx: -brushSize * 0.15, dy: -brushSize * 0.15)
                context.fill(
                    Path(ellipseIn: outerRect),
                    with: .color(Color.red.opacity(alpha * 0.3))
                )
            }

            lastDrawn = point
        }
    }
}

// MARK: - InpaintMaskOverlay + Mask Rendering

extension InpaintMaskOverlay {

    /// Render the current mask strokes to a binary CGImage for model input.
    /// White = inpaint area, Black = keep area.
    static func renderMask(
        strokes: [[CGPoint]],
        brushSize: CGFloat,
        brushSoftness: CGFloat,
        imageRect: CGRect,
        outputSize: CGSize
    ) -> CGImage? {
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: 0
        ) else { return nil }

        // Black background (keep)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale from view coordinates to image coordinates
        let scaleX = outputSize.width / imageRect.width
        let scaleY = outputSize.height / imageRect.height
        let scaledBrush = brushSize * scaleX

        // White brush strokes (inpaint area)
        ctx.setFillColor(gray: 1, alpha: 1)
        let spacing = max(scaledBrush * 0.15, 1)

        for stroke in strokes {
            var lastDrawn: CGPoint? = nil
            for point in stroke {
                // Transform from view space to image space
                let ix = (point.x - imageRect.minX) * scaleX
                // Flip Y for CGContext (origin bottom-left)
                let iy = outputSize.height - (point.y - imageRect.minY) * scaleY

                if let last = lastDrawn {
                    let dist = hypot(ix - last.x, iy - last.y)
                    if dist < spacing { continue }
                }

                let rect = CGRect(
                    x: ix - scaledBrush / 2,
                    y: iy - scaledBrush / 2,
                    width: scaledBrush,
                    height: scaledBrush
                )
                ctx.fillEllipse(in: rect)
                lastDrawn = CGPoint(x: ix, y: iy)
            }
        }

        return ctx.makeImage()
    }
}
