import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - QTRQuadFile

/// Parsed representation of a .quad file (QuadTone RIP curve set).
/// Contains 8 ink channels, each with 256 values (one per input level 0–255).
/// Values are 16-bit unsigned (0–65535), where 65535 = max ink.
struct QTRQuadFile: Identifiable, Equatable {
    static func == (lhs: QTRQuadFile, rhs: QTRQuadFile) -> Bool { lhs.id == rhs.id }

    let id: UUID
    let fileName: String
    let parentFolderName: String     // e.g. "QuadP800-DN" — used for process inference
    let comments: [String]           // header comment lines
    let channels: [InkChannel]       // K, C, M, Y, LC, LM, LK, LLK (always 8)
    let linearizationHistory: [LinearizationEntry]  // parsed from comments

    var channelNames: [String] {
        channels.map { $0.name }
    }

    /// Returns the active channels (those with at least one non-zero value).
    var activeChannels: [InkChannel] {
        channels.filter { $0.isActive }
    }

    init(id: UUID = UUID(), fileName: String, parentFolderName: String = "",
         comments: [String], channels: [InkChannel],
         linearizationHistory: [LinearizationEntry] = []) {
        self.id = id
        self.fileName = fileName
        self.parentFolderName = parentFolderName
        self.comments = comments
        self.channels = channels
        self.linearizationHistory = linearizationHistory
    }

    /// Infer the print process using a three-tier strategy:
    /// 1. Manual override (persisted in UserDefaults via CurveProcessOverrideStore)
    /// 2. Parent folder name heuristics (e.g. "QuadP800-DN" → Digital Neg)
    /// 3. Filename heuristics (original fallback)
    var inferredProcess: PrintProcess {
        // 1. Check for manual override
        if let override = CurveProcessOverrideStore.shared.override(for: fileName) {
            return override
        }

        // 2. Parent folder heuristics
        if let folderProcess = Self.processFromFolderName(parentFolderName) {
            return folderProcess
        }

        // 3. Filename heuristics (original logic)
        return Self.processFromFileName(fileName)
    }

    /// Infer process from the parent profile folder name.
    private static func processFromFolderName(_ folderName: String) -> PrintProcess? {
        guard !folderName.isEmpty else { return nil }
        let lower = folderName.lowercased()
        // DN folders contain mixed processes — let filename classification handle it
        if lower.contains("-dn") || lower.contains("digneg") { return nil }
        if lower.contains("cyano") { return .cyanotype }
        if lower.contains("plat") || lower.contains("ptpd") { return .platinumPd }
        if lower.contains("salt") { return .saltPrint }
        if lower.contains("vandyke") || lower.contains("vdb") { return .vanDykeBrown }
        if lower.contains("gum") || lower.contains("bichromate") { return .gumBichromate }
        if lower.contains("carbon") { return .carbonTransfer }
        if lower.contains("silver") || lower.contains("gelatin") { return .silverGelatin }
        return nil
    }

    /// Infer process from the filename using common naming conventions.
    private static func processFromFileName(_ fileName: String) -> PrintProcess {
        let lower = fileName.lowercased()

        // Direct to Plate / Gravure / Photopolymer
        if lower.hasPrefix("dtp") || lower.contains("gravure") || lower.contains("openbite") { return .directToPlate }

        // Cyanotype
        if lower.hasPrefix("cyanotype") || lower.contains("cyano") { return .cyanotype }

        // Chrysotype (new cyanotype variant)
        if lower.contains("chrysotype") { return .chrysotype }

        // Platinum/Palladium
        if lower.hasPrefix("ptpd") || lower.contains("platinum") || lower.contains("palladium") || lower.contains("pt-pd") { return .platinumPd }

        // Salt Print
        if lower.hasPrefix("salt") { return .saltPrint }

        // Van Dyke Brown
        if lower.hasPrefix("vandyke") || lower.contains("vdb") { return .vanDykeBrown }

        // Silver Gelatin (Ilford RC papers, PiezoDN-Silver)
        if lower.hasPrefix("ilford") || lower.contains("piezodn-silver") || lower.contains("silver") { return .silverGelatin }

        // Gum Bichromate
        if lower.contains("gum") || lower.contains("bichromate") { return .gumBichromate }

        // Carbon Transfer
        if lower.contains("carbon") { return .carbonTransfer }

        // Utility / blocking test — classify as inkjetBW (default bucket)
        if lower.contains("blocking") || lower.contains("test") || lower.contains("standard") { return .inkjetBW }

        // Piezography / B&W inkjet (P8- prefix for Piezography preset curves)
        if lower.hasPrefix("p8-") || lower.contains("piezo") || lower.contains("k7") || lower.contains("k6")
            || lower.contains("pro") || lower.contains("hdk") { return .inkjetBW }

        // Digital Negative (generic fallback for -dn named curves)
        if lower.contains("-dn") || lower.contains("digneg") || lower.contains("neg") { return .digitalNeg }

        // Default: inkjet B&W
        return .inkjetBW
    }

