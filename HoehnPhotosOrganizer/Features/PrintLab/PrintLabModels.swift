import SwiftUI
import AppKit
import CoreImage
import CoreGraphics
import Combine

// MARK: - CurveAdjustment

struct CurveAdjustment: Equatable, Codable {
    var brightnessOffset: Double  // e.g. +0.10 = +10%
    var saturationOffset: Double  // e.g. +0.05 = +5%
    static let identity = CurveAdjustment(brightnessOffset: 0, saturationOffset: 0)
}

// MARK: - CanvasImage

struct CanvasImage: Identifiable {
    let id: UUID
    var photoAsset: PhotoAsset?       // nil = dropped from Finder
    var sourceImage: NSImage
    var position: CGPoint             // inches from paper top-left
    var size: CGSize                  // inches
    var rotation: Double              // degrees
    var aspectRatioLocked: Bool
    var iccProfileURL: URL?           // nil = use global ICC setting
    var curveAdjustment: CurveAdjustment?
    var tileLabel: String?            // shown on canvas for calibration strip tiles
    var dragOffset: CGSize            // transient drag state, not persisted
    var groupID: UUID?                // shared UUID for template-generated tile groups
    var groupLabel: String?           // display name for the group row
    var borderWidthInches: CGFloat    // border width in inches, added outside image (expands total output size)
    var borderIsWhite: Bool           // false = black border (default for contact prints), true = white

    init(photoAsset: PhotoAsset? = nil,
         sourceImage: NSImage,
         position: CGPoint = .zero,
         size: CGSize = CGSize(width: 9, height: 12),
         rotation: Double = 0,
         aspectRatioLocked: Bool = true,
         iccProfileURL: URL? = nil,
         curveAdjustment: CurveAdjustment? = nil,
         tileLabel: String? = nil,
         groupID: UUID? = nil,
         groupLabel: String? = nil,
         borderWidthInches: CGFloat = 0,
         borderIsWhite: Bool = false) {
        self.id = UUID()
        self.photoAsset = photoAsset
        self.sourceImage = sourceImage
        self.position = position
        self.size = size
        self.rotation = rotation
        self.aspectRatioLocked = aspectRatioLocked
        self.iccProfileURL = iccProfileURL
        self.curveAdjustment = curveAdjustment
        self.tileLabel = tileLabel
        self.dragOffset = .zero
        self.groupID = groupID
        self.groupLabel = groupLabel
        self.borderWidthInches = borderWidthInches
        self.borderIsWhite = borderIsWhite
    }
}

// MARK: - PrintTemplate

enum PrintTemplate: Identifiable, Codable {
    case calibrationStrip(columns: Int, rows: Int, brightnessRange: Double, saturationRange: Double)
    case digitalNegative
    case eightUpProof
    case softProof
    case stepWedge(steps: Int)
    case flushTarget
    case custom(name: String)

    var id: String {
        switch self {
        case .calibrationStrip(let c, let r, _, _): return "calibration_\(c)x\(r)"
        case .digitalNegative:  return "digital_negative"
        case .eightUpProof:     return "eight_up_proof"
        case .softProof:        return "soft_proof"
        case .stepWedge(let s): return "step_wedge_\(s)"
        case .flushTarget:      return "flush_target"
        case .custom(let n):    return "custom_\(n)"
        }
    }

    var displayName: String {
        switch self {
        case .calibrationStrip(let c, let r, _, _): return "Calibration Strip (\(c)×\(r))"
        case .digitalNegative:  return "Digital Negative"
        case .eightUpProof:     return "8-up Proof Sheet"
        case .softProof:        return "Soft Proof"
        case .stepWedge(let s): return "\(s)-Step Wedge"
        case .flushTarget:      return "Flush Target"
        case .custom(let n):    return n
        }
    }
}

// MARK: - PrintTemplateEngine

struct PrintTemplateEngine {
    /// Compute tile positions for an N×M calibration strip.
    /// Brightness/saturation adjustments are baked into each tile's `sourceImage` so
    /// they render visually distinct without any runtime compositing.
    static func calibrationStripTiles(
        image: NSImage,
        columns: Int,
        rows: Int,
        paperWidth: CGFloat,
        paperHeight: CGFloat,
        margin: CGFloat,
        brightnessSteps: [Double],
        saturationSteps: [Double]
    ) -> [CanvasImage] {
        let gid   = UUID()
        let tileW = (paperWidth  - 2 * margin) / CGFloat(columns)
        let tileH = (paperHeight - 2 * margin) / CGFloat(rows)
        var tiles: [CanvasImage] = []
        for row in 0..<rows {
            for col in 0..<columns {
                let index = row * columns + col
                guard index < brightnessSteps.count else { break }
                let bOffset = brightnessSteps[index]
                let sOffset = saturationSteps.indices.contains(index) ? saturationSteps[index] : 0
                let bPct    = Int(round(bOffset * 100))
                let label   = bPct >= 0 ? "B +\(bPct)%" : "B \(bPct)%"
                let adjusted = image.applyingBrightnessSaturation(brightness: bOffset, saturation: sOffset)
                let tile = CanvasImage(
                    photoAsset: nil,
                    sourceImage: adjusted,
                    position: CGPoint(
                        x: margin + CGFloat(col) * tileW,
                        y: margin + CGFloat(row) * tileH
                    ),
                    size: CGSize(width: tileW * 0.95, height: tileH * 0.95),
                    curveAdjustment: CurveAdjustment(brightnessOffset: bOffset, saturationOffset: sOffset),
                    tileLabel: label,
                    groupID: gid,
                    groupLabel: "Calibration Strip"
                )
                tiles.append(tile)
            }
        }
        return tiles
    }

