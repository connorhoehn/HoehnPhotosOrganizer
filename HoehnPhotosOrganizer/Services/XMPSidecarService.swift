import Foundation
import ImageIO
import UniformTypeIdentifiers

enum XMPError: LocalizedError {
    case parsingFailed(String)
    case writeFailed(String)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .parsingFailed(let msg):
            "XMP parsing failed: \(msg)"
        case .writeFailed(let msg):
            "XMP write failed: \(msg)"
        case .invalidFormat:
            "Invalid XMP format"
        }
    }
}

final class XMPSidecarService {
    private let printNamespace = "http://hoehns.photo/print-workflow/"

    // MARK: - Read

    /// Extract print metadata from XMP sidecar file.
    func readPrintMetadata(from sidecarURL: URL) throws -> [String: String] {
        let xmlData = try Data(contentsOf: sidecarURL)
        let parser = XMLParser(data: xmlData)

        let delegate = XMPParserDelegate(printNamespace: printNamespace)
        parser.delegate = delegate

        guard parser.parse() else {
            throw XMPError.parsingFailed(parser.parserError?.localizedDescription ?? "Unknown error")
        }

        return delegate.printMetadata
    }

    // MARK: - Write

    /// Write print metadata to XMP sidecar, preserving existing non-print metadata.
    func writePrintMetadata(
        to sidecarURL: URL,
        attempt: PrintAttempt,
        mergeWithExisting: Bool = true
    ) throws {
        var existingXML = ""

        // Read existing XMP if merge requested
        if mergeWithExisting && FileManager.default.fileExists(atPath: sidecarURL.path) {
            existingXML = try String(contentsOf: sidecarURL, encoding: .utf8)
        }

        // Build new XMP XML with print namespace
        let xmpXML = buildXMPWithPrintMetadata(attempt: attempt, existingXML: existingXML)

        // Write to file
        do {
            try xmpXML.write(to: sidecarURL, atomically: true, encoding: .utf8)
        } catch {
            throw XMPError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func buildXMPWithPrintMetadata(
        attempt: PrintAttempt,
        existingXML: String
    ) -> String {
        let printType = attempt.printType.rawValue
        let paper = xmlEscape(attempt.paper)
        let outcome = attempt.outcome.rawValue
        let outcomeNotes = xmlEscape(attempt.outcomeNotes)
        let curveFile = attempt.curveFileName.map { xmlEscape($0) } ?? ""
        let loggedAt = ISO8601DateFormatter().string(from: attempt.createdAt)

        // If existing XML, merge into it; otherwise create new
        if existingXML.isEmpty {
            return """
            <?xml version="1.0" encoding="UTF-8"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:print="\(printNamespace)"
                  print:printType="\(printType)"
                  print:paper="\(paper)"
                  print:outcome="\(outcome)"
                  print:outcomeNotes="\(outcomeNotes)"
                  print:curveFile="\(curveFile)"
                  print:loggedAt="\(loggedAt)"
                />
              </rdf:RDF>
            </x:xmpmeta>
            """
        } else {
            // Merge: parse existing and add print attributes
            // For simplicity, use string manipulation; ideally use XMLElement APIs
            var merged = existingXML

            // Find rdf:Description tag and add print attributes if not present
            let printAttrs = """
            xmlns:print="\(printNamespace)" \
            print:printType="\(printType)" \
            print:paper="\(paper)" \
            print:outcome="\(outcome)" \
            print:outcomeNotes="\(outcomeNotes)" \
            print:curveFile="\(curveFile)" \
            print:loggedAt="\(loggedAt)"
            """

            if merged.contains("rdf:Description") {
                // Inject print namespace if not present
                if !merged.contains("xmlns:print") {
                    merged = merged.replacingOccurrences(
                        of: "<rdf:Description",
                        with: "<rdf:Description \(printAttrs)"
                    )
                } else {
                    // Update existing print attributes
                    // This is a simplified approach; full XML parsing would be more robust
                    merged = removePrintAttributes(from: merged)
                    merged = merged.replacingOccurrences(
                        of: "<rdf:Description",
                        with: "<rdf:Description \(printAttrs)"
                    )
                }
            }

            return merged
        }
    }

    private func removePrintAttributes(from xml: String) -> String {
        var result = xml
        let patterns = [
            "xmlns:print=\"[^\"]*\"",
            "print:[a-zA-Z]+=\"[^\"]*\""
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }

        return result
    }

    // MARK: - Camera Raw adjustments (crs: namespace)

    /// Write Camera Raw adjustment parameters to an XMP sidecar file.
    ///
    /// The resulting `.xmp` file, placed next to the source image, is read automatically
    /// by Adobe Photoshop (via Camera Raw) when the image is opened. Adjustments appear
    /// in the Camera Raw dialog as tone curve, exposure, and basic controls.
    ///
    /// Overwrites any existing sidecar at `sidecarURL`.
    func writeAdjustmentXMP(to sidecarURL: URL, adjustments: [ImageAdjustment]) throws {
        var toneCurvePoints: [CurvePoint]?
        var blacks = 0, whites = 0, shadows = 0, highlights = 0
        var exposure = 0.0
        var contrast = 0, saturation = 0, vibrance = 0

        for adj in adjustments {
            switch adj.type {
            case .toneCurve(let pts):
                toneCurvePoints = pts
            case .levels(let b, let w, let s, let h, let e):
                blacks = b; whites = w; shadows = s; highlights = h; exposure = e
            case .basic(let c, let sat, let v):
                contrast = c; saturation = sat; vibrance = v
            }
        }

        let xmp = buildCameraRawXMP(
            toneCurvePoints: toneCurvePoints,
            blacks: blacks, whites: whites, shadows: shadows,
            highlights: highlights, exposure: exposure,
            contrast: contrast, saturation: saturation, vibrance: vibrance
        )

        do {
            try xmp.write(to: sidecarURL, atomically: true, encoding: .utf8)
        } catch {
            throw XMPError.writeFailed(error.localizedDescription)
        }
    }

    /// Embed Camera Raw adjustment parameters directly into a TIFF (or JPEG) file's XMP metadata.
    ///
    /// Uses `CGImageDestinationCopyImageSource` so pixel data is copied losslessly — only
    /// the metadata block changes. The original file is replaced atomically.
    /// Any existing `.xmp` sidecar next to the image is deleted after a successful embed.
    func embedAdjustmentXMP(into imageURL: URL, adjustments: [ImageAdjustment]) throws {
        var toneCurvePoints: [CurvePoint]?
        var blacks = 0, whites = 0, shadows = 0, highlights = 0
        var exposure = 0.0
        var contrast = 0, saturation = 0, vibrance = 0

        for adj in adjustments {
            switch adj.type {
            case .toneCurve(let pts):      toneCurvePoints = pts
            case .levels(let b, let w, let s, let h, let e):
                blacks = b; whites = w; shadows = s; highlights = h; exposure = e
            case .basic(let c, let sat, let v):
                contrast = c; saturation = sat; vibrance = v
            }
        }

        let xmpXML = buildCameraRawXMP(
            toneCurvePoints: toneCurvePoints,
            blacks: blacks, whites: whites, shadows: shadows,
            highlights: highlights, exposure: exposure,
            contrast: contrast, saturation: saturation, vibrance: vibrance
        )

        guard let xmpData = xmpXML.data(using: .utf8) else {
            throw XMPError.writeFailed("Failed to encode XMP as UTF-8")
        }
        guard let metadata = CGImageMetadataCreateFromXMPData(xmpData as CFData) else {
            throw XMPError.writeFailed("Failed to parse XMP into CGImageMetadata")
        }
        // .dng files exported by this app are TIFF bytes with a .dng extension.
        // macOS otherwise routes .dng to the RA02 raw reader which rejects TIFF bytes.
        let sourceOpts: CFDictionary? = imageURL.pathExtension.lowercased() == "dng"
            ? [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
            : nil
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOpts) else {
            throw XMPError.writeFailed("Cannot open image at \(imageURL.lastPathComponent)")
        }

        // Detect source UTType so the destination matches (TIFF → TIFF, JPEG → JPEG, etc.)
        let sourceType = CGImageSourceGetType(source) as String? ?? UTType.tiff.identifier

        // Write to a sibling temp file, then atomically replace the original.
        let tempURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(imageURL.lastPathComponent).xmptmp")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, sourceType as CFString, 1, nil
        ) else {
            throw XMPError.writeFailed("Cannot create image destination for \(imageURL.lastPathComponent)")
        }

        let options: [String: Any] = [
            kCGImageDestinationMetadata as String: metadata,
            kCGImageDestinationMergeMetadata as String: true
        ]
        var copyError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &copyError) else {
            let detail = copyError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw XMPError.writeFailed("CGImageDestinationCopyImageSource failed: \(detail)")
        }

        // Replace the original file.
        _ = try FileManager.default.replaceItemAt(imageURL, withItemAt: tempURL)

        // Clean up any stale sidecar — metadata now lives in the file itself.
        let sidecarURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private func buildCameraRawXMP(
        toneCurvePoints: [CurvePoint]?,
        blacks: Int, whites: Int, shadows: Int, highlights: Int, exposure: Double,
        contrast: Int, saturation: Int, vibrance: Int
    ) -> String {
        let curveName = toneCurvePoints != nil ? "Custom" : "Linear"

        // Build the rdf:Seq for the tone curve, if present
        var curveElement = ""
        if let points = toneCurvePoints, !points.isEmpty {
            let liLines = points
                .map { "          <rdf:li>\($0.input), \($0.output)</rdf:li>" }
                .joined(separator: "\n")
            curveElement = """

      <crs:ToneCurvePV2012>
        <rdf:Seq>
\(liLines)
        </rdf:Seq>
      </crs:ToneCurvePV2012>
"""
        }

        // crs:Version is the Camera Raw plug-in version Adobe uses for compatibility gating.
        // ProcessVersion 11.0 = PV2012 (Lightroom 4+). HasSettings must be "True" for Photoshop
        // to route the file through Camera Raw rather than opening it directly.
        return """
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
      crs:Version="16.0"
      crs:ProcessVersion="11.0"
      crs:HasSettings="True"
      crs:Blacks2012="\(blacks)"
      crs:Whites2012="\(whites)"
      crs:Shadows2012="\(shadows)"
      crs:Highlights2012="\(highlights)"
      crs:Exposure2012="\(String(format: "%.2f", exposure))"
      crs:Contrast2012="\(contrast)"
      crs:Clarity2012="0"
      crs:Dehaze="0"
      crs:Texture="0"
      crs:Saturation="\(saturation)"
      crs:Vibrance="\(vibrance)"
      crs:ToneCurveName2012="\(curveName)">\(curveElement)
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
"""
    }

    private func xmlEscape(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Parser Delegate

final class XMPParserDelegate: NSObject, XMLParserDelegate {
    private let printNamespace: String
    var printMetadata = [String: String]()

    init(printNamespace: String) {
        self.printNamespace = printNamespace
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        // Look for rdf:Description element
        // When not using namespace-aware parsing, elementName includes the prefix (e.g., "rdf:Description")
        let localName = elementName.contains(":") ? String(elementName.split(separator: ":").last!) : elementName

        if localName == "Description" {
            for (key, value) in attributeDict {
                // XMLParser includes namespace prefixes in attribute keys
                // e.g., key might be "print:printType"
                if key.hasPrefix("print:") {
                    let cleanKey = key.replacingOccurrences(of: "print:", with: "")
                    printMetadata[cleanKey] = value
                }
            }
        }
    }
}