    /// Infer ink set from filename.
    var inferredInkSet: InkSet {
        let lower = fileName.lowercased()
        if lower.contains("china") { return .chinaInk }
        if lower.contains("piezo") || lower.contains("k7") || lower.contains("k6")
            || lower.contains("hdk") || lower.contains("pro") { return .piezography }
        if lower.contains("swift") { return .swiftInk }
        return .ultrachrome
    }

    /// Max ink limit across all active channels (percentage).
    var maxInkLimit: Double {
        activeChannels.map(\.maxInkPercent).max() ?? 0
    }
}

// MARK: - InkChannel

/// A single ink channel in a .quad file (256 values).
struct InkChannel: Identifiable {
    let id: UUID
    let name: String             // e.g. "K", "C", "M", "Y", "LC", "LM", "LK", "LLK"
    let values: [UInt16]         // 256 entries, index = input level, value = ink output (0–65535)

    /// Cached normalized curve data for graphing (0.0–1.0 range).
    /// Pre-computed at init to avoid recalculating on every Canvas draw.
    let normalizedCurve: [(input: Double, output: Double)]

    let isActive: Bool
    let maxInkPercent: Double

    init(id: UUID = UUID(), name: String, values: [UInt16]) {
        self.id = id
        self.name = name
        self.values = values
        self.normalizedCurve = values.enumerated().map { i, v in
            (input: Double(i) / 255.0, output: Double(v) / 65535.0)
        }
        self.isActive = values.contains(where: { $0 > 0 })
        let maxVal = values.max() ?? 0
        self.maxInkPercent = Double(maxVal) / 65535.0 * 100.0
    }
}

// MARK: - LinearizationEntry

/// Parsed from .quad comment headers: which measurement file + input quad were used.
struct LinearizationEntry {
    let measurementFile: String
    let inputQuadFile: String
}

// MARK: - SpyderPRINTMeasurement

/// Parsed SpyderPRINT measurement export (tab-separated Step / L* / a* / b*).
struct SpyderPRINTMeasurement: Identifiable {
    let id: UUID
    let fileName: String
    let hasHeader: Bool              // smoothed files have "QuadToneProfiler Measurement Data File" header
    let steps: [LabStep]

    var stepCount: Int { steps.count }

    /// Paper white L* (first step).
    var paperWhiteL: Double? { steps.first?.labL }
    /// Maximum density L* (darkest step).
    var dMaxL: Double? { steps.min(by: { $0.labL < $1.labL })?.labL }
    /// Density range: paper white L* minus Dmax L*.
    var densityRange: Double? {
        guard let white = paperWhiteL, let dmax = dMaxL else { return nil }
        return white - dmax
    }

    /// Detect anomalies: steps where L* increases (should monotonically decrease
    /// from paper white to Dmax in a properly linearized target).
    var anomalies: [AnomalyReport] {
        var results: [AnomalyReport] = []
        for i in 1..<steps.count {
            let delta = steps[i].labL - steps[i-1].labL
            if delta > 1.0 {
                // L* jumped UP by more than 1 — unexpected reversal
                results.append(AnomalyReport(
                    stepIndex: i,
                    step: steps[i],
                    previousStep: steps[i-1],
                    deltaL: delta,
                    type: .reversal
                ))
            }
        }
        // Check for flat zones (no density change across 3+ steps)
        for i in 2..<steps.count {
            let range = abs(steps[i].labL - steps[i-2].labL)
            if range < 0.3 {
                results.append(AnomalyReport(
                    stepIndex: i,
                    step: steps[i],
                    previousStep: steps[i-2],
                    deltaL: range,
                    type: .flatZone
                ))
            }
        }
        return results
    }

    init(id: UUID = UUID(), fileName: String, hasHeader: Bool = false, steps: [LabStep]) {
        self.id = id
        self.fileName = fileName
        self.hasHeader = hasHeader
        self.steps = steps
    }
}

// MARK: - LabStep