    /// Brightness steps for a standard N-tile calibration strip (symmetric around 0).
    static func defaultBrightnessSteps(tileCount: Int) -> [Double] {
        guard tileCount > 0 else { return [] }
        let range = 0.30  // ±30% total range
        let step  = tileCount > 1 ? range / Double(tileCount - 1) : 0
        return (0..<tileCount).map { i in -range / 2 + Double(i) * step }
    }

    /// Render an N-step grayscale wedge into a single NSImage.
    /// White at step 0, black at the last step (SpyderPrint/i1Pro convention: lightest first).
    /// Each patch has its step number in the bottom-left corner (small, contrasting text)
    /// so the solid center remains clean for spectrophotometer scanning.
    /// Returns the rendered image and its inch dimensions so the caller can size CanvasImage correctly.
    static func renderStepWedge(
        steps: Int,
        paperWidth: CGFloat,
        paperHeight: CGFloat,
        margin: CGFloat
    ) -> (image: NSImage, inchWidth: CGFloat, inchHeight: CGFloat) {
        guard steps >= 2 else { return (NSImage(), 0, 0) }

        let columns = steps <= 21 ? steps : 16
        let rows    = Int(ceil(Double(steps) / Double(columns)))

        let usableW = paperWidth  - 2 * margin
        let usableH = paperHeight - 2 * margin
        let imgW    = usableW
        let imgH    = rows == 1 ? min(usableH, 2.5) : usableH

        let tileW = imgW / CGFloat(columns)
        let tileH = imgH / CGFloat(rows)
        let gap: CGFloat = 0.015   // inch gap between patches

        let ppi: CGFloat = 144     // 2× for good screen preview
        let pixW = max(1, Int(imgW * ppi))
        let pixH = max(1, Int(imgH * ppi))

        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: pixW, height: pixH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return (NSImage(), imgW, imgH) }

        // White background
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixW), height: CGFloat(pixH)))

        // Only add labels when tiles are large enough to read
        let minTilePx = min(tileW * ppi, tileH * ppi)
        let addLabels = minTilePx >= 18
        let labelFontSize: CGFloat = max(5, min(9, tileW * ppi * 0.22))

        for i in 0..<steps {
            let col = i % columns
            let row = i / columns
            let lum = 1.0 - CGFloat(i) / CGFloat(steps - 1)   // white → black
            // CG y=0 is at BOTTOM — flip the row
            let x = (CGFloat(col) * tileW + gap / 2) * ppi
            let y = (CGFloat(rows - 1 - row) * tileH + gap / 2) * ppi
            let w = (tileW - gap) * ppi
            let h = (tileH - gap) * ppi
            ctx.setFillColor(gray: lum, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))

            if addLabels {
                // Contrasting label in the bottom-left corner of each patch.
                // Spectrophotometer targets the patch CENTER, so a corner label is fine.
                let textGray: CGFloat = lum < 0.45 ? 0.92 : 0.08
                renderStepLabel("\(i + 1)", x: x + 2, y: y + 2,
                                fontSize: labelFontSize, gray: textGray, in: ctx)
            }
        }

        guard let cg = ctx.makeImage() else { return (NSImage(), imgW, imgH) }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: CGFloat(pixW), height: CGFloat(pixH)))
        return (nsImage, imgW, imgH)
    }

    /// Draw a small text label into a grayscale CGContext using CoreText.
    private static func renderStepLabel(
        _ text: String, x: CGFloat, y: CGFloat,
        fontSize: CGFloat, gray: CGFloat, in ctx: CGContext
    ) {
        let font  = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let color = CGColor(gray: gray, alpha: 1.0)
        let attrs = NSDictionary(dictionary: [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ])
        guard let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Legacy tile-based step wedge (kept for calibration strip reuse)

    static func stepWedgeTiles(
        steps: Int,
        paperWidth: CGFloat,
        paperHeight: CGFloat,
        margin: CGFloat
    ) -> [CanvasImage] {
        guard steps >= 2 else { return [] }
        let gid     = UUID()
        let columns = steps <= 21 ? steps : 16
        let rows    = Int(ceil(Double(steps) / Double(columns)))
        let usableW = paperWidth  - 2 * margin
        let usableH = paperHeight - 2 * margin
        let tileW   = usableW / CGFloat(columns)
        let tileH   = rows == 1 ? min(usableH, 2.5) : usableH / CGFloat(rows)
        let gap: CGFloat = 0.015
        var tiles: [CanvasImage] = []
        for i in 0..<steps {
            let col  = i % columns
            let row  = i / columns
            let lum  = 1.0 - CGFloat(i) / CGFloat(steps - 1)
            let gray = Int(round(lum * 255))
            let tile = CanvasImage(
                sourceImage: NSImage.solidGray(luminosity: lum),
                position: CGPoint(x: margin + CGFloat(col) * tileW, y: margin + CGFloat(row) * tileH),
                size: CGSize(width: tileW - gap, height: tileH - gap),
                tileLabel: "\(gray)",
                groupID: gid,
                groupLabel: "\(steps)-Step Wedge"
            )
            tiles.append(tile)
        }
        return tiles
    }
}

// MARK: - NSImage helpers (used by template engine)

