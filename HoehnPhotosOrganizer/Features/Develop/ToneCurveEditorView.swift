import SwiftUI

/// Interactive tone curve editor overlaid on a histogram.
/// Displays the histogram behind a draggable Bezier curve with control points.
/// Lightroom/Camera Raw style: click to add points, drag to move, double-click to remove.
struct ToneCurveEditorView: View {

    let image: CGImage?
    @Binding var curvePoints: [CurvePoint]

    @State private var bins: HistogramBins = .empty
    @State private var draggingIndex: Int? = nil
    @State private var hoveredIndex: Int? = nil

    /// Default identity curve — endpoints only
    private static let defaultPoints: [CurvePoint] = [
        CurvePoint(input: 0, output: 0),
        CurvePoint(input: 255, output: 255)
    ]

    /// Sorted working points — always includes endpoints
    private var points: [CurvePoint] {
        let pts = curvePoints.isEmpty ? Self.defaultPoints : curvePoints
        return pts.sorted { $0.input < $1.input }
    }

    private let pointRadius: CGFloat = 5
    private let hitRadius: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Histogram background
                histogramCanvas(size: size)

                // Curve path
                curvePath(size: size)
                    .stroke(Color.white, lineWidth: 1.5)

                // Diagonal reference line (identity)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height))
                    p.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)

                // Control points
                ForEach(Array(points.enumerated()), id: \.offset) { idx, pt in
                    let pos = pointPosition(pt, in: size)
                    Circle()
                        .fill(draggingIndex == idx ? Color.accentColor : Color.white)
                        .frame(width: pointRadius * 2, height: pointRadius * 2)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .position(pos)
                        .onHover { hoveredIndex = $0 ? idx : nil }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: size))
            .onTapGesture(count: 2) { location in
                removePoint(at: location, in: size)
            }
            .simultaneousGesture(
                TapGesture(count: 1).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local).onEnded { value in
                    // Single click — handled by drag start (add point)
                })
            )
        }
        .frame(height: 140)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if curvePoints.count > 2 || (curvePoints.count == 2 && curvePoints != Self.defaultPoints) {
                Button {
                    curvePoints = []
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Reset curve")
            }
        }
        .task(id: image) { await computeBins() }
    }

    // MARK: - Histogram

    private func histogramCanvas(size: CGSize) -> some View {
        Canvas { context, sz in
            guard !bins.isEmpty else { return }
            let maxCount = bins.maxValue
            guard maxCount > 0 else { return }
            let binCount = CGFloat(bins.count)

            drawChannel(context: context, bins: bins.red, maxCount: maxCount,
                        color: .red.opacity(0.25), size: sz, binCount: binCount)
            drawChannel(context: context, bins: bins.green, maxCount: maxCount,
                        color: .green.opacity(0.25), size: sz, binCount: binCount)
            drawChannel(context: context, bins: bins.blue, maxCount: maxCount,
                        color: .blue.opacity(0.25), size: sz, binCount: binCount)
            drawChannel(context: context, bins: bins.luminance, maxCount: maxCount,
                        color: .white.opacity(0.35), size: sz, binCount: binCount)
        }
        .allowsHitTesting(false)
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

    // MARK: - Curve

    private func curvePath(size: CGSize) -> Path {
        let pts = points.map { pointPosition($0, in: size) }
        guard pts.count >= 2 else { return Path() }

        var path = Path()
        path.move(to: pts[0])

        if pts.count == 2 {
            path.addLine(to: pts[1])
        } else {
            // Catmull-Rom to Bezier for smooth curve through all points
            for i in 0..<(pts.count - 1) {
                let p0 = i > 0 ? pts[i - 1] : pts[i]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]

                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6,
                    y: p1.y + (p2.y - p0.y) / 6
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6,
                    y: p2.y - (p3.y - p1.y) / 6
                )
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            }
        }
        return path
    }

    // MARK: - Coordinate Mapping

    private func pointPosition(_ pt: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat(pt.input) / 255.0 * size.width,
            y: size.height - CGFloat(pt.output) / 255.0 * size.height
        )
    }

    private func curveValue(at location: CGPoint, in size: CGSize) -> CurvePoint {
        let input = Int(max(0, min(255, location.x / size.width * 255)))
        let output = Int(max(0, min(255, (1.0 - location.y / size.height) * 255)))
        return CurvePoint(input: input, output: output)
    }

    // MARK: - Gestures

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if draggingIndex == nil {
                    // Find existing point near start, or add new
                    if let idx = hitTest(value.startLocation, in: size) {
                        draggingIndex = idx
                    } else {
                        // Add a new point
                        let newPt = curveValue(at: value.startLocation, in: size)
                        var pts = points
                        pts.append(newPt)
                        pts.sort { $0.input < $1.input }
                        curvePoints = pts
                        draggingIndex = pts.firstIndex(where: { $0.input == newPt.input && $0.output == newPt.output })
                    }
                }

                guard let idx = draggingIndex else { return }
                let sorted = points
                var updated = curveValue(at: value.location, in: size)

                // Clamp X between neighbors (endpoints stay fixed at 0/255)
                if idx == 0 {
                    updated.input = 0
                } else if idx == sorted.count - 1 {
                    updated.input = 255
                } else {
                    let minX = sorted[idx - 1].input + 1
                    let maxX = sorted[idx + 1].input - 1
                    updated.input = max(minX, min(maxX, updated.input))
                }
                updated.output = max(0, min(255, updated.output))

                var pts = sorted
                pts[idx] = updated
                curvePoints = pts
            }
            .onEnded { _ in
                draggingIndex = nil
            }
    }

    private func hitTest(_ location: CGPoint, in size: CGSize) -> Int? {
        let pts = points
        for (idx, pt) in pts.enumerated() {
            let pos = pointPosition(pt, in: size)
            let dx = location.x - pos.x
            let dy = location.y - pos.y
            if sqrt(dx * dx + dy * dy) < hitRadius {
                return idx
            }
        }
        return nil
    }

    private func removePoint(at location: CGPoint, in size: CGSize) {
        guard let idx = hitTest(location, in: size) else { return }
        let pts = points
        // Don't remove endpoints
        guard idx > 0 && idx < pts.count - 1 else { return }
        var updated = pts
        updated.remove(at: idx)
        curvePoints = updated
    }

    // MARK: - Async

    private func computeBins() async {
        guard let cg = image else { bins = .empty; return }
        let result = await Task.detached(priority: .utility) {
            HistogramBins.compute(from: cg)
        }.value
        bins = result
    }
}