/// A single measurement step: step number + L*a*b* color values.
struct LabStep: Identifiable {
    let id: UUID
    let stepNumber: Int
    let labL: Double     // Lightness (0 = black, 100 = white)
    let labA: Double     // green–red axis
    let labB: Double     // blue–yellow axis

    init(id: UUID = UUID(), stepNumber: Int, labL: Double, labA: Double, labB: Double) {
        self.id = id
        self.stepNumber = stepNumber
        self.labL = labL
        self.labA = labA
        self.labB = labB
    }
}

// MARK: - AnomalyReport

struct AnomalyReport: Identifiable {
    let id = UUID()
    let stepIndex: Int
    let step: LabStep
    let previousStep: LabStep
    let deltaL: Double
    let type: AnomalyType

    enum AnomalyType: String {
        case reversal = "Reversal"      // L* went UP instead of down
        case flatZone = "Flat Zone"     // No density change across multiple steps
    }
}

// MARK: - QTRFileParser

enum QTRFileParser {

    static let standardChannelNames = ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"]

    // MARK: - Parse .quad file

    /// Parse a .quad file from disk.
    static func parseQuadFile(at url: URL) throws -> QTRQuadFile {
        let content = try String(contentsOf: url, encoding: .utf8)
        let parentFolder = url.deletingLastPathComponent().lastPathComponent
        return try parseQuadFile(content: content, fileName: url.lastPathComponent, parentFolderName: parentFolder)
    }

    /// Parse .quad file content.
    static func parseQuadFile(content: String, fileName: String, parentFolderName: String = "") throws -> QTRQuadFile {
        let lines = content.components(separatedBy: .newlines)
        var comments: [String] = []
        var channelValues: [[UInt16]] = []
        var currentChannel: [UInt16] = []
        var linearizationHistory: [LinearizationEntry] = []
        var inChannel = false

        // Parse linearization history from comments
        var pendingMeasurementFile: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("##") || trimmed.hasPrefix("#") {
                comments.append(trimmed)

                // Extract linearization history
                if trimmed.contains("Linearized from measurement file:") {
                    let parts = trimmed.components(separatedBy: "Linearized from measurement file:")
                    if parts.count > 1 {
                        pendingMeasurementFile = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                } else if trimmed.contains("and input quad file:") {
                    let parts = trimmed.components(separatedBy: "and input quad file:")
                    if parts.count > 1, let mf = pendingMeasurementFile {
                        linearizationHistory.append(LinearizationEntry(
                            measurementFile: mf,
                            inputQuadFile: parts[1].trimmingCharacters(in: .whitespaces)
                        ))
                        pendingMeasurementFile = nil
                    }
                }

                // Detect channel marker (e.g. "# K curve", "# C Curve")
                let lower = trimmed.lowercased()
                if lower.contains("curve") && !lower.contains("linearized") && !lower.contains("max") {
                    if inChannel && !currentChannel.isEmpty {
                        // Pad to 256 if needed
                        while currentChannel.count < 256 { currentChannel.append(0) }
                        channelValues.append(Array(currentChannel.prefix(256)))
                    }
                    currentChannel = []
                    inChannel = true
                }
                continue
            }

            // Data line: single integer value
            if inChannel, let value = UInt16(trimmed) {
                currentChannel.append(value)
            } else if inChannel && trimmed.isEmpty {
                // Skip blank lines within a channel
                continue
            }
        }

        // Flush last channel
        if inChannel && !currentChannel.isEmpty {
            while currentChannel.count < 256 { currentChannel.append(0) }
            channelValues.append(Array(currentChannel.prefix(256)))
        }

        // Build channels (expect 8, pad with empty if fewer)
        var channels: [InkChannel] = []
        for i in 0..<8 {
            let name = i < standardChannelNames.count ? standardChannelNames[i] : "CH\(i)"
            let vals = i < channelValues.count ? channelValues[i] : Array(repeating: UInt16(0), count: 256)
            channels.append(InkChannel(name: name, values: vals))
        }

        return QTRQuadFile(
            fileName: fileName,
            parentFolderName: parentFolderName,
            comments: comments,
            channels: channels,
            linearizationHistory: linearizationHistory
        )
    }

    // MARK: - Parse SpyderPRINT measurement file

    /// Parse a SpyderPRINT measurement export (.txt with Step/L*/a*/b*).
    static func parseMeasurement(at url: URL) throws -> SpyderPRINTMeasurement {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parseMeasurement(content: content, fileName: url.lastPathComponent)
    }