extension NSImage {
    /// Apply brightness (−1…+1) and saturation offset (−1…+1, 0 = neutral) via CoreImage.
    func applyingBrightnessSaturation(brightness: Double, saturation: Double) -> NSImage {
        guard brightness != 0 || saturation != 0,
              let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return self }
        let ciIn = CIImage(bitmapImageRep: bitmap)
        let filter = CIFilter.colorControls()
        filter.inputImage = ciIn
        filter.brightness = Float(brightness)
        filter.saturation = Float(1.0 + saturation)
        filter.contrast   = 1.0
        guard let output = filter.outputImage else { return self }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(output, from: output.extent) else { return self }
        return NSImage(cgImage: cg, size: self.size)
    }

    /// Convert to grayscale then invert — produces a digital negative suitable for alt-process printing.
    func grayscaledAndInverted() -> NSImage {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return self }
        let ciIn = CIImage(bitmapImageRep: bitmap)
        // Step 1: desaturate to grayscale
        let gray = CIFilter(name: "CIColorMonochrome",
                            parameters: [kCIInputImageKey: ciIn,
                                         "inputColor": CIColor.white,
                                         "inputIntensity": 1.0])?.outputImage
        guard let grayImg = gray else { return self }
        // Step 2: invert
        let invFilter = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: grayImg])
        guard let inverted = invFilter?.outputImage else { return self }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(inverted, from: inverted.extent) else { return self }
        return NSImage(cgImage: cg, size: self.size)
    }

    /// Rotate the image 90° clockwise as seen on screen (bakes into pixel data).
    func rotatedCW90() -> NSImage {
        guard let cgSrc = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let srcW = cgSrc.width
        let srcH = cgSrc.height
        // Rotated dimensions: swap width/height
        let dstW = srcH
        let dstH = srcW
        guard let space = cgSrc.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: dstW, height: dstH,
                                 bitsPerComponent: cgSrc.bitsPerComponent,
                                 bytesPerRow: 0, space: space,
                                 bitmapInfo: cgSrc.bitmapInfo.rawValue) else { return self }
        // Translate to center, rotate -90°, translate back
        ctx.translateBy(x: CGFloat(dstW) / 2, y: CGFloat(dstH) / 2)
        ctx.rotate(by: -.pi / 2)
        ctx.translateBy(x: -CGFloat(srcW) / 2, y: -CGFloat(srcH) / 2)
        ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        guard let rotatedCG = ctx.makeImage() else { return self }
        return NSImage(cgImage: rotatedCG, size: CGSize(width: size.height, height: size.width))
    }

    /// Rotate the image 90° counter-clockwise as seen on screen (bakes into pixel data).
    func rotatedCCW90() -> NSImage {
        guard let cgSrc = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let srcW = cgSrc.width
        let srcH = cgSrc.height
        let dstW = srcH
        let dstH = srcW
        guard let space = cgSrc.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: dstW, height: dstH,
                                 bitsPerComponent: cgSrc.bitsPerComponent,
                                 bytesPerRow: 0, space: space,
                                 bitmapInfo: cgSrc.bitmapInfo.rawValue) else { return self }
        ctx.translateBy(x: CGFloat(dstW) / 2, y: CGFloat(dstH) / 2)
        ctx.rotate(by: .pi / 2)
        ctx.translateBy(x: -CGFloat(srcW) / 2, y: -CGFloat(srcH) / 2)
        ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        guard let rotatedCG = ctx.makeImage() else { return self }
        return NSImage(cgImage: rotatedCG, size: CGSize(width: size.height, height: size.width))
    }

    /// Create a solid-gray image at the given luminosity (0 = black, 1 = white).
    static func solidGray(luminosity: CGFloat, pixelSize: NSSize = NSSize(width: 256, height: 256)) -> NSImage {
        let img = NSImage(size: pixelSize)
        img.lockFocus()
        NSColor(white: luminosity, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: pixelSize).fill()
        img.unlockFocus()
        return img
    }
}

// MARK: - ICCProfile

struct ICCProfile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let displayName: String
    let groupName: String
}

struct ICCProfileGroup: Identifiable {
    var id: String { name }
    let name: String
    var profiles: [ICCProfile]
}

// MARK: - ICCProfileService

struct ICCProfileService {

    // MARK: Flat URL list (legacy — right panel picker)

    static func discoverICCProfiles() -> [URL] {
        discoverGroupedICCProfiles().flatMap { $0.profiles.map(\.url) }
    }

    // MARK: Grouped discovery — Soft Proof Panel

