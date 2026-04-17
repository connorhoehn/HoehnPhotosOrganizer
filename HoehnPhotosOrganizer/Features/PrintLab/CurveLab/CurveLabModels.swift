import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - PrintLabPage

/// Sub-page navigation within Print Lab.
enum PrintLabPage: String, CaseIterable, Identifiable {
    case printLayout   = "Print Layout"
    case curveBuilder  = "Curves"
    case processes     = "Processes"
    case printers      = "Printers"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .printLayout:  return "printer.fill"
        case .curveBuilder: return "waveform.path.ecg"
        case .processes:    return "paintbrush.pointed"
        case .printers:     return "printer.dotmatrix.fill"
        }
    }
}

// MARK: - QTRCurve

/// Represents a single QTR linearization curve (.txt file).
struct QTRCurve: Identifiable, Codable {
    let id: UUID
    var name: String
    var fileName: String           // e.g. "Hahnemuhle-Plat-Warm.txt"
    var process: PrintProcess      // which alt process this targets
    var inkTone: InkTone           // warm, neutral, cool, etc.
    var steps: [CurveStep]         // the actual curve data points
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, fileName: String = "",
         process: PrintProcess = .inkjetBW, inkTone: InkTone = .neutral,
         steps: [CurveStep] = [], notes: String = "",
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.process = process
        self.inkTone = inkTone
        self.steps = steps
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - CurveStep

/// A single data point in a QTR curve: input density → output ink value.
struct CurveStep: Identifiable, Codable {
    let id: UUID
    var input: Double    // 0.0–1.0 (paper white to max density)
    var output: Double   // 0.0–1.0 (no ink to full ink)

    init(id: UUID = UUID(), input: Double, output: Double) {
        self.id = id
        self.input = input
        self.output = output
    }
}

// MARK: - InkTone (legacy — kept for QTRCurve model compat)

/// Ink tone for multi-ink QTR setups.
enum InkTone: String, CaseIterable, Codable, Identifiable {
    case warm    = "Warm"
    case neutral = "Neutral"
    case cool    = "Cool"
    case custom  = "Custom"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .warm:    return .orange
        case .neutral: return .gray
        case .cool:    return .blue
        case .custom:  return .purple
        }
    }
}

// MARK: - InkSet

/// Physical ink sets that can be installed in a printer.
/// Determines which QTR curve profile folders are relevant.
enum InkSet: String, CaseIterable, Codable, Identifiable {
    case ultrachrome  = "UltraChrome"
    case piezography  = "Piezography"
    case swiftInk     = "SwiftInk"
    case chinaInk     = "China Ink"

    var id: String { rawValue }

    var channelCount: Int { 8 }

    var icon: String {
        switch self {
        case .ultrachrome: return "drop.fill"
        case .piezography: return "drop.halffull"
        case .swiftInk:    return "hare"
        case .chinaInk:    return "paintbrush.pointed"
        }
    }
}

// MARK: - PrintProcess

/// Alternative and digital print processes.
enum PrintProcess: String, CaseIterable, Codable, Identifiable {
    case inkjetBW     = "Inkjet B&W"
    case inkjetColor  = "Inkjet Color"
    case digitalNeg   = "Digital Negative"
    case platinumPd   = "Platinum/Palladium"
    case cyanotype    = "Cyanotype"
    case silverGelatin = "Silver Gelatin"
    case saltPrint    = "Salt Print"
    case vanDykeBrown = "Van Dyke Brown"
    case gumBichromate = "Gum Bichromate"
    case carbonTransfer = "Carbon Transfer"
    case directToPlate  = "Direct to Plate"
    case chrysotype     = "Chrysotype"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .inkjetBW:       return "printer"
        case .inkjetColor:    return "printer.fill"
        case .digitalNeg:     return "film"
        case .platinumPd:     return "sparkles"
        case .cyanotype:      return "drop.fill"
        case .silverGelatin:  return "camera.aperture"
        case .saltPrint:      return "leaf"
        case .vanDykeBrown:   return "paintbrush"
        case .gumBichromate:  return "paintpalette"
        case .carbonTransfer: return "square.stack.3d.up"
        case .directToPlate:  return "rectangle.3.group"
        case .chrysotype:     return "sun.max"
        }
    }

    /// Whether this process uses positive curves (vs negative/inverted).
    var usesPositiveCurve: Bool {
        switch self {
        case .inkjetBW, .inkjetColor: return true
        default: return false  // alt processes typically print through a digital negative (directToPlate, chrysotype included)
        }
    }

    /// Whether this is a hands-on alternative process that uses sensitizer chemistry.
    var usesSensitizer: Bool {
        switch self {
        case .platinumPd, .cyanotype, .saltPrint, .vanDykeBrown, .gumBichromate, .chrysotype:
            return true
        default:
            return false
        }
    }

    /// Typical ink/sensitizer drop count ranges for this process.
    var typicalDropCounts: String {
        switch self {
        case .platinumPd:     return "18–24 drops per mL sensitizer"
        case .cyanotype:      return "16–20 drops ferric ammonium citrate + potassium ferricyanide"
        case .silverGelatin:  return "N/A — enlarger exposure"
        case .saltPrint:      return "20–24 drops silver nitrate solution"
        case .vanDykeBrown:   return "20–22 drops sensitizer"
        case .gumBichromate:  return "Varies — gum + pigment + dichromate ratio"
        case .carbonTransfer: return "Tissue-based — no drops"
        case .directToPlate:  return "N/A — exposure-based process, no sensitizer coating"
        case .chrysotype:     return "Gold chloride 8–12 drops + ferric ammonium citrate 16–20 drops per 8×10"
        default:              return "N/A"
        }
    }
}

// MARK: - SplitToneConfig

/// QTR-style split-tone configuration for blending warm/cool inks.
struct SplitToneConfig: Equatable {
    var enabled: Bool = false
    var curve1Highlights: Double = 0  // 0–100
    var curve1Midtones: Double = 0
    var curve1Shadows: Double = 0
    var curve2Highlights: Double = 0
    var curve2Midtones: Double = 0
    var curve2Shadows: Double = 0
    var curve3Highlights: Double = 0
    var curve3Midtones: Double = 0
    var curve3Shadows: Double = 0
}

// MARK: - CurveProfileFolder

/// A curve profile folder discovered on disk at /Library/Printers/QTR/quadtone/.
/// Each folder represents a collection of .quad curves calibrated for a specific
/// printer + ink set combination (e.g. QuadP800-Pro = P800 with Piezography Pro inks).
struct CurveProfileFolder: Identifiable, Hashable {
    let directoryName: String    // e.g. "QuadP800-DN"
    let directoryURL: URL

    var id: String { directoryName }

    /// Human-readable display name derived from the directory name
    var displayName: String {
        // Strip "Quad" prefix and clean up
        var name = directoryName
        if name.hasPrefix("Quad") { name = String(name.dropFirst(4)) }
        // Insert spaces before capitals and dashes for readability
        return name
    }