    /// Parse measurement content.
    static func parseMeasurement(content: String, fileName: String) throws -> SpyderPRINTMeasurement {
        let lines = content.components(separatedBy: .newlines)
        var steps: [LabStep] = []
        var hasHeader = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Detect header line
            if trimmed.contains("QuadToneProfiler") || trimmed.contains("Step") && trimmed.contains("Lab") {
                hasHeader = true
                continue
            }

            // Parse data: Step\tL*\ta*\tb*
            let parts = trimmed.components(separatedBy: "\t")
            if parts.count >= 4,
               let step = Int(parts[0].trimmingCharacters(in: .whitespaces)),
               let labL = Double(parts[1].trimmingCharacters(in: .whitespaces)),
               let labA = Double(parts[2].trimmingCharacters(in: .whitespaces)),
               let labB = Double(parts[3].trimmingCharacters(in: .whitespaces)) {
                steps.append(LabStep(stepNumber: step, labL: labL, labA: labA, labB: labB))
            }
        }

        return SpyderPRINTMeasurement(fileName: fileName, hasHeader: hasHeader, steps: steps)
    }

    // MARK: - Smoothing

    /// Apply Savitzky-Golay (quadratic) smoothing to measurement L*/a*/b* values.
    /// Window size should be odd (3, 5, 7...).
    static func smooth(steps: [LabStep], windowSize: Int = 5) -> [LabStep] {
        guard steps.count > windowSize else { return steps }
        let lValues = steps.map(\.labL)
        let aValues = steps.map(\.labA)
        let bValues = steps.map(\.labB)
        let smoothedL = SavitzkyGolay.smooth(lValues, windowSize: windowSize)
        let smoothedA = SavitzkyGolay.smooth(aValues, windowSize: windowSize)
        let smoothedB = SavitzkyGolay.smooth(bValues, windowSize: windowSize)
        return steps.enumerated().map { i, step in
            LabStep(stepNumber: step.stepNumber, labL: smoothedL[i], labA: smoothedA[i], labB: smoothedB[i])
        }
    }

    /// Monotonic enforcement: ensure L* only decreases from paper white to Dmax.
    /// Clamps any reversal to the previous step's value.
    static func enforceMonotonic(steps: [LabStep]) -> [LabStep] {
        guard !steps.isEmpty else { return steps }
        var result = [steps[0]]
        for i in 1..<steps.count {
            let prev = result[i-1]
            let current = steps[i]
            let clampedL = min(prev.labL, current.labL)
            result.append(LabStep(
                stepNumber: current.stepNumber,
                labL: clampedL,
                labA: current.labA,
                labB: current.labB
            ))
        }
        return result
    }

    // MARK: - Scan directories

    /// Scan the QTR quadtone directory for .quad files.
    static func scanQuadDirectory(at path: String = "/Library/Printers/QTR/quadtone/QuadP800-DN") -> [URL] {
        let url = URL(fileURLWithPath: path)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "quad" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    /// Scan the SpyderPRINT export directory for measurement files.
    static func scanMeasurementDirectory(
        at path: String = "~/Library/Preferences/Datacolor/SpyderPRINT/Data/Export"
    ) -> [URL] {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    // MARK: - Serialize .quad file

    /// Serialize a QTRQuadFile to the .quad text format (per-channel, one value per line).
    /// Matches the format expected by `parseQuadFile` and QuadTone RIP itself.
    static func serializeQuadFile(_ quad: QTRQuadFile) -> String {
        var lines: [String] = []

        // Header comments (strip any existing channel markers to avoid duplication)
        for comment in quad.comments {
            let lower = comment.lowercased()
            let isChannelMarker = lower.contains("curve") && !lower.contains("linearized") && !lower.contains("max")
            if !isChannelMarker {
                lines.append(comment)
            }
        }
        if quad.comments.isEmpty {
            let channelHeader = quad.channels.map(\.name).joined(separator: ",")
            lines.append("## QuadToneRIP \(channelHeader)")
            lines.append("# Generated by HoehnPhotos CurveLab")
        }
        lines.append("")

        // Channel data: per-channel format with marker comment + 256 values per line
        for channel in quad.channels {
            lines.append("# \(channel.name) curve")
            for value in channel.values {
                lines.append(String(value))
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Install .quad file

    /// Write a serialized .quad file into a CurveProfileFolder's directory.
    /// Creates a `.bak` backup of any existing file with the same name.
    /// - Returns: The URL of the installed file.
    @discardableResult
    static func installQuadFile(
        _ quad: QTRQuadFile,
        content: String,
        destination: CurveProfileFolder
    ) throws -> URL {
        let fm = FileManager.default
        let fileURL = destination.directoryURL.appendingPathComponent(quad.fileName)

        // Backup existing file if present
        if fm.fileExists(atPath: fileURL.path) {
            let backupURL = fileURL.appendingPathExtension("bak")
            // Remove stale backup so the copy succeeds
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.copyItem(at: fileURL, to: backupURL)
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - File open panels

    /// Present an NSOpenPanel filtered to .quad files, starting in the QTR quadtone directory.
    @MainActor
    static func openQuadFilePanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open .quad File"
        panel.allowedContentTypes = [.init(filenameExtension: "quad")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Library/Printers/QTR/quadtone/")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Present an NSOpenPanel filtered to .txt measurement files.
    @MainActor
    static func openMeasurementFilePanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Measurement File"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - MeasurementSorter

/// Utilities for reordering SpyderPRINT measurement steps.
struct MeasurementSorter {

    /// Reverse step order (for instruments that read dark-to-light instead of light-to-dark).
    /// Step numbers are reassigned sequentially after reversal.
    static func pivot(_ measurement: SpyderPRINTMeasurement) -> SpyderPRINTMeasurement {
        let reversed = measurement.steps.reversed().enumerated().map { index, step in
            LabStep(stepNumber: index + 1, labL: step.labL, labA: step.labA, labB: step.labB)
        }
        return SpyderPRINTMeasurement(
            fileName: measurement.fileName,
            hasHeader: measurement.hasHeader,
            steps: reversed
        )
    }

    /// Sort steps by L* value ascending (darkest to lightest).
    /// Step numbers are reassigned sequentially after sorting.
    static func sort(_ measurement: SpyderPRINTMeasurement) -> SpyderPRINTMeasurement {
        let sorted = measurement.steps
            .sorted { $0.labL < $1.labL }
            .enumerated()
            .map { index, step in
                LabStep(stepNumber: index + 1, labL: step.labL, labA: step.labA, labB: step.labB)
            }
        return SpyderPRINTMeasurement(
            fileName: measurement.fileName,
            hasHeader: measurement.hasHeader,
            steps: sorted
        )
    }

    /// Restore original step ordering from a reference measurement.
    /// Matches steps by their original step numbers and restores the original sequence.
    static func revert(
        _ measurement: SpyderPRINTMeasurement,
        original: SpyderPRINTMeasurement
    ) -> SpyderPRINTMeasurement {
        // Build a lookup from L* values in the current measurement to their Lab data.
        // Since the original has the correct ordering, we pair by index position.
        guard measurement.steps.count == original.steps.count else { return original }

        // The original defines the canonical order; re-map current Lab values back
        // to the original step sequence using index correspondence.
        let restoredSteps = original.steps.enumerated().map { index, origStep in
            // Use the Lab data from the current measurement at the position that
            // corresponds to this original step. Since we only reorder, and the
            // original step numbers are sequential, we can rebuild directly.
            LabStep(
                stepNumber: origStep.stepNumber,
                labL: origStep.labL,
                labA: origStep.labA,
                labB: origStep.labB
            )
        }
        return SpyderPRINTMeasurement(
            fileName: measurement.fileName,
            hasHeader: measurement.hasHeader,
            steps: restoredSteps
        )
    }
}

// MARK: - Savitzky-Golay Filter

/// Savitzky-Golay smoothing filter (quadratic/cubic polynomial fitting).
/// Preserves higher-order moments of the data better than a moving average,
/// retaining peak shapes and curve features while removing noise.
enum SavitzkyGolay {

    /// Apply Savitzky-Golay quadratic smoothing to an array of Doubles.
    /// - Parameters:
    ///   - values: The input signal.
    ///   - windowSize: Must be odd and >= 5. Clamped/rounded if needed.
    /// - Returns: Smoothed array of the same length.
    static func smooth(_ values: [Double], windowSize: Int) -> [Double] {
        let n = values.count
        // Ensure window is odd and at least 5
        var w = max(5, windowSize)
        if w % 2 == 0 { w += 1 }
        // Window can't exceed data length
        if w > n { return values }

        let half = w / 2

        // Precompute Savitzky-Golay convolution coefficients for quadratic (order=2) fit.
        // For a window of size w = 2*half+1, the smoothing coefficients for the central
        // point of a least-squares quadratic fit are:
        //   c_i = A + B*i + C*i^2  where i ranges from -half to +half
        // For the zeroth derivative (smoothing), the coefficients simplify to:
        //   c_i = (3*m*(m+1) - 1 - 5*i^2) / ((2*m+1)*(3*m*(m+1) - 1))
        //   where m = half
        let m = Double(half)
        let denom = (2.0 * m + 1.0) * (3.0 * m * (m + 1.0) - 1.0)
        let numerConst = 3.0 * m * (m + 1.0) - 1.0

        var coeffs = [Double](repeating: 0, count: w)
        for i in 0..<w {
            let offset = Double(i - half)
            coeffs[i] = (numerConst - 5.0 * offset * offset) / denom
        }

        var result = [Double](repeating: 0, count: n)

        // Interior points: full convolution
        for i in half..<(n - half) {
            var sum = 0.0
            for j in 0..<w {
                sum += coeffs[j] * values[i - half + j]
            }
            result[i] = sum
        }

        // Boundary points: use progressively smaller symmetric windows (min size 5),
        // falling back to the original value at the very edges.
        for i in 0..<half {
            let availableHalf = min(i, n - 1 - i)
            if availableHalf >= 2 {
                // Recompute coefficients for this smaller window
                let bm = Double(availableHalf)
                let bDenom = (2.0 * bm + 1.0) * (3.0 * bm * (bm + 1.0) - 1.0)
                let bNumerConst = 3.0 * bm * (bm + 1.0) - 1.0
                var sum = 0.0
                for j in -availableHalf...availableHalf {
                    let c = (bNumerConst - 5.0 * Double(j * j)) / bDenom
                    sum += c * values[i + j]
                }
                result[i] = sum
            } else {
                result[i] = values[i]
            }

            // Mirror for the trailing edge
            let mirror = n - 1 - i
            if mirror != i {
                if availableHalf >= 2 {
                    let bm = Double(availableHalf)
                    let bDenom = (2.0 * bm + 1.0) * (3.0 * bm * (bm + 1.0) - 1.0)
                    let bNumerConst = 3.0 * bm * (bm + 1.0) - 1.0
                    var sum = 0.0
                    for j in -availableHalf...availableHalf {
                        let c = (bNumerConst - 5.0 * Double(j * j)) / bDenom
                        sum += c * values[mirror + j]
                    }
                    result[mirror] = sum
                } else {
                    result[mirror] = values[mirror]
                }
            }
        }

        return result
    }
}

// MARK: - InkChannelSmoother

/// Savitzky-Golay smoothing for ink channel curves.
/// Uses a quadratic polynomial fit that preserves curve shape better than moving average.
struct InkChannelSmoother {

    /// Apply Savitzky-Golay smoothing to a single ink channel's values.
    /// Window size should be odd (5, 7, 9...) for symmetric fitting.
    static func smooth(channel: InkChannel, windowSize: Int) -> InkChannel {
        let doubles = channel.values.map { Double($0) }
        let smoothed = SavitzkyGolay.smooth(doubles, windowSize: windowSize)
        let clamped: [UInt16] = smoothed.map {
            UInt16(min(65535, max(0, $0.rounded())))
        }
        return InkChannel(name: channel.name, values: clamped)
    }

    /// Apply Savitzky-Golay smoothing to all channels in a quad file.
    static func smooth(quad: QTRQuadFile, windowSize: Int) -> QTRQuadFile {
        let smoothedChannels = quad.channels.map { channel in
            channel.isActive ? smooth(channel: channel, windowSize: windowSize) : channel
        }
        return QTRQuadFile(
            fileName: quad.fileName,
            parentFolderName: quad.parentFolderName,
            comments: quad.comments,
            channels: smoothedChannels,
            linearizationHistory: quad.linearizationHistory
        )
    }
}

// MARK: - CurveInverter

/// Inverts ink channel curves for positive-to-negative (or negative-to-positive) conversion.
struct CurveInverter {

    /// Invert all channel curves in a quad file.
    /// For each channel value at index i, the new value is taken from index (255 - i).
    static func invert(quad: QTRQuadFile) -> QTRQuadFile {
        let invertedChannels = quad.channels.map { channel -> InkChannel in
            guard channel.isActive else { return channel }
            let inverted = (0..<256).map { i in channel.values[255 - i] }
            return InkChannel(name: channel.name, values: inverted)
        }
        return QTRQuadFile(
            fileName: quad.fileName,
            parentFolderName: quad.parentFolderName,
            comments: quad.comments,
            channels: invertedChannels,
            linearizationHistory: quad.linearizationHistory
        )
    }
}