    static func discoverGroupedICCProfiles() -> [ICCProfileGroup] {
        let fm = FileManager.default

        let searchRoots: [(path: String, recursive: Bool, groupHint: String?)] = [
            ("/Library/ColorSync/Profiles",                          false, nil),
            (NSHomeDirectory() + "/Library/ColorSync/Profiles",      false, nil),
            ("/System/Library/ColorSync/Profiles",                   false, "ColorSync System"),
            ("/Library/Printers/EPSON/InkjetPrinter2/ICCProfiles",   true,  nil),
            ("/Library/Printers/QTR/icc",                            false, "QTR"),
            ("/Library/Printers/QTR/quadtone",                       true,  "QTR"),
            ("/Library/Application Support/Adobe/Color/Profiles",    false, "Adobe"),
        ]

        var buckets: [String: [ICCProfile]] = [:]

        func collect(in dir: URL, recursive: Bool, groupHint: String?) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir && recursive {
                    collect(in: item, recursive: true, groupHint: groupHint)
                } else if ["icc", "icm"].contains(item.pathExtension.lowercased()) {
                    let group = groupHint ?? inferGroup(from: item)
                    let profile = ICCProfile(
                        url: item,
                        displayName: cleanDisplayName(item.deletingPathExtension().lastPathComponent),
                        groupName: group
                    )
                    buckets[group, default: []].append(profile)
                }
            }
        }

        for root in searchRoots {
            collect(in: URL(fileURLWithPath: root.path),
                    recursive: root.recursive, groupHint: root.groupHint)
        }

        let order = ["Hahnemühle", "Epson XP-8600", "Epson SC-P800", "QTR",
                     "Adobe", "ColorSync System", "Other"]
        var groups: [ICCProfileGroup] = order.compactMap { name in
            guard let profiles = buckets[name], !profiles.isEmpty else { return nil }
            return ICCProfileGroup(name: name,
                                   profiles: profiles.sorted { $0.displayName < $1.displayName })
        }
        let known = Set(order)
        for key in buckets.keys.filter({ !known.contains($0) }).sorted() {
            if let profiles = buckets[key], !profiles.isEmpty {
                groups.append(ICCProfileGroup(name: key,
                                              profiles: profiles.sorted { $0.displayName < $1.displayName }))
            }
        }
        return groups
    }

    private static func inferGroup(from url: URL) -> String {
        let path = url.path.lowercased()
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("hahnemule") || name.contains("hahnemühle") || name.contains("hahnmule") {
            return "Hahnemühle"
        }
        if path.contains("/epson/") {
            if name.contains("xp-8600") || name.contains("xp8600") { return "Epson XP-8600" }
            if name.contains("p800")    || name.contains("sc-p800") { return "Epson SC-P800" }
            return "Epson"
        }
        if path.contains("/qtr/")    { return "QTR" }
        if path.contains("/adobe/")  { return "Adobe" }
        if path.contains("/system/library/") { return "ColorSync System" }
        if name.contains("ilford")   { return "Ilford" }
        if name.contains("canson")   { return "Canson" }
        return "Other"
    }

    private static func cleanDisplayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
           .replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - PrintLabViewModel

@MainActor
final class PrintLabViewModel: ObservableObject {

    // MARK: - Breadcrumb (set by PrintLabHostView for toolbar display)
    @Published var breadcrumbSubtitle: String = "Print Layout"

    // MARK: - Canvas images
    @Published var canvasImages: [CanvasImage] = []
    @Published var selectedImageID: UUID?

    // MARK: - Paper state (migrated from PrintCanvasView @State)
    @Published var paperWidth: CGFloat   = 19.0
    @Published var paperHeight: CGFloat  = 13.0
    @Published var isPortrait: Bool      = false
    @Published var marginLeft: CGFloat   = 0.125
    @Published var marginRight: CGFloat  = 0.125
    @Published var marginTop: CGFloat    = 0.125
    @Published var marginBottom: CGFloat = 0.125
    @Published var magnify: CGFloat      = 0.74

    // MARK: - Templates
    @Published var activeTemplate: PrintTemplate? = nil
    @Published var savedTemplates: [PrintTemplate] = []

    // MARK: - ICC / Color management
    @Published var availableICCProfiles: [URL]  = []
    @Published var iccProfileURL: URL?          = nil
    @Published var colorMgmt: String            = "No Color Management"
    @Published var relativeIntent: Bool         = true
    @Published var blackPoint: Bool             = false

    // MARK: - Printer
    @Published var availablePrinters: [String]  = []
    @Published var selectedPrinterName: String  = ""

    // MARK: - Neg prefs (migrated from PrintCanvasView)
    @Published var isNegative: Bool       = false
    @Published var is16Bit: Bool          = true
    @Published var simulateInkBlack: Bool = false
    @Published var flipEmulsion: Bool     = false

    // MARK: - Soft Proof

    @Published var showingSoftProof: Bool = false
    @Published var softProofProfileURL: URL? = nil
    @Published var softProofIntent: CGColorRenderingIntent = .relativeColorimetric
    @Published var softProofBPC: Bool = true

    // MARK: - Section expand state (right panel collapsed by default)
    @Published var printerExpanded: Bool  = false
    @Published var positionExpanded: Bool = false
    @Published var colorExpanded: Bool    = false
    @Published var pageSetupExpanded: Bool = false

    // MARK: - Undo / History

    private struct UndoEntry {
        let label: String
        let images: [CanvasImage]
    }

    private var undoStack: [UndoEntry] = []
    private let maxUndoDepth = 50

    /// Named history entries for display (most-recent first).
    @Published var historyLabels: [String] = []