    /// Ink channel count — detected from the header of the first .quad file,
    /// or inferred from directory naming conventions.
    var channelCount: Int {
        // 4-channel (KCMY) printers use "UT" suffix naming
        let lower = directoryName.lowercased()
        if lower.hasSuffix("-ut") || lower.hasSuffix("-ut2") { return 4 }
        return 8
    }

    /// Channel names based on channel count
    var channelNames: [String] {
        channelCount == 4
            ? ["K", "C", "M", "Y"]
            : ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"]
    }

    /// Printer family inferred from directory name
    var printerFamily: String {
        let lower = directoryName.lowercased()
        if lower.contains("p800") || lower.contains("p8000") { return "Epson SC-P800" }
        if lower.contains("p900") || lower.contains("p9000") { return "Epson SC-P900" }
        if lower.contains("p600") || lower.contains("p6000") { return "Epson SC-P600" }
        if lower.contains("p700") || lower.contains("p7000") { return "Epson SC-P700" }
        if lower.contains("860")  { return "Epson XP-860" }
        if lower.contains("870")  { return "Epson XP-870" }
        if lower.contains("890")  { return "Epson XP-890" }
        if lower.contains("1290") { return "Epson 1290" }
        if lower.contains("r2880") { return "Epson R2880" }
        if lower.contains("r2400") { return "Epson R2400" }
        if lower.contains("3880") { return "Epson 3880" }
        if lower.contains("4880") { return "Epson 4880" }
        if lower.contains("7890") { return "Epson 7890" }
        if lower.contains("9890") { return "Epson 9890" }
        // Fallback: use directory name
        return displayName
    }

    /// Ink set / profile type inferred from directory name suffix
    var inkSetLabel: String {
        let lower = directoryName.lowercased()
        if lower.contains("-pro")     { return "Piezography Pro" }
        if lower.contains("-hdk7")    { return "Piezography HD K7" }
        if lower.contains("-dn-open") { return "Digital Neg (OpenRIP)" }
        if lower.contains("-dn")      { return "Digital Neg" }
        if lower.hasSuffix("-ut")     { return "Claria (UT)" }
        if lower.hasSuffix("-ut2")    { return "Claria (UT2)" }
        if lower.hasSuffix("-ut7")    { return "UltraTone K7" }
        if lower.contains("-mis")     { return "MIS Inks" }
        if lower.contains("-3mk")     { return "3-Matte K" }
        return "Standard"
    }

    /// Number of .quad files in this folder
    var curveCount: Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directoryURL.path) else { return 0 }
        return items.filter { $0.hasSuffix(".quad") }.count
    }

    /// Full path string for QTRFileParser
    var quadDirectoryPath: String { directoryURL.path }

    // MARK: - Discovery

    /// Scan /Library/Printers/QTR/quadtone/ and return all folders that contain .quad files.
    static func discoverAll(at basePath: String = "/Library/Printers/QTR/quadtone") -> [CurveProfileFolder] {
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: basePath)
        guard let contents = try? fm.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            // Only include folders that actually contain .quad files
            let quadFiles = (try? fm.contentsOfDirectory(atPath: url.path))?
                .filter { $0.hasSuffix(".quad") } ?? []
            guard !quadFiles.isEmpty else { return nil }
            return CurveProfileFolder(directoryName: url.lastPathComponent, directoryURL: url)
        }
        .sorted { $0.directoryName < $1.directoryName }
    }
}

// MARK: - PrinterModel (backward-compat alias)

/// Alias for views that reference PrinterModel — maps to CurveProfileFolder.
/// Provides the same interface so existing code compiles.
typealias PrinterModel = CurveProfileFolder

// MARK: - CurvesSubPage

/// Sub-pages within the "Curves" top-level tab.
/// Rendered as a horizontal menu bar inside the Curves area.
enum CurvesSubPage: String, CaseIterable, Identifiable {
    case gallery    = "Gallery"
    case creator    = "Creator"
    case linearize  = "Linearize"
    case blend      = "Blend"
    case remap      = "Remap"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .gallery:   return "square.grid.2x2"
        case .creator:   return "plus.circle"
        case .linearize: return "line.diagonal"
        case .blend:     return "arrow.triangle.merge"
        case .remap:     return "arrow.triangle.swap"
        }
    }
}

// MARK: - CurveEditSession

/// Tracks an active curve editing session with undo/redo and dirty state.
/// When the user navigates away from an unsaved session, we prompt to save or discard.
struct CurveEditSession: Identifiable {
    let id: UUID
    let createdAt: Date

    /// The quad file being edited (nil for brand-new curves)
    var sourceQuadFile: QTRQuadFile?
    var sourceFileName: String

    /// Printer context captured at session start
    var printerProfile: CurveProfileFolder?
    var inkSet: InkSet
    var process: PrintProcess

    /// Current curve state
    var steps: [CurveStep]
    var smoothingWindow: Int = 5
    var gammaAdjust: Double = 1.0

    /// Undo/redo stacks
    var undoStack: [CurveEditSnapshot] = []
    var redoStack: [CurveEditSnapshot] = []

    /// Whether the session has unsaved changes
    var isDirty: Bool = false

    /// Snapshot of the initial state for diff comparison
    var initialSteps: [CurveStep]

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(
        sourceQuadFile: QTRQuadFile? = nil,
        sourceFileName: String = "Untitled.quad",
        printerProfile: CurveProfileFolder? = nil,
        inkSet: InkSet = .piezography,
        process: PrintProcess = .platinumPd,
        steps: [CurveStep] = []
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.sourceQuadFile = sourceQuadFile
        self.sourceFileName = sourceFileName
        self.printerProfile = printerProfile
        self.inkSet = inkSet
        self.process = process
        self.steps = steps
        self.initialSteps = steps
    }

    mutating func recordSnapshot(label: String) {
        undoStack.append(CurveEditSnapshot(label: label, steps: steps, smoothingWindow: smoothingWindow, gammaAdjust: gammaAdjust))
        redoStack.removeAll()
        isDirty = true
        // Cap undo stack at 50
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    mutating func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(CurveEditSnapshot(label: "Before undo", steps: steps, smoothingWindow: smoothingWindow, gammaAdjust: gammaAdjust))
        steps = snapshot.steps
        smoothingWindow = snapshot.smoothingWindow
        gammaAdjust = snapshot.gammaAdjust
    }

    mutating func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(CurveEditSnapshot(label: "Before redo", steps: steps, smoothingWindow: smoothingWindow, gammaAdjust: gammaAdjust))
        steps = snapshot.steps
        smoothingWindow = snapshot.smoothingWindow
        gammaAdjust = snapshot.gammaAdjust
    }
}

/// A point-in-time snapshot of curve editor state for undo/redo.
struct CurveEditSnapshot: Identifiable {
    let id = UUID()
    let label: String
    let steps: [CurveStep]
    let smoothingWindow: Int
    let gammaAdjust: Double
    let timestamp = Date()
}

// MARK: - CurveEditSessionSnapshot

