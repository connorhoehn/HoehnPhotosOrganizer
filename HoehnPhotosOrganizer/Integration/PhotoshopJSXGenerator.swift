import Foundation

// MARK: - JSXGenerationError

/// Errors thrown by PhotoshopJSXGenerator during curve-to-JSX conversion.
enum JSXGenerationError: LocalizedError {
    case invalidCurveFormat(details: String)
    case pointsOutOfRange(details: String)
    case generationFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .invalidCurveFormat(let details):
            return "Invalid curve format: \(details)"
        case .pointsOutOfRange(let details):
            return "Curve points out of range: \(details)"
        case .generationFailed(let details):
            return "JSX generation failed: \(details)"
        }
    }
}

// MARK: - PhotoshopJSXGenerator

/// Actor that converts ACV/CSV curve data into Photoshop action descriptor JSX (ExtendScript).
///
/// Usage:
/// ```swift
/// let generator = PhotoshopJSXGenerator()
/// let jsx = try await generator.generateJSX(from: curveData)
/// // send jsx to PhotoshopAutomationService.applyJSX(jsx:)
/// ```
///
/// The generated JSX uses Photoshop's ExtendScript action descriptor API to apply
/// a Curves adjustment to the active document. Output is deterministic — same curve
/// data always produces identical JSX.
actor PhotoshopJSXGenerator {

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Generate Photoshop-compatible JSX from curve data.
    ///
    /// - Parameter curveData: A `CurveData` with `format` of "acv" or "csv".
    /// - Returns: JSX (ExtendScript) string ready to send to Photoshop.
    /// - Throws: `JSXGenerationError` if the data is malformed or out of range.
    func generateJSX(from curveData: CurveData) async throws -> String {
        let points: [(x: Int, y: Int)]

        switch curveData.format.lowercased() {
        case "csv":
            guard let text = String(data: curveData.data, encoding: .utf8) else {
                throw JSXGenerationError.invalidCurveFormat(details: "CSV data is not valid UTF-8")
            }
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            points = try parseCSVPoints(lines: lines)
        case "acv":
            points = try parseACVPoints(data: curveData.data)
        default:
            throw JSXGenerationError.invalidCurveFormat(
                details: "Unsupported curve format '\(curveData.format)'. Expected 'acv' or 'csv'."
            )
        }

        guard !points.isEmpty else {
            throw JSXGenerationError.invalidCurveFormat(details: "No curve points found in data")
        }

        return try generateActionDescriptorJSX(points: points)
    }

    // MARK: - Parsing

    /// Parse CSV curve data: tab-separated "x\ty" lines, one point per line.
    ///
    /// Accepts lines like "0\t0", "128\t140", "255\t255".
    func parseCSVPoints(lines: [String]) throws -> [(x: Int, y: Int)] {
        var points: [(x: Int, y: Int)] = []

        for line in lines {
            // Support both tab and comma as separators
            let components: [String]
            if line.contains("\t") {
                components = line.components(separatedBy: "\t")
            } else if line.contains(",") {
                components = line.components(separatedBy: ",")
            } else {
                // Try whitespace split
                components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            }

            guard components.count >= 2,
                  let x = Int(components[0].trimmingCharacters(in: .whitespaces)),
                  let y = Int(components[1].trimmingCharacters(in: .whitespaces)) else {
                continue // Skip malformed lines
            }

            guard (0...255).contains(x) && (0...255).contains(y) else {
                throw JSXGenerationError.pointsOutOfRange(
                    details: "Point (\(x), \(y)) is out of [0, 255] range"
                )
            }

            points.append((x: x, y: y))
        }

        return points
    }

    /// Parse Adobe Curve Binary (ACV) format.
    ///
    /// ACV format (Adobe Photoshop Curves):
    /// - Bytes 0-1: version (Big Endian UInt16, value 1 or 4)
    /// - Bytes 2-3: curve count (Big Endian UInt16)
    /// - Per curve:
    ///   - Bytes 0-1: point count (Big Endian UInt16)
    ///   - Per point: 2 × UInt16 Big Endian (output then input)
    ///
    /// We read the composite (all-channel) curve only.
    func parseACVPoints(data: Data) throws -> [(x: Int, y: Int)] {
        guard data.count >= 4 else {
            throw JSXGenerationError.invalidCurveFormat(details: "ACV data too short (\(data.count) bytes)")
        }

        var offset = 0

        // Read version
        let version: UInt16 = offset + 1 < data.count ? (UInt16(data[offset]) << 8) | UInt16(data[offset + 1]) : 0
        offset += 2

        guard version == 1 || version == 4 else {
            throw JSXGenerationError.invalidCurveFormat(details: "Unknown ACV version \(version)")
        }

        // Read curve count
        let curveCount: UInt16 = offset + 1 < data.count ? (UInt16(data[offset]) << 8) | UInt16(data[offset + 1]) : 0
        offset += 2

        guard curveCount > 0 else {
            throw JSXGenerationError.invalidCurveFormat(details: "ACV has no curves")
        }

        // Read first (composite) curve
        guard offset + 2 <= data.count else {
            throw JSXGenerationError.invalidCurveFormat(details: "ACV truncated before first curve point count")
        }

        let pointCount: UInt16 = offset + 1 < data.count ? (UInt16(data[offset]) << 8) | UInt16(data[offset + 1]) : 0
        offset += 2

        guard pointCount > 0 else {
            throw JSXGenerationError.invalidCurveFormat(details: "ACV curve has zero points")
        }

        var points: [(x: Int, y: Int)] = []
        let requiredBytes = offset + Int(pointCount) * 4

        guard requiredBytes <= data.count else {
            throw JSXGenerationError.invalidCurveFormat(
                details: "ACV data truncated: need \(requiredBytes) bytes but got \(data.count)"
            )
        }

        for _ in 0..<pointCount {
            // ACV stores output then input (y then x)
            let output = Int(offset + 1 < data.count ? (UInt16(data[offset]) << 8) | UInt16(data[offset + 1]) : 0)
            offset += 2
            let input = Int(offset + 1 < data.count ? (UInt16(data[offset]) << 8) | UInt16(data[offset + 1]) : 0)
            offset += 2
            points.append((x: input, y: output))
        }

        return points
    }

    // MARK: - JSX Generation

    /// Build an ExtendScript (JSX) string that applies curve points to the active Photoshop document.
    ///
    /// Uses Photoshop's action descriptor API:
    /// - `charIDToTypeID` for 4-character field codes
    /// - `ActionDescriptor` / `ActionList` to build the curve descriptor
    /// - `executeAction` to apply the Curves adjustment layer
    func generateActionDescriptorJSX(points: [(x: Int, y: Int)]) throws -> String {
        guard !points.isEmpty else {
            throw JSXGenerationError.generationFailed(details: "Cannot generate JSX with zero points")
        }

        // Validate all points are in range
        for pt in points {
            guard (0...255).contains(pt.x) && (0...255).contains(pt.y) else {
                throw JSXGenerationError.pointsOutOfRange(
                    details: "Point (\(pt.x), \(pt.y)) is out of [0, 255] range"
                )
            }
        }

        // Build the point list as JSX array literals for readability
        let pointEntries = points.map { pt in
            """
                { hrzn: \(pt.x), vrtn: \(pt.y) }
            """
        }.joined(separator: ",\n")

        let jsx = """
// Generated by PhotoshopJSXGenerator (HoehnPhotosOrganizer)
// Applies editorial feedback curve to active Photoshop document
(function applyCurve() {
    var doc = app.activeDocument;

    // Build Curves adjustment descriptor
    var desc = new ActionDescriptor();
    desc.putEnumerated(
        charIDToTypeID("Crv "),
        charIDToTypeID("Ordn"),
        charIDToTypeID("Trgt")
    );

    // Build curve point list
    var curveList = new ActionList();
    var curvePoints = [
\(pointEntries)
    ];

    for (var i = 0; i < curvePoints.length; i++) {
        var pointDesc = new ActionDescriptor();
        pointDesc.putInteger(charIDToTypeID("hrzn"), curvePoints[i].hrzn);
        pointDesc.putInteger(charIDToTypeID("vrtn"), curvePoints[i].vrtn);
        curveList.putObject(charIDToTypeID("Pnt "), pointDesc);
    }

    // Composite channel curves descriptor
    var curvesDesc = new ActionDescriptor();
    var channelRef = new ActionReference();
    channelRef.putEnumerated(
        charIDToTypeID("Chnl"),
        charIDToTypeID("Chnl"),
        charIDToTypeID("Cmps")
    );
    curvesDesc.putReference(charIDToTypeID("null"), channelRef);
    curvesDesc.putList(charIDToTypeID("Crv "), curveList);

    var curvesList = new ActionList();
    curvesList.putObject(charIDToTypeID("CrvA"), curvesDesc);
    desc.putList(charIDToTypeID("Crvs"), curvesList);

    // Apply the Curves adjustment
    executeAction(charIDToTypeID("CrvA"), desc, DialogModes.NO);
})();
"""
        return jsx
    }
}