    func recordSnapshot(label: String = "Edit") {
        undoStack.append(UndoEntry(label: label, images: canvasImages))
        if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
        historyLabels = undoStack.reversed().map(\.label)
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        canvasImages = undoStack.removeLast().images
        historyLabels = undoStack.reversed().map(\.label)
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Layer ordering

    /// Rebuilds `canvasImages` according to the supplied list-item ID order (back-to-front).
    /// Each ID is either a single CanvasImage.id or a group's groupID.
    func reorderLayers(byListItemIDs ids: [UUID]) {
        recordSnapshot(label: "Reorder Layers")
        var newImages: [CanvasImage] = []
        for itemID in ids {
            let groupImages = canvasImages.filter { $0.groupID == itemID }
            if !groupImages.isEmpty {
                newImages.append(contentsOf: groupImages)
            } else if let img = canvasImages.first(where: { $0.id == itemID }) {
                newImages.append(img)
            }
        }
        canvasImages = newImages
    }

    // MARK: - Canvas image management

    func addCanvasImage(_ image: CanvasImage) {
        let name = image.photoAsset?.canonicalName
            .components(separatedBy: ".").first ?? "Layer"
        recordSnapshot(label: "Add \(name)")

        // Fit image within the current canvas dimensions
        var fitted = image
        let canvasW = isPortrait ? min(paperWidth, paperHeight) : max(paperWidth, paperHeight)
        let canvasH = isPortrait ? max(paperWidth, paperHeight) : min(paperWidth, paperHeight)
        let availW = canvasW - marginLeft - marginRight
        let availH = canvasH - marginTop - marginBottom
        if fitted.size.width > availW || fitted.size.height > availH {
            let aspect = fitted.size.width / fitted.size.height
            let fitW = min(availW, availH * aspect)
            let fitH = fitW / aspect
            fitted.size = CGSize(width: fitW, height: fitH)
        }
        // Center on canvas
        fitted.position = CGPoint(
            x: marginLeft + (availW - fitted.size.width) / 2,
            y: marginTop + (availH - fitted.size.height) / 2
        )

        canvasImages.append(fitted)
        selectedImageID = fitted.id
    }

    func removeCanvasImage(id: UUID) {
        let name = canvasImages.first(where: { $0.id == id })?
            .photoAsset?.canonicalName.components(separatedBy: ".").first
            ?? canvasImages.first(where: { $0.id == id })?.tileLabel
            ?? "Layer"
        recordSnapshot(label: "Remove \(name)")
        canvasImages.removeAll { $0.id == id }
        if selectedImageID == id { selectedImageID = canvasImages.last?.id }
    }

    func removeGroup(groupID: UUID) {
        let label = canvasImages.first(where: { $0.groupID == groupID })?.groupLabel ?? "Group"
        recordSnapshot(label: "Remove \(label)")
        let removedIDs = Set(canvasImages.filter { $0.groupID == groupID }.map(\.id))
        canvasImages.removeAll { $0.groupID == groupID }
        if let sel = selectedImageID, removedIDs.contains(sel) {
            selectedImageID = canvasImages.last?.id
        }
    }

    func updateCanvasImage(_ updated: CanvasImage) {
        guard let idx = canvasImages.firstIndex(where: { $0.id == updated.id }) else { return }
        canvasImages[idx] = updated
    }

    /// Refit all canvas images when the paper orientation changes.
    /// Scales and repositions each image to fit within the new paper dimensions.
    /// Distribute all canvas images evenly in a grid across the printable area.
    /// Each image is scaled to fit its cell while preserving aspect ratio.
    func autoArrangeImages() {
        let count = canvasImages.count
        guard count > 0 else { return }
        recordSnapshot(label: "Auto-Arrange")

        let displayW = isPortrait ? min(paperWidth, paperHeight) : max(paperWidth, paperHeight)
        let displayH = isPortrait ? max(paperWidth, paperHeight) : min(paperWidth, paperHeight)

        let margin: CGFloat = 0.3
        let availW = displayW - margin * 2
        let availH = displayH - margin * 2

        let cols = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(cols)))
        let cellW = availW / CGFloat(cols)
        let cellH = availH / CGFloat(rows)