/// Codable snapshot of a CurveEditSession for disk persistence.
/// Non-Codable fields (sourceQuadFile, printerProfile) are stored as string references
/// that can be resolved on restore. Undo/redo stacks are session-only and not persisted.
struct CurveEditSessionSnapshot: Codable {
    let id: UUID
    let createdAt: Date
    let sourceFileName: String
    let profileDirectoryName: String?
    let inkSet: InkSet
    let process: PrintProcess
    let steps: [CurveStep]
    let smoothingWindow: Int
    let gammaAdjust: Double
}

// MARK: - BlendWeights

/// Zone-based blend weights for curve blending (each 0-100).
struct BlendWeights: Equatable {
    var whites: Double = 100    // 0-100, how much of curve1 in whites zone
    var lights: Double = 100
    var midtones: Double = 100
    var darks: Double = 100
    var blacks: Double = 100
}

// MARK: - CurveUsageStats

/// Per-curve usage metadata, persisted via UserDefaults.
struct CurveUsageStats: Codable {
    var viewCount: Int = 0
    var editCount: Int = 0
    var lastViewed: Date?
    var lastEdited: Date?

    var totalInteractions: Int { viewCount + editCount }
}

/// Tracks curve usage across sessions. Keyed by filename (stable across re-parses).
@MainActor
class CurveUsageTracker: ObservableObject {
    private static let storageKey = "curveUsageStats"

    @Published private(set) var stats: [String: CurveUsageStats] = [:]

    init() { load() }

    func recordView(_ fileName: String) {
        var s = stats[fileName] ?? CurveUsageStats()
        s.viewCount += 1
        s.lastViewed = Date()
        stats[fileName] = s
        save()
    }

    func recordEdit(_ fileName: String) {
        var s = stats[fileName] ?? CurveUsageStats()
        s.editCount += 1
        s.lastEdited = Date()
        stats[fileName] = s
        save()
    }

    /// Recently used filenames, sorted by most recent interaction first.
    func recentlyUsed(limit: Int = 8) -> [String] {
        stats.sorted { a, b in
            let aDate = a.value.lastViewed ?? a.value.lastEdited ?? .distantPast
            let bDate = b.value.lastViewed ?? b.value.lastEdited ?? .distantPast
            return aDate > bDate
        }
        .prefix(limit)
        .map(\.key)
    }

    /// Most used filenames by total interaction count.
    func mostUsed(limit: Int = 8) -> [String] {
        stats.filter { $0.value.totalInteractions > 0 }
            .sorted { $0.value.totalInteractions > $1.value.totalInteractions }
            .prefix(limit)
            .map(\.key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: CurveUsageStats].self, from: data)
        else { return }
        stats = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - CurveProcessOverrideStore

/// Persists manual process overrides per curve filename in UserDefaults.
/// Keyed by filename (same stable key as CurveUsageTracker) so overrides survive re-parses.
@MainActor
class CurveProcessOverrideStore: ObservableObject {
    static let shared = CurveProcessOverrideStore()

    private static let storageKey = "curveProcessOverrides"

    /// Map of fileName → PrintProcess rawValue
    @Published private(set) var overrides: [String: String] = [:]

    init() { load() }

    /// Returns the manual process override for a given curve filename, if set.
    func override(for fileName: String) -> PrintProcess? {
        guard let rawValue = overrides[fileName] else { return nil }
        return PrintProcess(rawValue: rawValue)
    }

    /// Set a manual process override for a curve filename.
    func setOverride(_ process: PrintProcess, for fileName: String) {
        overrides[fileName] = process.rawValue
        save()
        objectWillChange.send()
    }

    /// Remove a manual override, reverting to automatic inference.
    func removeOverride(for fileName: String) {
        overrides.removeValue(forKey: fileName)
        save()
        objectWillChange.send()
    }

