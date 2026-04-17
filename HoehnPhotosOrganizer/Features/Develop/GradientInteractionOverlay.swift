import SwiftUI

// MARK: - MaskInteractionMode

enum MaskInteractionMode: Equatable {
    case none
    case placingLinearGradient
    case placingRadialGradient
}

// MARK: - GradientInteractionOverlay

/// Overlay on the image pane for interactive mask placement and handle dragging.
/// Provides Lightroom-style interactive gradient handles with click-drag placement,
/// post-placement handle manipulation, feather visualization, and smooth rotation.
struct GradientInteractionOverlay: View {

    @Binding var mode: MaskInteractionMode
    @Binding var maskLayers: [AdjustmentLayer]
    @Binding var selectedMaskId: String?
    let displayedImageRect: CGRect
    let onSourcePlaced: (MaskSourceType) -> Void
    let onNudgePreview: () -> Void

    // Placement drag state
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    // Handle sizes matching Lightroom styling
    private let handleRadius: CGFloat = 8
    private let handleStroke: CGFloat = 2
    private let lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if mode != .none {
                    placementLayer
                }

                if mode == .none, let selectedId = selectedMaskId,
                   let layerIdx = maskLayers.firstIndex(where: { $0.id == selectedId }) {
                    handleLayer(layerIndex: layerIdx)
                }
            }
        }
    }

    // MARK: - Placement Layer

    private var placementLayer: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            if dragStart == nil { dragStart = value.startLocation }
                            dragCurrent = value.location
                        }
                        .onEnded { value in
                            guard let start = dragStart else { return }
                            let end = value.location
                            let normStart = viewToNormalized(start)
                            let normEnd = viewToNormalized(end)

                            switch mode {
                            case .placingLinearGradient:
                                onSourcePlaced(.linearGradient(startPoint: normStart, endPoint: normEnd))
                            case .placingRadialGradient:
                                let dx = normEnd.x - normStart.x
                                let dy = normEnd.y - normStart.y
                                let radius = sqrt(dx * dx + dy * dy)
                                onSourcePlaced(.radialGradient(center: normStart, innerRadius: radius * 0.1, outerRadius: max(0.02, radius)))
                            case .none:
                                break
                            }

                            dragStart = nil
                            dragCurrent = nil
                            mode = .none
                        }
                )
                .onHover { inside in
                    if inside && mode != .none { NSCursor.crosshair.push() }
                    else { NSCursor.pop() }
                }

            // Live preview during drag
            if let start = dragStart, let current = dragCurrent {
                Canvas { context, size in
                    switch mode {
                    case .placingLinearGradient:
                        drawLinearGradientPreview(context: context, start: start, end: current)

                    case .placingRadialGradient:
                        drawRadialGradientPreview(context: context, center: start, edge: current)

                    case .none: break
                    }
                }
                .allowsHitTesting(false)
            }

            // Instruction banner
            VStack {
                HStack(spacing: 12) {
                    Text(mode == .placingLinearGradient
                         ? "Drag to set gradient direction"
                         : "Drag from center outward")
                        .font(.caption.weight(.medium)).foregroundStyle(.white)
                    Button("Cancel") {
                        mode = .none; dragStart = nil; dragCurrent = nil
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.white)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.top, 12)
                Spacer()
            }
        }
    }

    // MARK: - Placement Preview Drawing

    /// Draw a linear gradient preview with feather zone visualization during placement.
    private func drawLinearGradientPreview(context: GraphicsContext, start: CGPoint, end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 2 else { return }

        // Draw feather zone — semi-transparent band between start and end
        let perpX = -dy / length
        let perpY = dx / length
        let bandHalf: CGFloat = max(length * 0.6, 40) // Visible feather band

        var featherPath = Path()
        featherPath.move(to: CGPoint(x: start.x + perpX * bandHalf, y: start.y + perpY * bandHalf))
        featherPath.addLine(to: CGPoint(x: end.x + perpX * bandHalf, y: end.y + perpY * bandHalf))
        featherPath.addLine(to: CGPoint(x: end.x - perpX * bandHalf, y: end.y - perpY * bandHalf))
        featherPath.addLine(to: CGPoint(x: start.x - perpX * bandHalf, y: start.y - perpY * bandHalf))
        featherPath.closeSubpath()

        // Gradient fill for the feather zone
        let gradStart = CGPoint(x: start.x, y: start.y)
        let gradEnd = CGPoint(x: end.x, y: end.y)
        context.fill(featherPath, with: .linearGradient(
            Gradient(colors: [Color.red.opacity(0.25), Color.red.opacity(0.0)]),
            startPoint: gradStart, endPoint: gradEnd
        ))

        // Connector line
        var linePath = Path()
        linePath.move(to: start)
        linePath.addLine(to: end)
        context.stroke(linePath, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: lineWidth))

        // Perpendicular lines at start and end (Lightroom-style)
        let tickLen: CGFloat = 20
        drawPerpendicularTick(context: context, at: start, dx: dx, dy: dy, length: length, tickLen: tickLen)
        drawPerpendicularTick(context: context, at: end, dx: dx, dy: dy, length: length, tickLen: tickLen)

        // Endpoint handles
        drawHandle(context: context, at: start, filled: true)
        drawHandle(context: context, at: end, filled: false)
    }

    /// Draw a radial gradient preview with concentric rings during placement.
    private func drawRadialGradientPreview(context: GraphicsContext, center: CGPoint, edge: CGPoint) {
        let dx = edge.x - center.x
        let dy = edge.y - center.y
        let radius = sqrt(dx * dx + dy * dy)

        // Feather zone — filled circle
        let outerCircle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2))
        context.fill(outerCircle, with: .radialGradient(
            Gradient(colors: [Color.red.opacity(0.25), Color.red.opacity(0.0)]),
            center: center, startRadius: radius * 0.1, endRadius: radius
        ))

        // Inner radius ring
        let innerR = radius * 0.1
        let innerCircle = Path(ellipseIn: CGRect(x: center.x - innerR, y: center.y - innerR,
                                                  width: innerR * 2, height: innerR * 2))
        context.stroke(innerCircle, with: .color(.white.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // Outer radius ring
        context.stroke(outerCircle, with: .color(.white.opacity(0.7)),
                       style: StrokeStyle(lineWidth: lineWidth, dash: [6, 4]))

        // Connector line from center to edge
        var linePath = Path()
        linePath.move(to: center)
        linePath.addLine(to: edge)
        context.stroke(linePath, with: .color(.white.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // Handles
        drawHandle(context: context, at: center, filled: true)
        drawHandle(context: context, at: edge, filled: false)
    }

    // MARK: - Handle Drawing Helpers

    /// Draw a Lightroom-style circular handle: small (8pt), white fill or outline, with blue ring.
    private func drawHandle(context: GraphicsContext, at point: CGPoint, filled: Bool) {
        let r = handleRadius
        let rect = CGRect(x: point.x - r/2, y: point.y - r/2, width: r, height: r)
        let path = Path(ellipseIn: rect)

        if filled {
            context.fill(path, with: .color(.white))
        } else {
            context.fill(path, with: .color(.white.opacity(0.3)))
        }
        context.stroke(path, with: .color(.white), lineWidth: handleStroke)
        // Outer glow for visibility on any background
        let outerRect = CGRect(x: point.x - r/2 - 1, y: point.y - r/2 - 1, width: r + 2, height: r + 2)
        context.stroke(Path(ellipseIn: outerRect), with: .color(.black.opacity(0.4)), lineWidth: 1)
    }

    /// Draw a perpendicular tick mark at a point along the gradient direction (Lightroom-style).
    private func drawPerpendicularTick(context: GraphicsContext, at point: CGPoint,
                                        dx: CGFloat, dy: CGFloat, length: CGFloat, tickLen: CGFloat) {
        let perpX = -dy / length
        let perpY = dx / length
        var tick = Path()
        tick.move(to: CGPoint(x: point.x - perpX * tickLen, y: point.y - perpY * tickLen))
        tick.addLine(to: CGPoint(x: point.x + perpX * tickLen, y: point.y + perpY * tickLen))
        context.stroke(tick, with: .color(.white.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1))
    }

    // MARK: - Handle Layer

    @ViewBuilder
    private func handleLayer(layerIndex: Int) -> some View {
        let layer = maskLayers[layerIndex]
        ForEach(Array(layer.sources.enumerated()), id: \.element.id) { srcIdx, source in
            switch source.sourceType {
            case .linearGradient(let start, let end):
                linearHandles(li: layerIndex, si: srcIdx, start: start, end: end)
            case .radialGradient(let center, _, let outerRadius):
                radialHandles(li: layerIndex, si: srcIdx, center: center, outerRadius: outerRadius)
            case .ellipse(let rect):
                ellipseHandles(li: layerIndex, si: srcIdx, rect: rect)
            case .rectangle(let rect):
                rectangleHandles(li: layerIndex, si: srcIdx, rect: rect)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Linear Gradient Handles

    @ViewBuilder
    private func linearHandles(li: Int, si: Int, start: CGPoint, end: CGPoint) -> some View {
        let p0 = normalizedToView(start)
        let p1 = normalizedToView(end)
        let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)

        // Feather visualization + connector line via Canvas
        Canvas { context, _ in
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let length = sqrt(dx * dx + dy * dy)
            guard length > 2 else { return }

            // Feather zone — semi-transparent gradient band
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
                Gradient(colors: [Color.red.opacity(0.15), Color.red.opacity(0.0)]),
                startPoint: p0, endPoint: p1
            ))

            // Main connector line
            var linePath = Path()
            linePath.move(to: p0)
            linePath.addLine(to: p1)
            context.stroke(linePath, with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: lineWidth))

            // Perpendicular ticks at start and end
            let tickLen: CGFloat = 16
            drawPerpendicularTick(context: context, at: p0, dx: dx, dy: dy, length: length, tickLen: tickLen)
            drawPerpendicularTick(context: context, at: p1, dx: dx, dy: dy, length: length, tickLen: tickLen)

            // Midpoint tick
            let midTickLen: CGFloat = 10
            drawPerpendicularTick(context: context, at: mid, dx: dx, dy: dy, length: length, tickLen: midTickLen)
        }
        .allowsHitTesting(false)

        // Start handle — drag to reposition start, naturally rotates/resizes
        absoluteDragHandle(at: p0, filled: true) { newViewPos in
            let n = clampNorm(viewToNormalized(newViewPos))
            maskLayers[li].sources[si].sourceType = .linearGradient(startPoint: n, endPoint: end)
        }

        // End handle — drag to reposition end, naturally rotates/resizes
        absoluteDragHandle(at: p1, filled: false) { newViewPos in
            let n = clampNorm(viewToNormalized(newViewPos))
            maskLayers[li].sources[si].sourceType = .linearGradient(startPoint: start, endPoint: n)
        }

        // Midpoint handle — drag to translate entire gradient
        absoluteDragHandle(at: mid, filled: true, isMidpoint: true) { newViewPos in
            let newMidNorm = viewToNormalized(newViewPos)
            let oldMidNorm = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let dx = newMidNorm.x - oldMidNorm.x
            let dy = newMidNorm.y - oldMidNorm.y
            let ns = clampNorm(CGPoint(x: start.x + dx, y: start.y + dy))
            let ne = clampNorm(CGPoint(x: end.x + dx, y: end.y + dy))
            maskLayers[li].sources[si].sourceType = .linearGradient(startPoint: ns, endPoint: ne)
        }
    }

    // MARK: - Radial Gradient Handles

    @ViewBuilder
    private func radialHandles(li: Int, si: Int, center: CGPoint, outerRadius: CGFloat) -> some View {
        let c = normalizedToView(center)
        let edgePt = normalizedToView(CGPoint(x: center.x + outerRadius, y: center.y))
        let viewR = outerRadius * displayedImageRect.width
        let innerViewR = outerRadius * 0.1 * displayedImageRect.width

        // Feather visualization + radius ring via Canvas
        Canvas { context, _ in
            // Feather zone
            let outerCircle = Path(ellipseIn: CGRect(x: c.x - viewR, y: c.y - viewR,
                                                      width: viewR * 2, height: viewR * 2))
            context.fill(outerCircle, with: .radialGradient(
                Gradient(colors: [Color.red.opacity(0.15), Color.red.opacity(0.0)]),
                center: c, startRadius: innerViewR, endRadius: viewR
            ))

            // Inner radius ring
            let innerCircle = Path(ellipseIn: CGRect(x: c.x - innerViewR, y: c.y - innerViewR,
                                                      width: innerViewR * 2, height: innerViewR * 2))
            context.stroke(innerCircle, with: .color(.white.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // Outer radius ring
            context.stroke(outerCircle, with: .color(.white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: lineWidth, dash: [6, 4]))

            // Connector from center to edge handle
            var linePath = Path()
            linePath.move(to: c)
            linePath.addLine(to: edgePt)
            context.stroke(linePath, with: .color(.white.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .allowsHitTesting(false)

        // Center handle — drag to reposition
        absoluteDragHandle(at: c, filled: true) { newViewPos in
            let n = clampNorm(viewToNormalized(newViewPos))
            if case .radialGradient(_, let inner, let outer) = maskLayers[li].sources[si].sourceType {
                maskLayers[li].sources[si].sourceType = .radialGradient(center: n, innerRadius: inner, outerRadius: outer)
            }
        }

        // Edge handle — drag to resize radius
        absoluteDragHandle(at: edgePt, filled: false) { newViewPos in
            let newNorm = viewToNormalized(newViewPos)
            let dx = newNorm.x - center.x, dy = newNorm.y - center.y
            let newR = max(0.02, sqrt(dx * dx + dy * dy))
            maskLayers[li].sources[si].sourceType = .radialGradient(center: center, innerRadius: newR * 0.1, outerRadius: newR)
        }
    }

    // MARK: - Ellipse Handles (4 corner + center)

    @ViewBuilder
    private func ellipseHandles(li: Int, si: Int, rect: CGRect) -> some View {
        let vr = viewRect(from: rect)

        // Corner handles for resize
        let corners: [(CGPoint, String)] = [
            (CGPoint(x: vr.minX, y: vr.minY), "tl"),
            (CGPoint(x: vr.maxX, y: vr.minY), "tr"),
            (CGPoint(x: vr.minX, y: vr.maxY), "bl"),
            (CGPoint(x: vr.maxX, y: vr.maxY), "br"),
        ]
        ForEach(corners, id: \.1) { corner, id in
            absoluteDragHandle(at: corner, filled: false) { newViewPos in
                let n = viewToNormalized(newViewPos)
                let newRect = resizedRect(rect, corner: id, to: n)
                maskLayers[li].sources[si].sourceType = .ellipse(normalizedRect: newRect)
            }
        }

        // Center handle for move
        let center = CGPoint(x: vr.midX, y: vr.midY)
        absoluteDragHandle(at: center, filled: true, isMidpoint: true) { newViewPos in
            let newCenterNorm = viewToNormalized(newViewPos)
            let dx = newCenterNorm.x - (rect.origin.x + rect.width / 2)
            let dy = newCenterNorm.y - (rect.origin.y + rect.height / 2)
            let moved = CGRect(x: rect.origin.x + dx, y: rect.origin.y + dy, width: rect.width, height: rect.height)
            maskLayers[li].sources[si].sourceType = .ellipse(normalizedRect: moved)
        }
    }

    // MARK: - Rectangle Handles

    @ViewBuilder
    private func rectangleHandles(li: Int, si: Int, rect: CGRect) -> some View {
        let vr = viewRect(from: rect)

        let corners: [(CGPoint, String)] = [
            (CGPoint(x: vr.minX, y: vr.minY), "tl"),
            (CGPoint(x: vr.maxX, y: vr.minY), "tr"),
            (CGPoint(x: vr.minX, y: vr.maxY), "bl"),
            (CGPoint(x: vr.maxX, y: vr.maxY), "br"),
        ]
        ForEach(corners, id: \.1) { corner, id in
            absoluteDragHandle(at: corner, filled: false) { newViewPos in
                let n = viewToNormalized(newViewPos)
                let newRect = resizedRect(rect, corner: id, to: n)
                maskLayers[li].sources[si].sourceType = .rectangle(normalizedRect: newRect)
            }
        }

        let center = CGPoint(x: vr.midX, y: vr.midY)
        absoluteDragHandle(at: center, filled: true, isMidpoint: true) { newViewPos in
            let newCenterNorm = viewToNormalized(newViewPos)
            let dx = newCenterNorm.x - (rect.origin.x + rect.width / 2)
            let dy = newCenterNorm.y - (rect.origin.y + rect.height / 2)
            let moved = CGRect(x: rect.origin.x + dx, y: rect.origin.y + dy, width: rect.width, height: rect.height)
            maskLayers[li].sources[si].sourceType = .rectangle(normalizedRect: moved)
        }
    }

    // MARK: - Absolute Drag Handle (Lightroom-style)

    /// A Lightroom-style handle: small (8pt) circle with white fill/stroke and subtle shadow.
    /// Midpoint handles are shown as a slightly smaller square for visual distinction.
    @ViewBuilder
    private func absoluteDragHandle(at point: CGPoint, filled: Bool,
                                     isMidpoint: Bool = false,
                                     onDragTo: @escaping (CGPoint) -> Void) -> some View {
        let size = isMidpoint ? handleRadius - 1 : handleRadius
        let view = Group {
            if isMidpoint {
                // Square midpoint handle
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            } else {
                // Circle endpoint handle
                Circle()
                    .fill(filled ? Color.white : Color.white.opacity(0.3))
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(Color.white, lineWidth: handleStroke))
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1).padding(-1))
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            }
        }

        view
            .position(point)
            .gesture(
                DragGesture(coordinateSpace: .local)
                    .onChanged { value in
                        onDragTo(value.location)
                    }
                    .onEnded { _ in
                        onNudgePreview()
                    }
            )
    }

    // MARK: - Coordinate Helpers

    private func viewToNormalized(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - displayedImageRect.minX) / displayedImageRect.width,
            y: (point.y - displayedImageRect.minY) / displayedImageRect.height
        )
    }

    private func normalizedToView(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: displayedImageRect.minX + point.x * displayedImageRect.width,
            y: displayedImageRect.minY + point.y * displayedImageRect.height
        )
    }

    private func viewRect(from normRect: CGRect) -> CGRect {
        CGRect(
            x: displayedImageRect.minX + normRect.origin.x * displayedImageRect.width,
            y: displayedImageRect.minY + normRect.origin.y * displayedImageRect.height,
            width: normRect.width * displayedImageRect.width,
            height: normRect.height * displayedImageRect.height
        )
    }

    private func clampNorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(1, p.x)), y: max(0, min(1, p.y)))
    }

    /// Resize a normalized rect by moving one corner to a new normalized position.
    private func resizedRect(_ rect: CGRect, corner: String, to newPos: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY
        var maxX = rect.maxX, maxY = rect.maxY

        switch corner {
        case "tl": minX = newPos.x; minY = newPos.y
        case "tr": maxX = newPos.x; minY = newPos.y
        case "bl": minX = newPos.x; maxY = newPos.y
        case "br": maxX = newPos.x; maxY = newPos.y
        default: break
        }

        // Ensure min < max (allow flipping)
        let x0 = min(minX, maxX), x1 = max(minX, maxX)
        let y0 = min(minY, maxY), y1 = max(minY, maxY)
        let w = max(0.02, x1 - x0)
        let h = max(0.02, y1 - y0)
        return CGRect(x: x0, y: y0, width: w, height: h)
    }
}