        for idx in canvasImages.indices {
            var img = canvasImages[idx]
            let col = idx % cols
            let row = idx / cols

            // Preserve source image aspect ratio when fitting into the cell
            let rep = img.sourceImage.representations.first
            let pw = rep?.pixelsWide ?? 0
            let ph = rep?.pixelsHigh ?? 0
            let ar: CGFloat = (pw > 0 && ph > 0)
                ? CGFloat(pw) / CGFloat(ph)
                : (img.size.width > 0 && img.size.height > 0 ? img.size.width / img.size.height : 1.0)

            let maxW = cellW * 0.9
            let maxH = cellH * 0.9
            let fitW: CGFloat
            let fitH: CGFloat
            if ar > maxW / maxH {
                fitW = maxW
                fitH = maxW / ar
            } else {
                fitH = maxH
                fitW = maxH * ar
            }

            // Center image within its cell
            let cellOriginX = margin + cellW * CGFloat(col)
            let cellOriginY = margin + cellH * CGFloat(row)
            img.size = CGSize(width: fitW, height: fitH)
            img.position = CGPoint(
                x: cellOriginX + (cellW - fitW) / 2,
                y: cellOriginY + (cellH - fitH) / 2
            )
            canvasImages[idx] = img
        }
    }

    func refitImagesToCanvas() {
        let newW = isPortrait ? min(paperWidth, paperHeight) : max(paperWidth, paperHeight)
        let newH = isPortrait ? max(paperWidth, paperHeight) : min(paperWidth, paperHeight)
        guard newW > 0, newH > 0 else { return }

        for idx in canvasImages.indices {
            var img = canvasImages[idx]
            // Scale image to fit within the new canvas if it overflows
            if img.size.width > newW - marginLeft - marginRight
                || img.size.height > newH - marginTop - marginBottom {
                let availW = newW - marginLeft - marginRight
                let availH = newH - marginTop - marginBottom
                let aspect = img.size.width / img.size.height
                let fitW = min(availW, availH * aspect)
                let fitH = fitW / aspect
                img.size = CGSize(width: fitW, height: fitH)
            }
            // Clamp position into bounds
            img.position = CGPoint(
                x: max(0, min(newW - img.size.width, img.position.x)),
                y: max(0, min(newH - img.size.height, img.position.y))
            )
            canvasImages[idx] = img
        }
    }

    var selectedImage: CanvasImage? {
        get { canvasImages.first { $0.id == selectedImageID } }
        set {
            guard let updated = newValue else { return }
            updateCanvasImage(updated)
        }
    }

    // MARK: - Aspect ratio helpers

    /// Recalculate height from width when aspect-ratio lock is enabled.
    func applyWidthChange(_ newWidth: CGFloat, imageID: UUID) {
        guard let idx = canvasImages.firstIndex(where: { $0.id == imageID }) else { return }
        var img = canvasImages[idx]
        guard img.aspectRatioLocked, img.size.width > 0 else {
            img.size.width = newWidth
            canvasImages[idx] = img
            return
        }
        let ratio = img.size.height / img.size.width
        img.size.width  = newWidth
        img.size.height = newWidth * ratio
        canvasImages[idx] = img
    }

    // MARK: - ICC profile loading

    func loadICCProfiles() {
        availableICCProfiles = ICCProfileService.discoverICCProfiles()
    }

    // MARK: - Printer setup

    func loadPrinters() {
        availablePrinters = Array(NSOrderedSet(array: NSPrinter.printerNames)) as! [String]
        selectedPrinterName = availablePrinters.first { $0.hasPrefix("Quad") }
            ?? availablePrinters.first ?? ""
    }

    // MARK: - Soft proof application

    /// Bake the soft-proofed image into the selected canvas tile and save proof settings.
    func applySoftProof(image: NSImage, profileURL: URL, intentString: String, bpc: Bool) {
        guard let idx = canvasImages.firstIndex(where: { $0.id == selectedImageID })
                ?? canvasImages.indices.first else { return }
        recordSnapshot(label: "Soft Proof")
        canvasImages[idx].sourceImage = image
        canvasImages[idx].iccProfileURL = profileURL
        softProofProfileURL = profileURL
        softProofBPC = bpc
    }

    // MARK: - Snapshot capture

    /// Build a full PrintJobSnapshot from the current ViewModel state.
    func snapshotCurrentState() -> PrintJobSnapshot {
        let intentString: String
        switch softProofIntent {
        case .perceptual:           intentString = "perceptual"
        case .relativeColorimetric: intentString = "relative"
        case .absoluteColorimetric: intentString = "absolute"
        case .saturation:           intentString = "saturation"
        default:                    intentString = "relative"
        }

        let iccName = iccProfileURL
            .map { $0.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ") }

        let placements = canvasImages.map { img in
            PrintJobSnapshot.ImagePlacement(
                photoAssetId: img.photoAsset?.id,
                canonicalName: img.photoAsset?.canonicalName,
                positionX: Double(img.position.x),
                positionY: Double(img.position.y),
                width: Double(img.size.width),
                height: Double(img.size.height),
                rotation: img.rotation,
                aspectRatioLocked: img.aspectRatioLocked,
                borderWidthInches: Double(img.borderWidthInches),
                borderIsWhite: img.borderIsWhite,
                iccProfilePath: img.iccProfileURL?.path,
                brightnessOffset: img.curveAdjustment?.brightnessOffset,
                saturationOffset: img.curveAdjustment?.saturationOffset,
                tileLabel: img.tileLabel,
                groupLabel: img.groupLabel
            )
        }

        let templateEncoder = JSONEncoder()
        templateEncoder.outputFormatting = [.sortedKeys]
        let templateJSON: String? = activeTemplate.flatMap {
            (try? templateEncoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) }
        }

        return PrintJobSnapshot(
            paperWidth: Double(paperWidth),
            paperHeight: Double(paperHeight),
            isPortrait: isPortrait,
            marginLeft: Double(marginLeft),
            marginRight: Double(marginRight),
            marginTop: Double(marginTop),
            marginBottom: Double(marginBottom),
            templateName: activeTemplate?.displayName,
            templateJSON: templateJSON,
            colorMgmt: colorMgmt,
            iccProfilePath: iccProfileURL?.path,
            iccProfileName: iccName,
            renderingIntent: relativeIntent ? "relative" : intentString,
            blackPointCompensation: blackPoint,
            printerName: selectedPrinterName.isEmpty ? nil : selectedPrinterName,
            isNegative: isNegative,
            is16Bit: is16Bit,
            simulateInkBlack: simulateInkBlack,
            flipEmulsion: flipEmulsion,
            softProofEnabled: showingSoftProof,
            softProofProfilePath: softProofProfileURL?.path,
            softProofIntent: intentString,
            softProofBPC: softProofBPC,
            images: placements,
            printAttemptId: nil
        )
    }

    // MARK: - Restore from snapshot

    /// Restore the full Print Lab state from a `PrintJobSnapshot`.
    /// Returns a list of photo IDs whose proxies could not be loaded (empty = full success).
    func restoreFromSnapshot(_ snapshot: PrintJobSnapshot) async -> [String] {
        // Paper
        paperWidth = CGFloat(snapshot.paperWidth)
        paperHeight = CGFloat(snapshot.paperHeight)
        isPortrait = snapshot.isPortrait
        marginLeft = CGFloat(snapshot.marginLeft)
        marginRight = CGFloat(snapshot.marginRight)
        marginTop = CGFloat(snapshot.marginTop)
        marginBottom = CGFloat(snapshot.marginBottom)

        // Color management
        colorMgmt = snapshot.colorMgmt
        iccProfileURL = snapshot.iccProfilePath.map { URL(fileURLWithPath: $0) }
        relativeIntent = snapshot.renderingIntent == "relative"
        blackPoint = snapshot.blackPointCompensation

        // Printer
        if let name = snapshot.printerName { selectedPrinterName = name }
        isNegative = snapshot.isNegative
        is16Bit = snapshot.is16Bit
        simulateInkBlack = snapshot.simulateInkBlack
        flipEmulsion = snapshot.flipEmulsion

        // Soft proof
        showingSoftProof = snapshot.softProofEnabled
        softProofProfileURL = snapshot.softProofProfilePath.map { URL(fileURLWithPath: $0) }
        softProofBPC = snapshot.softProofBPC

        // Template
        if let templateJSON = snapshot.templateJSON,
           let data = templateJSON.data(using: .utf8),
           let template = try? JSONDecoder().decode(PrintTemplate.self, from: data) {
            activeTemplate = template
        }

        // Canvas images
        var missingIds: [String] = []
        var newCanvasImages: [CanvasImage] = []
        let proxiesDir = ProxyGenerationActor.proxiesDirectory()

        for placement in snapshot.images {
            var img: NSImage = NSImage()
            if let assetId = placement.photoAssetId,
               let name = placement.canonicalName {
                let baseName = (name as NSString).deletingPathExtension
                let proxyURL = proxiesDir.appendingPathComponent(baseName + ".jpg")
                if let loaded = NSImage(contentsOf: proxyURL) {
                    img = loaded
                } else {
                    missingIds.append(assetId)
                    continue
                }
            }

            let curve: CurveAdjustment? = {
                if let b = placement.brightnessOffset, let s = placement.saturationOffset {
                    return CurveAdjustment(brightnessOffset: b, saturationOffset: s)
                } else if let b = placement.brightnessOffset {
                    return CurveAdjustment(brightnessOffset: b, saturationOffset: 0)
                }
                return nil
            }()

            // We don't have the full PhotoAsset here — caller should set it if needed
            let canvasImage = CanvasImage(
                photoAsset: nil,
                sourceImage: img,
                position: CGPoint(x: placement.positionX, y: placement.positionY),
                size: CGSize(width: placement.width, height: placement.height),
                rotation: placement.rotation,
                aspectRatioLocked: placement.aspectRatioLocked,
                iccProfileURL: placement.iccProfilePath.map { URL(fileURLWithPath: $0) },
                curveAdjustment: curve,
                tileLabel: placement.tileLabel,
                groupLabel: placement.groupLabel,
                borderWidthInches: CGFloat(placement.borderWidthInches),
                borderIsWhite: placement.borderIsWhite
            )
            newCanvasImages.append(canvasImage)
        }

        canvasImages = newCanvasImages
        selectedImageID = newCanvasImages.first?.id

        return missingIds
    }

    // MARK: - AI suggestion application

    /// Restore from a snapshot and apply AI-suggested curve revision parameters.
    /// Overrides the calibration template with a refined grid centered on the suggestion.
    func applyAISuggestion(
        snapshot: PrintJobSnapshot,
        brightnessCenter: Double,
        range: Double
    ) async -> [String] {
        let missingIds = await restoreFromSnapshot(snapshot)

        // If there's a source image available, apply a refined calibration grid
        if let sourceImage = canvasImages.first?.sourceImage {
            let cols = 4
            let rows = 2
            let template = PrintTemplate.calibrationStrip(
                columns: cols,
                rows: rows,
                brightnessRange: range,
                saturationRange: 0
            )
            applyTemplate(template, sourceImage: sourceImage)

            // Re-center the brightness offsets around the AI-suggested center
            for idx in canvasImages.indices {
                if let curve = canvasImages[idx].curveAdjustment {
                    canvasImages[idx].curveAdjustment = CurveAdjustment(
                        brightnessOffset: curve.brightnessOffset + brightnessCenter,
                        saturationOffset: curve.saturationOffset
                    )
                    // Update tile label to reflect new offset
                    let b = canvasImages[idx].curveAdjustment!.brightnessOffset
                    canvasImages[idx].tileLabel = "B \(b >= 0 ? "+" : "")\(String(format: "%.0f", b * 100))%"
                }
            }
        }

        return missingIds
    }

    // MARK: - Print job logging

    /// Log the current print job to the database as a PrintAttempt and emit activity events.
    func logPrintJob(db: AppDatabase?, activityService: ActivityEventService? = nil) async {
        guard let db = db else { return }
        let photoID = canvasImages.first(where: { $0.id == selectedImageID })?.photoAsset?.id
            ?? canvasImages.first?.photoAsset?.id
        guard let photoID = photoID else { return }

        let intentString: String
        switch softProofIntent {
        case .perceptual:           intentString = "perceptual"
        case .relativeColorimetric: intentString = "relative"
        case .absoluteColorimetric: intentString = "absolute"
        case .saturation:           intentString = "saturation"
        default:                    intentString = "relative"
        }

        let profileName = softProofProfileURL
            .map { $0.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ") }

        let now = Date()
        let attemptId = UUID().uuidString
        let attempt = PrintAttempt(
            id: attemptId,
            photoId: photoID,
            printType: isNegative ? .digitalNegative : .inkjetColor,
            paper: "",
            outcome: .testing,
            outcomeNotes: "",
            curveFileId: nil,
            curveFileName: nil,
            printPhotoId: nil,
            createdAt: now,
            updatedAt: now,
            processSpecificFields: [:],
            iccProfileName: profileName,
            iccProfilePath: softProofProfileURL?.path,
            renderingIntent: softProofProfileURL != nil ? intentString : nil,
            blackPointCompensation: softProofProfileURL != nil ? softProofBPC : nil,
            brightnessCorrection: nil,
            saturationCorrection: nil,
            calibrationTemplate: activeTemplate?.displayName,
            tileParametersJSON: nil,
            winnerTileIndex: nil,
            calibrationNotes: nil
        )

        // Emit print job activity event first to get the cross-reference ID
        var activityEventId: String? = nil
        if let service = activityService {
            var snapshot = snapshotCurrentState()
            snapshot.printAttemptId = attemptId

            let imageName: String = {
                guard let name = canvasImages.first?.photoAsset?.canonicalName else { return "Print" }
                return (name as NSString).deletingPathExtension
            }()
            let templateLabel = activeTemplate?.displayName ?? (isNegative ? "Digital Neg" : "Positive")
            let title = "\(templateLabel) — \(imageName)"
            let detail = [
                profileName.map { "ICC: \($0)" },
                activeTemplate?.displayName,
                "\(Int(paperWidth))×\(Int(paperHeight))\""
            ].compactMap { $0 }.joined(separator: " · ")

            if let rootEvent = try? await service.emitPrintJob(
                photoAssetId: photoID,
                title: title,
                detail: detail,
                snapshot: snapshot
            ) {
                // Emit print attempt as child event
                try? await service.emitPrintAttemptChild(
                    parentEventId: rootEvent.id,
                    photoAssetId: photoID,
                    printerName: selectedPrinterName,
                    templateName: activeTemplate?.displayName
                )
                activityEventId = rootEvent.id
            }
        }

        // Create the thread entry with cross-reference to the activity event
        let repo = PrintAttemptRepository(db.dbPool)
        try? await repo.addPrintAttempt(to: photoID, attempt: attempt, activityEventId: activityEventId)
    }

    // MARK: - Template application

    func applyTemplate(_ template: PrintTemplate, sourceImage: NSImage) {
        recordSnapshot(label: template.displayName)
        activeTemplate = template
        switch template {
        case .calibrationStrip(let cols, let rows, _, let sRange):
            let bSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: cols * rows)
            let sSteps = Array(repeating: sRange / Double(cols * rows), count: cols * rows)
            canvasImages = PrintTemplateEngine.calibrationStripTiles(
                image: sourceImage,
                columns: cols,
                rows: rows,
                paperWidth:  isPortrait ? min(paperWidth, paperHeight) : max(paperWidth, paperHeight),
                paperHeight: isPortrait ? max(paperWidth, paperHeight) : min(paperWidth, paperHeight),
                margin: marginLeft,
                brightnessSteps: bSteps,
                saturationSteps: sSteps
            )
        case .digitalNegative:
            if canvasImages.isEmpty { return }
            var img = canvasImages[0]
            img.sourceImage = img.sourceImage.grayscaledAndInverted()
            img.tileLabel = "Digital Negative"
            canvasImages = [img]
        case .eightUpProof:
            if let first = canvasImages.first {
                let bSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
                canvasImages = PrintTemplateEngine.calibrationStripTiles(
                    image: first.sourceImage,
                    columns: 4, rows: 2,
                    paperWidth:  isPortrait ? min(paperWidth, paperHeight) : paperWidth,
                    paperHeight: isPortrait ? paperHeight : min(paperWidth, paperHeight),
                    margin: marginLeft,
                    brightnessSteps: bSteps,
                    saturationSteps: Array(repeating: 0, count: 8)
                )
            }
        case .softProof:
            // Single image with soft proof flag — colorMgmt set to ColorSync
            colorMgmt = "ColorSync Managed"
            if canvasImages.count > 1 {
                canvasImages = [canvasImages[0]]
            }
        case .stepWedge(let steps):
            let displayW = isPortrait ? min(paperWidth, paperHeight) : max(paperWidth, paperHeight)
            let displayH = isPortrait ? max(paperWidth, paperHeight) : min(paperWidth, paperHeight)
            let (wedgeImg, wedgeW, wedgeH) = PrintTemplateEngine.renderStepWedge(
                steps: steps, paperWidth: displayW, paperHeight: displayH, margin: marginLeft
            )
            // Step wedge is always additive — append alongside existing images instead of replacing
            canvasImages.append(CanvasImage(
                sourceImage: wedgeImg,
                position: CGPoint(x: marginLeft, y: marginTop),
                size: CGSize(width: wedgeW, height: wedgeH),
                tileLabel: "\(steps)-step wedge",
                groupLabel: "\(steps)-Step Wedge"
            ))
        case .flushTarget:
            // Zero margins, image fills full paper maintaining aspect ratio
            let pw = isPortrait ? min(paperWidth, paperHeight) : max(paperWidth, paperHeight)
            let ph = isPortrait ? max(paperWidth, paperHeight) : min(paperWidth, paperHeight)
            marginLeft = 0; marginRight = 0; marginTop = 0; marginBottom = 0
            let img = canvasImages.first?.sourceImage ?? sourceImage
            let rep = img.representations.first
            let pixW = CGFloat(rep?.pixelsWide ?? Int(pw * 360))
            let pixH = CGFloat(rep?.pixelsHigh ?? Int(ph * 360))
            let ar = pixH / pixW
            var fitW = pw, fitH = ph
            if ar > ph / pw {
                fitH = ph; fitW = ph / ar
            } else {
                fitW = pw; fitH = pw * ar
            }
            let ci = CanvasImage(
                sourceImage: img,
                position: CGPoint(x: (pw - fitW) / 2, y: (ph - fitH) / 2),
                size: CGSize(width: fitW, height: fitH),
                tileLabel: "Flush Target"
            )
            canvasImages = [ci]
        case .custom:
            break  // custom templates applied externally
        }
    }
}