    /// Whether a given curve has a manual override set.
    func hasOverride(for fileName: String) -> Bool {
        overrides[fileName] != nil
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        overrides = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - OutputCurveType

/// Target linearization output curve type.
enum OutputCurveType: String, CaseIterable, Identifiable {
    case linearLabL = "Linear Lab L*"
    case linearDensity = "Linear Density"
    case linearInk = "Linear Ink"
    var id: String { rawValue }
}

// MARK: - L* ↔ Reflectance ↔ Density Conversions

/// Convert CIE L* to relative luminance (Y/Yn).
/// Uses the standard CIE formula: L* = 116 × f(Y/Yn) - 16.
func labLToReflectance(_ lStar: Double) -> Double {
    let fy = (lStar + 16.0) / 116.0
    let delta: Double = 6.0 / 29.0
    if fy > delta {
        return fy * fy * fy
    } else {
        return 3.0 * delta * delta * (fy - 4.0 / 29.0)
    }
}

/// Convert relative luminance (Y/Yn) to CIE L*.
func reflectanceToLabL(_ r: Double) -> Double {
    let delta: Double = 6.0 / 29.0
    let fy: Double
    if r > delta * delta * delta {
        fy = pow(r, 1.0 / 3.0)
    } else {
        fy = r / (3.0 * delta * delta) + 4.0 / 29.0
    }
    return 116.0 * fy - 16.0
}

/// Convert relative luminance to visual density: D = -log10(R).
func reflectanceToDensity(_ r: Double) -> Double {
    -log10(max(r, 1e-10))
}

/// Convert visual density to relative luminance: R = 10^(-D).
func densityToReflectance(_ d: Double) -> Double {
    pow(10.0, -d)
}

// MARK: - LinearizationConfig

/// Configuration for the linearization engine — smoothing, inversion, and output curve type.
struct LinearizationConfig {
    var mainSmoothing: Double = 25       // 0–100 continuous slider
    var inkSmoothing: Double = 20        // 0–100 for output ink curves (kept modest to preserve ink load)
    var invertCurve: Bool = false        // positive vs negative
    var outputCurveType: OutputCurveType = .linearLabL
    var gravureCorrection: Bool = false  // gravure/positive correction toggle
}

// MARK: - CurveLabViewModel

@MainActor
class CurveLabViewModel: ObservableObject {
    @Published var currentPage: PrintLabPage = .printLayout
    // Curve profile folder selection (auto-discovered from /Library/Printers/QTR/quadtone/)
    @Published var availableProfiles: [CurveProfileFolder] = CurveProfileFolder.discoverAll()
    @Published var selectedProfile: CurveProfileFolder? = CurveProfileFolder.discoverAll().first(where: { $0.directoryName == "QuadP800-DN" }) ?? CurveProfileFolder.discoverAll().first
    @Published var selectedQuadForViewing: QTRQuadFile?  // the currently loaded/viewed quad
    @Published var comparisonQuad: QTRQuadFile?            // overlay quad for Compare Curves

    // Real data from disk
    @Published var quadFiles: [QTRQuadFile] = []
    @Published var selectedQuadFileID: UUID? {
        didSet {
            if let id = selectedQuadFileID,
               let quad = quadFiles.first(where: { $0.id == id }) {
                usageTracker.recordView(quad.fileName)
            }
        }
    }
    @Published var measurements: [SpyderPRINTMeasurement] = []
    @Published var selectedMeasurementID: UUID?

    // Usage tracking
    let usageTracker = CurveUsageTracker()
    let processOverrideStore = CurveProcessOverrideStore.shared

    /// Activity event service — set by the host view via environment injection.
    var activityEventService: ActivityEventService?

    // Linearization state
    @Published var linearizeSourceQuad: QTRQuadFile?
    @Published var linearizeMeasurement: SpyderPRINTMeasurement?
    @Published var linearizeOriginalMeasurement: SpyderPRINTMeasurement?  // for revert
    @Published var linearizeConfig: LinearizationConfig = LinearizationConfig()
    @Published var linearizedQuad: QTRQuadFile?          // the output
    @Published var linearizeNotes: String = ""
    @Published var showOriginalCurves: Bool = false

    // Blend page state
    @Published var blendCurve1: QTRQuadFile?
    @Published var blendCurve2: QTRQuadFile?
    @Published var blendWeights: BlendWeights = BlendWeights()
    @Published var blendWeights2: BlendWeights = BlendWeights()  // Independent curve 2 weights
    @Published var linkedSliders: Bool = true                     // When true, curve2 = 100 - curve1
    @Published var blendedResult: QTRQuadFile?

    // Channel remap state
    @Published var remapSourceQuad: QTRQuadFile?
    @Published var remapChannelMap: [String: String] = [:]  // source channel name -> target channel name
    @Published var remappedQuad: QTRQuadFile?

    // Curve builder state
    @Published var builderTargetImage: NSImage?  // scanned target
    @Published var builderSteps: [CurveStep] = []
    @Published var smoothingWindow: Int = 5

    // Split-tone preview
    @Published var curve1: QTRCurve?
    @Published var curve2: QTRCurve?
    @Published var curve3: QTRCurve?
    @Published var splitTone: SplitToneConfig = SplitToneConfig()
    @Published var previewImage: NSImage?

    // Chat
    @Published var chatMessages: [CurveLabChatMessage] = []
    @Published var chatInput: String = ""
    @Published var chatLoading: Bool = false

    // Process explorer
    @Published var selectedProcess: PrintProcess = .platinumPd
    @Published var selectedInkSet: InkSet = .piezography

    // Sub-page navigation within Curves
    @Published var curvesSubPage: CurvesSubPage = .gallery
    @Published var showCreatorWizard: Bool = false
    @Published var showUnsavedChangesAlert: Bool = false
    var pendingSubPageNavigation: CurvesSubPage?

    // Edit session
    @Published var editSession: CurveEditSession?

    // Loading state
    @Published var isLoadingFiles: Bool = false
    @Published var loadFilesError: String? = nil

    var selectedQuadFile: QTRQuadFile? {
        quadFiles.first(where: { $0.id == selectedQuadFileID })
    }

    var selectedMeasurement: SpyderPRINTMeasurement? {
        measurements.first(where: { $0.id == selectedMeasurementID })
    }

    // MARK: - Sub-page Navigation

    /// Navigate to a curves sub-page, prompting to save if there's an active dirty session.
    func navigateToCurvesSubPage(_ page: CurvesSubPage) {
        if let session = editSession, session.isDirty, page != .creator {
            pendingSubPageNavigation = page
            showUnsavedChangesAlert = true
        } else {
            curvesSubPage = page
            if page == .creator {
                showCreatorWizard = true
            }
        }
    }

    /// Discard the current edit session and navigate to the pending page.
    func discardSessionAndNavigate() {
        editSession = nil
        if let pending = pendingSubPageNavigation {
            curvesSubPage = pending
            pendingSubPageNavigation = nil
        }
    }

    /// Save the current session, then navigate to the pending page.
    func saveSessionAndNavigate() {
        saveSessionToDisk()
        editSession?.isDirty = false
        if let pending = pendingSubPageNavigation {
            curvesSubPage = pending
            pendingSubPageNavigation = nil
        }
    }

    /// Start a new edit session from the creator wizard.
    /// Loads the first real .quad file from the selected profile as the starting curve,
    /// or generates a realistic base curve shape if none available.
    func startNewEditSession(profile: CurveProfileFolder?, inkSet: InkSet, process: PrintProcess) {
        selectedProfile = profile
        selectedInkSet = inkSet
        selectedProcess = process
        showCreatorWizard = false
        curvesSubPage = .creator

        // Reload files for the selected profile
        loadFilesFromDisk()

        // Try to load the first real quad file as the base curve
        if let profile = profile {
            let quadPath = profile.quadDirectoryPath
            let urls = QTRFileParser.scanQuadDirectory(at: quadPath)
            if let firstURL = urls.first, let quad = try? QTRFileParser.parseQuadFile(at: firstURL) {
                selectedQuadForViewing = quad
                let steps = quad.channels.first?.normalizedCurve.map { pt in
                    CurveStep(input: pt.input, output: pt.output)
                } ?? Self.generateDefaultCurveSteps()
                builderSteps = steps
                editSession = CurveEditSession(
                    sourceQuadFile: quad,
                    sourceFileName: editSession?.sourceFileName ?? quad.fileName,
                    printerProfile: profile,
                    inkSet: inkSet,
                    process: process,
                    steps: steps
                )
                return
            }
        }

        // Fallback: generate a realistic base curve (power curve ~x^1.4)
        let defaultSteps = Self.generateDefaultCurveSteps()
        builderSteps = defaultSteps
        editSession = CurveEditSession(
            printerProfile: profile,
            inkSet: inkSet,
            process: process,
            steps: defaultSteps
        )
    }

    /// Generate a realistic default K-channel curve shape.
    /// Based on real QTR .quad files: paper-white preservation at low inputs,
    /// power-curve ramp (x^1.4), slight shoulder compression at max density.
    static func generateDefaultCurveSteps() -> [CurveStep] {
        (0..<256).map { i in
            let x = Double(i) / 255.0
            let output: Double
            if x < 0.02 {
                // Paper white preservation: first ~5 steps stay near zero
                output = 0
            } else {
                // Power curve with slight shoulder
                let normalized = (x - 0.02) / 0.98
                let power = pow(normalized, 1.4)
                // Soft shoulder at top end (compress last 10%)
                let shoulder = x > 0.9 ? 1.0 - (1.0 - power) * 0.7 : power
                output = min(1.0, shoulder * 0.95) // typical max ~95% ink limit
            }
            return CurveStep(input: x, output: output)
        }
    }

    /// Open an existing quad file for editing.
    func openQuadForEditing(_ quad: QTRQuadFile) {
        usageTracker.recordEdit(quad.fileName)
        let steps = quad.channels.first?.normalizedCurve.map { pt in
            CurveStep(input: pt.input, output: pt.output)
        } ?? []
        editSession = CurveEditSession(
            sourceQuadFile: quad,
            sourceFileName: quad.fileName,
            printerProfile: selectedProfile,
            inkSet: selectedInkSet,
            process: selectedProcess,
            steps: steps
        )
        selectedQuadForViewing = quad
        curvesSubPage = .creator
    }

    /// Load real .quad files from the QTR directory and measurement exports from SpyderPRINT.
    func loadFilesFromDisk() {
        isLoadingFiles = true
        loadFilesError = nil
        // Reset so a retry re-scans from scratch
        quadFiles = []
        measurements = []
        selectedQuadForViewing = nil

        let quadPath = selectedProfile?.quadDirectoryPath ?? "/Library/Printers/QTR/quadtone/QuadP800-DN"

        Task.detached(priority: .userInitiated) {
            do {
                let quadURLs = QTRFileParser.scanQuadDirectory(at: quadPath)
                let measURLs = QTRFileParser.scanMeasurementDirectory()

                var parsedQuads: [QTRQuadFile] = []
                for url in quadURLs {
                    if let quad = try? QTRFileParser.parseQuadFile(at: url) {
                        parsedQuads.append(quad)
                    }
                }

                var parsedMeas: [SpyderPRINTMeasurement] = []
                for url in measURLs {
                    if let meas = try? QTRFileParser.parseMeasurement(at: url) {
                        parsedMeas.append(meas)
                    }
                }

                await MainActor.run {
                    self.quadFiles = parsedQuads
                    self.measurements = parsedMeas
                    self.isLoadingFiles = false
                    self.restoreSessionFromDisk()
                }
            } catch {
                await MainActor.run {
                    self.isLoadingFiles = false
                    self.loadFilesError = "Failed to load curves: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Session Persistence

    private static let sessionStorageKey = "curveLabEditSession"

    /// Persist the current edit session to UserDefaults as a JSON snapshot.
    func saveSessionToDisk() {
        guard let session = editSession else { return }
        let snapshot = CurveEditSessionSnapshot(
            id: session.id,
            createdAt: session.createdAt,
            sourceFileName: session.sourceFileName,
            profileDirectoryName: session.printerProfile?.directoryName,
            inkSet: session.inkSet,
            process: session.process,
            steps: session.steps,
            smoothingWindow: session.smoothingWindow,
            gammaAdjust: session.gammaAdjust
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionStorageKey)
    }

    /// Restore a previously saved edit session from UserDefaults.
    /// Resolves the printer profile by directory name and the source quad by filename.
    /// Clears the stored session after restoring so it only restores once.
    func restoreSessionFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionStorageKey),
              let snapshot = try? JSONDecoder().decode(CurveEditSessionSnapshot.self, from: data)
        else { return }

        // Clear storage immediately to prevent double-restore
        UserDefaults.standard.removeObject(forKey: Self.sessionStorageKey)

        // Resolve the printer profile by directory name
        let profile: CurveProfileFolder? = if let dirName = snapshot.profileDirectoryName {
            availableProfiles.first(where: { $0.directoryName == dirName })
        } else {
            nil
        }

        // Resolve the source quad file by filename
        let sourceQuad = quadFiles.first(where: { $0.fileName == snapshot.sourceFileName })

        var session = CurveEditSession(
            sourceQuadFile: sourceQuad,
            sourceFileName: snapshot.sourceFileName,
            printerProfile: profile,
            inkSet: snapshot.inkSet,
            process: snapshot.process,
            steps: snapshot.steps
        )
        session.smoothingWindow = snapshot.smoothingWindow
        session.gammaAdjust = snapshot.gammaAdjust

        editSession = session
        builderSteps = snapshot.steps
        selectedProfile = profile
        selectedInkSet = snapshot.inkSet
        selectedProcess = snapshot.process
        if let sourceQuad { selectedQuadForViewing = sourceQuad }
        curvesSubPage = .creator
    }

    // MARK: - Curve Blending

    /// Blend two quad files using zone-based weights with smooth interpolation.
    func computeBlend() {
        guard let c1 = blendCurve1, let c2 = blendCurve2 else {
            blendedResult = nil
            return
        }
        // Zone center positions (0-255) and their weights
        let zoneCenters: [Double] = [25.5, 76.5, 127.5, 178.5, 229.5]
        let zoneWeights: [Double]
        if linkedSliders {
            // Linked mode: curve1 weight = slider/100, curve2 = 1 - curve1
            zoneWeights = [
                blendWeights.whites / 100.0,
                blendWeights.lights / 100.0,
                blendWeights.midtones / 100.0,
                blendWeights.darks / 100.0,
                blendWeights.blacks / 100.0
            ]
        } else {
            // Independent mode: normalize w1/(w1+w2) per zone
            let pairs: [(Double, Double)] = [
                (blendWeights.whites, blendWeights2.whites),
                (blendWeights.lights, blendWeights2.lights),
                (blendWeights.midtones, blendWeights2.midtones),
                (blendWeights.darks, blendWeights2.darks),
                (blendWeights.blacks, blendWeights2.blacks)
            ]
            zoneWeights = pairs.map { w1, w2 in
                let sum = w1 + w2
                return sum > 0 ? w1 / sum : 0.5
            }
        }

        // Blend each channel using smoothly interpolated zone weights
        var blendedChannels: [InkChannel] = []
        for i in 0..<min(c1.channels.count, c2.channels.count) {
            let ch1 = c1.channels[i]
            let ch2 = c2.channels[i]
            var values: [UInt16] = []
            for j in 0..<256 {
                let pos = Double(j)
                let weight = interpolatedWeight(at: pos, centers: zoneCenters, weights: zoneWeights)
                let v1 = Double(ch1.values[j])
                let v2 = Double(ch2.values[j])
                let blended = v1 * weight + v2 * (1.0 - weight)
                values.append(UInt16(min(65535, max(0, blended))))
            }
            blendedChannels.append(InkChannel(name: ch1.name, values: values))
        }
        blendedResult = QTRQuadFile(
            fileName: "Blended.quad",
            comments: ["## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK",
                       "# Blended from \(c1.fileName) and \(c2.fileName)"],
            channels: blendedChannels
        )

        // Emit activity event
        let capturedService = activityEventService
        let name1 = c1.fileName
        let name2 = c2.fileName
        Task {
            try? await capturedService?.emitCurveBlended(
                curve1: name1, curve2: name2, outputName: "Blended.quad"
            )
        }
    }

    /// Smoothly interpolate blend weight at a given position using zone centers.
    /// Uses cosine interpolation between adjacent zone centers for smooth transitions.
    private func interpolatedWeight(at pos: Double, centers: [Double], weights: [Double]) -> Double {
        // Before first center: use first weight
        if pos <= centers[0] { return weights[0] }
        // After last center: use last weight
        if pos >= centers[centers.count - 1] { return weights[centers.count - 1] }

        // Find which two centers we're between
        for i in 0..<(centers.count - 1) {
            if pos >= centers[i] && pos <= centers[i + 1] {
                let t = (pos - centers[i]) / (centers[i + 1] - centers[i])
                // Cosine interpolation for smooth S-curve transition
                let smooth = (1.0 - cos(t * .pi)) / 2.0
                return weights[i] * (1.0 - smooth) + weights[i + 1] * smooth
            }
        }
        return weights[centers.count - 1]
    }

    // MARK: - Linearization Engine

    /// Core linearization: takes source quad + measurement and produces a linearized quad.
    ///
    /// Algorithm:
    /// 1. Extract L* values from measurement steps
    /// 2. Build a correction LUT mapping each input level to the level that produces ideal linear L*
    /// 3. Smooth the LUT with Savitzky-Golay quadratic filter (window from mainSmoothing)
    /// 4. Remap each channel of the source quad through the correction LUT
    /// 5. Smooth the output ink channels with Savitzky-Golay (window from inkSmoothing)
    /// 6. Optionally invert for negative/positive workflows
    func linearize() {
        guard let sourceQuad = linearizeSourceQuad,
              let measurement = linearizeMeasurement,
              measurement.steps.count >= 2 else { return }

        let config = linearizeConfig
        let measSteps = filterOutlierPatches(measurement.steps)

        // 1. Extract L* values — assume steps are ordered from paper white (high L*) to Dmax (low L*)
        let paperWhiteL = measSteps.first!.labL
        let dMaxL = measSteps.last!.labL
        let lRange = paperWhiteL - dMaxL
        guard lRange > 0 else { return }

        // Build measured L* lookup: for each of 256 input levels, interpolate the measured L*
        let stepCount = measSteps.count
        var measuredL = [Double](repeating: 0, count: 256)
        for i in 0..<256 {
            let t = Double(i) / 255.0  // 0 = paper white, 1 = max density
            let fractionalIndex = t * Double(stepCount - 1)
            let lo = Int(fractionalIndex)
            let hi = min(lo + 1, stepCount - 1)
            let frac = fractionalIndex - Double(lo)
            measuredL[i] = measSteps[lo].labL * (1.0 - frac) + measSteps[hi].labL * frac
        }

        // Helper: interpolate measuredL at fractional index (continuous lookup)
        func interpMeasuredL(_ x: Double) -> Double {
            let clamped = max(0.0, min(255.0, x))
            let lo = Int(clamped)
            let hi = min(lo + 1, 255)
            let frac = clamped - Double(lo)
            return measuredL[lo] * (1.0 - frac) + measuredL[hi] * frac
        }

        // Helper: numerical derivative dL*/dx of the measured response at position x
        func measuredLDerivative(_ x: Double) -> Double {
            let h = 0.5  // half-step for central difference
            let xPlus = min(255.0, x + h)
            let xMinus = max(0.0, x - h)
            let dx = xPlus - xMinus
            guard dx > 0 else { return -1.0 }  // fallback: assume decreasing
            return (interpMeasuredL(xPlus) - interpMeasuredL(xMinus)) / dx
        }

        // 2. Build initial correction LUT via closest-match search (basic L* compensation)
        // This serves as the starting point for Newton-Raphson refinement.
        var correctionLUT = [Double](repeating: 0, count: 256)
        for i in 0..<256 {
            let t = Double(i) / 255.0

            let idealL: Double
            switch config.outputCurveType {
            case .linearLabL:
                // Linear L*: straight line from paper white to Dmax
                idealL = paperWhiteL - t * lRange
            case .linearDensity:
                // Linear density: equal density steps from paper white to Dmax.
                // Convert L* endpoints to reflectance, then density, interpolate in
                // density space, and convert back to L* for the lookup.
                let rPaper = labLToReflectance(paperWhiteL)
                let rDmax  = labLToReflectance(dMaxL)
                let dPaper = reflectanceToDensity(rPaper)
                let dDmax  = reflectanceToDensity(rDmax)
                let targetD = dPaper + t * (dDmax - dPaper)
                let targetR = densityToReflectance(targetD)
                idealL = reflectanceToLabL(targetR)
            case .linearInk:
                // Linear ink: identity mapping (no L* correction, just pass through)
                idealL = measuredL[i]
            }

            // Binary search for the measured input level closest to idealL
            // measuredL goes from high (paper white) to low (Dmax)
            var bestIdx = i
            var bestDist = Double.infinity
            for j in 0..<256 {
                let dist = abs(measuredL[j] - idealL)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = j
                }
            }
            correctionLUT[i] = Double(bestIdx)
        }

        // 3. Newton-Raphson iterative refinement
        // Refines each LUT entry so that measuredL(correctionLUT[i]) converges to idealL[i].
        // This handles steep gradients and non-monotonic regions much better than the
        // simple closest-match search above.
        let maxIterations = 12
        let convergenceThreshold = 0.05  // L* units — below this we stop iterating
        let dampingFactor = 0.8          // under-relax to prevent oscillation

        // Skip Newton-Raphson for linearInk mode (identity mapping, no correction needed)
        if config.outputCurveType != .linearInk {
            // Precompute ideal L* targets for all 256 levels
            var idealLTargets = [Double](repeating: 0, count: 256)
            for i in 0..<256 {
                let t = Double(i) / 255.0
                switch config.outputCurveType {
                case .linearLabL:
                    idealLTargets[i] = paperWhiteL - t * lRange
                case .linearDensity:
                    let rPaper = labLToReflectance(paperWhiteL)
                    let rDmax  = labLToReflectance(dMaxL)
                    let dPaper = reflectanceToDensity(rPaper)
                    let dDmax  = reflectanceToDensity(rDmax)
                    let targetD = dPaper + t * (dDmax - dPaper)
                    let targetR = densityToReflectance(targetD)
                    idealLTargets[i] = reflectanceToLabL(targetR)
                case .linearInk:
                    idealLTargets[i] = measuredL[i]  // unreachable due to guard above
                }
            }

            for _ in 0..<maxIterations {
                var maxError = 0.0

                for i in 0..<256 {
                    let currentX = correctionLUT[i]
                    let currentL = interpMeasuredL(currentX)
                    let error = currentL - idealLTargets[i]

                    maxError = max(maxError, abs(error))

                    // Compute derivative dL*/dx at the current position
                    let derivative = measuredLDerivative(currentX)

                    // Guard against zero/tiny derivatives (flat zones in the measured curve)
                    // — fall back to no adjustment rather than exploding
                    guard abs(derivative) > 1e-6 else { continue }

                    // Newton step: x_new = x_old - f(x)/f'(x)
                    // where f(x) = measuredL(x) - idealL, f'(x) = dL*/dx
                    var step = dampingFactor * error / derivative
                    // Clamp step magnitude to prevent oscillation from small derivatives
                    let maxStepSize = 20.0
                    step = max(-maxStepSize, min(maxStepSize, step))
                    let newX = currentX - step

                    // Clamp to valid range
                    correctionLUT[i] = max(0.0, min(255.0, newX))
                }

                // Early exit if all entries have converged
                if maxError < convergenceThreshold { break }
            }
        }

        // Convert fractional LUT to integer, enforcing monotonicity
        var intLUT = correctionLUT.map { Int(max(0, min(255, $0.rounded()))) }
        for i in 1..<256 {
            if intLUT[i] < intLUT[i - 1] {
                intLUT[i] = intLUT[i - 1]
            }
        }

        // 4. Smooth the correction LUT with mainSmoothing (Savitzky-Golay quadratic)
        // Slider 0-100 maps to window 5-51 (odd). S-G preserves curve shape better
        // than moving average, so the same slider range gives cleaner results.
        let mainWindow = max(5, Int((config.mainSmoothing / 100.0 * 23.0).rounded()) * 2 + 5)
        let smoothedLUT = smoothArray(intLUT.map { Double($0) }, windowSize: mainWindow)
            .map { Int(max(0, min(255, $0.rounded()))) }

        // 5. Apply correction to each channel: remap channel values through the LUT
        var linearizedChannels: [InkChannel] = []
        for channel in sourceQuad.channels {
            var newValues = [UInt16](repeating: 0, count: 256)
            for i in 0..<256 {
                let mappedIdx = smoothedLUT[i]
                newValues[i] = channel.values[mappedIdx]
            }

            // 6. Apply inkSmoothing to the output channel values
            // Savitzky-Golay window: slider 0-100 maps to 5-51 (odd)
            let inkWindow = max(5, Int((config.inkSmoothing / 100.0 * 23.0).rounded()) * 2 + 5)
            let smoothedValues = smoothArray(newValues.map { Double($0) }, windowSize: inkWindow)
                .map { UInt16(max(0, min(65535, $0.rounded()))) }

            // 6b. Enforce monotonicity on smoothed ink channels (S-G can introduce ringing)
            let monotonicValues: [UInt16]
            let lightInkChannels: Set<String> = ["LK", "LM", "LLK"]
            if lightInkChannels.contains(channel.name) {
                // Light inks have a peak-then-decrease shape — enforce unimodal peak
                monotonicValues = enforceUnimodalPeak(smoothedValues)
            } else {
                // Primary channels are non-decreasing
                monotonicValues = enforceNonDecreasing(smoothedValues)
            }

            // 7. Invert if needed (for negative workflows)
            let finalValues: [UInt16]
            if config.invertCurve {
                finalValues = monotonicValues.map { 65535 - $0 }
            } else if config.gravureCorrection {
                // Gravure correction: flip the curve for positive printing processes
                finalValues = monotonicValues.reversed()
            } else {
                finalValues = monotonicValues
            }

            linearizedChannels.append(InkChannel(name: channel.name, values: finalValues))
        }

        // 8. Build the output quad
        var outputComments = sourceQuad.comments
        outputComments.append("# Linearized from measurement file: \(measurement.fileName)")
        outputComments.append("# and input quad file: \(sourceQuad.fileName)")
        outputComments.append("# Linearization config: mainSmoothing=\(config.mainSmoothing), inkSmoothing=\(config.inkSmoothing), type=\(config.outputCurveType.rawValue), method=Newton-Raphson")

        linearizedQuad = QTRQuadFile(
            fileName: linearizedFileName(for: sourceQuad),
            comments: outputComments,
            channels: linearizedChannels,
            linearizationHistory: sourceQuad.linearizationHistory + [
                LinearizationEntry(measurementFile: measurement.fileName, inputQuadFile: sourceQuad.fileName)
            ]
        )

        // 9. Auto-populate notes
        if linearizeNotes.isEmpty {
            linearizeNotes = "Linearized \(sourceQuad.fileName) with \(measurement.fileName) (\(config.outputCurveType.rawValue), Newton-Raphson, smoothing \(Int(config.mainSmoothing))/\(Int(config.inkSmoothing)))"
        }

        // 10. Emit activity event
        let capturedService = activityEventService
        let outputName = linearizedFileName(for: sourceQuad)
        let inputName = sourceQuad.fileName
        let measName = measurement.fileName
        let smoothing = config.mainSmoothing
        Task {
            try? await capturedService?.emitCurveLinearized(
                inputQuad: inputName, measurementFile: measName,
                outputQuad: outputName, smoothing: smoothing
            )
        }
    }

    // MARK: - Outlier Filtering

    /// Filter outlier patches from measurement data before linearization.
    /// Detects L* reversals and a*/b* spikes, replaces them with interpolated values.
    private func filterOutlierPatches(_ steps: [LabStep]) -> [LabStep] {
        guard steps.count >= 3 else { return steps }

        var filtered = steps
        var outlierIndices: Set<Int> = []

        // Pass 1: detect outliers
        for i in 1..<(steps.count - 1) {
            let prev = steps[i - 1]
            let curr = steps[i]
            let next = steps[i + 1]
            let neighborAvgL = (prev.labL + next.labL) / 2.0
            let neighborAvgA = (prev.labA + next.labA) / 2.0
            let neighborAvgB = (prev.labB + next.labB) / 2.0

            // L* reversal > 1.0 from expected monotonic decrease
            if curr.labL > prev.labL + 1.0 {
                outlierIndices.insert(i)
            }
            // a* deviation > 5.0 from neighbor average
            if abs(curr.labA - neighborAvgA) > 5.0 {
                outlierIndices.insert(i)
            }
            // b* deviation > 8.0 from neighbor average
            if abs(curr.labB - neighborAvgB) > 8.0 {
                outlierIndices.insert(i)
            }
            // L* deviates > 3.0 from neighbor average (general outlier)
            if abs(curr.labL - neighborAvgL) > 3.0 {
                outlierIndices.insert(i)
            }
        }

        // Pass 2: interpolate over outliers from nearest valid neighbors
        for i in outlierIndices.sorted() {
            var prevValid = i - 1
            while prevValid >= 0 && outlierIndices.contains(prevValid) { prevValid -= 1 }
            var nextValid = i + 1
            while nextValid < steps.count && outlierIndices.contains(nextValid) { nextValid += 1 }

            guard prevValid >= 0, nextValid < steps.count else { continue }

            let span = Double(nextValid - prevValid)
            let t = Double(i - prevValid) / span
            let interpL = steps[prevValid].labL * (1.0 - t) + steps[nextValid].labL * t
            let interpA = steps[prevValid].labA * (1.0 - t) + steps[nextValid].labA * t
            let interpB = steps[prevValid].labB * (1.0 - t) + steps[nextValid].labB * t

            filtered[i] = LabStep(
                stepNumber: steps[i].stepNumber,
                labL: interpL, labA: interpA, labB: interpB
            )
        }

        if !outlierIndices.isEmpty {
            print("[CurveLab] Filtered \(outlierIndices.count) outlier patches at indices: \(outlierIndices.sorted())")
        }

        return filtered
    }

    // MARK: - Monotonicity Helpers

    /// Enforce non-decreasing values (for primary ink channels).
    private func enforceNonDecreasing(_ values: [UInt16]) -> [UInt16] {
        var result = values
        for i in 1..<result.count {
            if result[i] < result[i - 1] {
                result[i] = result[i - 1]
            }
        }
        return result
    }

    /// Enforce unimodal peak shape (for light ink channels LK/LM/LLK).
    /// Finds the peak, enforces non-decreasing before it and non-increasing after.
    private func enforceUnimodalPeak(_ values: [UInt16]) -> [UInt16] {
        guard values.count >= 2 else { return values }
        // If channel is inactive (all zeros or all same value), skip
        let maxVal = values.max() ?? 0
        guard maxVal > 0 else { return values }

        guard let peakIdx = values.indices.max(by: { values[$0] < values[$1] }) else { return values }
        var result = values
        // Non-decreasing up to peak
        if peakIdx > 0 {
            for i in 1...peakIdx {
                if result[i] < result[i - 1] {
                    result[i] = result[i - 1]
                }
            }
        }
        // Non-increasing after peak
        if peakIdx < values.count - 1 {
            for i in stride(from: values.count - 2, through: peakIdx, by: -1) {
                if result[i] < result[i + 1] {
                    result[i] = result[i + 1]
                }
            }
        }
        return result
    }

    /// Sort current measurement steps by L* descending (paper white first).
    func sortMeasurement() {
        guard let measurement = linearizeMeasurement else { return }
        if linearizeOriginalMeasurement == nil {
            linearizeOriginalMeasurement = measurement
        }
        let sorted = measurement.steps.sorted { $0.labL > $1.labL }
        let renumbered = sorted.enumerated().map { i, step in
            LabStep(stepNumber: i + 1, labL: step.labL, labA: step.labA, labB: step.labB)
        }
        linearizeMeasurement = SpyderPRINTMeasurement(
            id: measurement.id,
            fileName: measurement.fileName,
            hasHeader: measurement.hasHeader,
            steps: renumbered
        )
    }

    /// Reverse the measurement step order (pivot).
    func pivotMeasurement() {
        guard let measurement = linearizeMeasurement else { return }
        if linearizeOriginalMeasurement == nil {
            linearizeOriginalMeasurement = measurement
        }
        let reversed = measurement.steps.reversed()
        let renumbered = reversed.enumerated().map { i, step in
            LabStep(stepNumber: i + 1, labL: step.labL, labA: step.labA, labB: step.labB)
        }
        linearizeMeasurement = SpyderPRINTMeasurement(
            id: measurement.id,
            fileName: measurement.fileName,
            hasHeader: measurement.hasHeader,
            steps: renumbered
        )
    }

    /// Restore original measurement order from saved copy.
    func revertMeasurement() {
        guard let original = linearizeOriginalMeasurement else { return }
        linearizeMeasurement = original
    }

    /// Install the linearized quad to the selected profile's QTR directory.
    func autoInstallLinearizedQuad() {
        guard let quad = linearizedQuad,
              let profile = selectedProfile else { return }

        let destDir = URL(fileURLWithPath: profile.quadDirectoryPath)
        let destURL = destDir.appendingPathComponent(quad.fileName)

        // Serialize the quad file
        let content = QTRFileParser.serializeQuadFile(quad)

        do {
            try content.write(to: destURL, atomically: true, encoding: .utf8)
            loadFilesFromDisk()
            // Emit activity event
            let capturedService = activityEventService
            let fileName = quad.fileName
            let profileName = profile.displayName
            Task { try? await capturedService?.emitCurveSaved(fileName: fileName, profileName: profileName) }
        } catch {
            loadFilesError = "Failed to install linearized quad: \(error.localizedDescription)"
        }
    }

    /// Use NSOpenPanel to let user browse for a .quad file, parse it, set as linearizeSourceQuad.
    func openAdHocQuadFile() {
        let panel = NSOpenPanel()
        panel.title = "Select a .quad file"
        panel.allowedContentTypes = [.init(filenameExtension: "quad")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let quad = try QTRFileParser.parseQuadFile(at: url)
            linearizeSourceQuad = quad
        } catch {
            loadFilesError = "Failed to parse quad file: \(error.localizedDescription)"
        }
    }

    /// Use NSOpenPanel to let user browse for a measurement .txt file, parse it, set as linearizeMeasurement.
    func openAdHocMeasurementFile() {
        let panel = NSOpenPanel()
        panel.title = "Select a measurement file"
        panel.allowedContentTypes = [.init(filenameExtension: "txt")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let measurement = try QTRFileParser.parseMeasurement(at: url)
            linearizeMeasurement = measurement
            linearizeOriginalMeasurement = measurement
        } catch {
            loadFilesError = "Failed to parse measurement file: \(error.localizedDescription)"
        }
    }

    // MARK: - Linearization Helpers

    /// Generate a linearized filename with "-linvN" suffix.
    private func linearizedFileName(for sourceQuad: QTRQuadFile) -> String {
        let baseName = sourceQuad.fileName.replacingOccurrences(of: ".quad", with: "")
        // Count existing linearization versions from the source's history
        let existingCount = sourceQuad.linearizationHistory.count
        let version = existingCount + 1
        return "\(baseName)-linv\(version).quad"
    }

    /// Apply Savitzky-Golay quadratic smoothing to an array of Doubles.
    /// Delegates to the shared SavitzkyGolay filter which preserves curve shape
    /// better than simple moving average while still removing noise.
    private func smoothArray(_ values: [Double], windowSize: Int) -> [Double] {
        guard values.count > windowSize, windowSize >= 5 else { return values }
        return SavitzkyGolay.smooth(values, windowSize: windowSize)
    }

    // MARK: - Channel Remap

    /// Compute the remapped quad by reassigning channels according to remapChannelMap.
    /// For each target channel position, find the source channel whose data should fill it.
    func computeRemap() {
        guard let source = remapSourceQuad else {
            remappedQuad = nil
            return
        }
        let standardNames = QTRFileParser.standardChannelNames
        let sourceByName = Dictionary(uniqueKeysWithValues: source.channels.map { ($0.name, $0) })

        var remappedChannels: [InkChannel] = []
        for targetName in standardNames {
            let sourceName = remapChannelMap[targetName] ?? targetName
            if let sourceChannel = sourceByName[sourceName] {
                remappedChannels.append(InkChannel(name: targetName, values: sourceChannel.values))
            } else {
                remappedChannels.append(InkChannel(name: targetName, values: Array(repeating: 0, count: 256)))
            }
        }

        let baseName = source.fileName.replacingOccurrences(of: ".quad", with: "")
        remappedQuad = QTRQuadFile(
            fileName: "\(baseName)-remap.quad",
            comments: ["## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK",
                       "# Remapped from \(source.fileName)",
                       "# Generated by HoehnPhotos CurveLab"],
            channels: remappedChannels
        )
    }

    /// Reset channel map to identity (each channel maps to itself).
    func resetChannelMap() {
        let standardNames = QTRFileParser.standardChannelNames
        var identity: [String: String] = [:]
        for name in standardNames {
            identity[name] = name
        }
        remapChannelMap = identity
        computeRemap()
    }

    /// Save remapped quad to the selected profile's QTR directory.
    func saveRemappedQuad() {
        guard let quad = remappedQuad, let profile = selectedProfile else { return }
        let content = QTRFileParser.serializeQuadFile(quad)
        do {
            try QTRFileParser.installQuadFile(quad, content: content, destination: profile)
            loadFilesFromDisk()
            // Emit activity event
            let capturedService = activityEventService
            let fileName = quad.fileName
            let profileName = profile.displayName
            Task { try? await capturedService?.emitCurveSaved(fileName: fileName, profileName: profileName) }
        } catch {
            loadFilesError = "Failed to save remapped quad: \(error.localizedDescription)"
        }
    }

}

// MARK: - CurveLabChatMessage

struct CurveLabChatMessage: Identifiable {
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    enum Role: String { case user, assistant, system }

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
