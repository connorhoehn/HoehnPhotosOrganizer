import AppKit
import CoreGraphics

// MARK: - PBNTemplateExportError

enum PBNTemplateExportError: Error, LocalizedError {
    case failedToCreatePDFContext
    case failedToRenderTemplate
    case failedToCreateCGImage
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .failedToCreatePDFContext: return "Could not create PDF graphics context."
        case .failedToRenderTemplate:  return "Failed to render the paint-by-numbers template."
        case .failedToCreateCGImage:   return "Could not create CGImage from rendered output."
        case .invalidDestination:      return "The export destination URL is invalid."
        }
    }
}

// MARK: - PBNTemplateExporter

final class PBNTemplateExporter {

    // MARK: - TemplateOptions

    struct TemplateOptions {
        /// Paper size in points (72 points = 1 inch). Default is US Letter.
        var paperSize: NSSize = NSSize(width: 612, height: 792)
        /// Page margin in points. Default is 0.5 inch.
        var margin: CGFloat = 36
        /// Contour line weight in points for the PDF template.
        var contourLineWeight: CGFloat = 1.0
        /// Font size for region number labels.
        var numberFontSize: CGFloat = 8
        /// Font size for the title text.
        var titleFontSize: CGFloat = 18
        /// Whether to draw reference grid lines over the template.
        var showGridLines: Bool = false
        /// Spacing between grid lines in points (default 72 = 1 inch).
        var gridSpacing: CGFloat = 72
        /// Whether to include the color guide as a second page.
        var includeColorGuide: Bool = true
        /// Whether to include a small reference of the original image on the guide page.
        var includeOriginal: Bool = false
        /// Scale factor for high-resolution rendering (e.g. 4.0 = 300 DPI on letter).
        var highResScale: CGFloat = 4.0

        nonisolated init() {}
    }

    private nonisolated(unsafe) let renderer = PaintByNumbersRenderer()

    // MARK: - Public API

    /// Export a complete paint-by-numbers PDF to the given URL.
    ///
    /// Page 1: Numbered contour template at high resolution.
    /// Page 2 (optional): Color guide with swatches, names, RGB values, and palette strip.
    func exportPDF(
        source: NSImage,
        config: PBNConfig,
        regions: [PBNRegion],
        options: TemplateOptions = TemplateOptions(),
        to url: URL
    ) async throws {
        let mediaBox = CGRect(origin: .zero, size: options.paperSize)

        guard let pdfContext = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw PBNTemplateExportError.failedToCreatePDFContext
        }

        // --- Page 1: Template ---
        let templateImage = try await renderTemplate(
            source: source,
            config: config,
            options: options
        )

        var templateBox = mediaBox
        pdfContext.beginPage(mediaBox: &templateBox)
        try drawTemplatePage(
            in: pdfContext,
            templateImage: templateImage,
            config: config,
            options: options,
            mediaBox: mediaBox
        )
        pdfContext.endPage()

        // --- Page 2: Color Guide ---
        if options.includeColorGuide {
            let guideImage = renderColorGuide(
                config: config,
                regions: regions,
                options: options,
                originalImage: options.includeOriginal ? source : nil
            )

            var guideBox = mediaBox
            pdfContext.beginPage(mediaBox: &guideBox)
            if let cgGuide = cgImage(from: guideImage) {
                pdfContext.draw(cgGuide, in: mediaBox)
            }
            pdfContext.endPage()
        }

        pdfContext.closePDF()
    }

    /// Render just the template page (contours + numbers) as a high-res NSImage.
    func renderTemplate(
        source: NSImage,
        config: PBNConfig,
        options: TemplateOptions = TemplateOptions()
    ) async throws -> NSImage {
        // Build a config with the export-specific contour settings
        var exportConfig = config
        exportConfig.contourSettings.lineWeight = Double(options.contourLineWeight)
        exportConfig.contourSettings.showNumbers = true
        exportConfig.contourSettings.numberFontSize = Double(options.numberFontSize)

        let numberedImage = try await renderer.render(
            source: source,
            config: exportConfig,
            displayMode: .numbered,
            progress: { _ in }
        )

        return numberedImage
    }

    /// Render the color guide page as an NSImage.
    func renderColorGuide(
        config: PBNConfig,
        regions: [PBNRegion],
        options: TemplateOptions = TemplateOptions(),
        originalImage: NSImage? = nil
    ) -> NSImage {
        let pageSize = options.paperSize
        let margin = options.margin
        let image = NSImage(size: pageSize)

        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        // White background
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(origin: .zero, size: pageSize))

        let contentWidth = pageSize.width - margin * 2
        var cursorY = pageSize.height - margin

        // --- Title ---
        let titleFont = NSFont.systemFont(ofSize: options.titleFontSize, weight: .bold)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.black,
        ]
        let titleText = "Paint by Numbers Color Guide"
        let titleAttr = NSAttributedString(string: titleText, attributes: titleAttrs)
        let titleSize = titleAttr.size()
        cursorY -= titleSize.height
        titleAttr.draw(at: NSPoint(x: margin, y: cursorY))
        cursorY -= 4

        // --- Subtitle (config name) ---
        let subtitleFont = NSFont.systemFont(ofSize: options.titleFontSize * 0.7, weight: .regular)
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: subtitleFont,
            .foregroundColor: NSColor.darkGray,
        ]
        let subtitleAttr = NSAttributedString(string: config.name, attributes: subtitleAttrs)
        let subtitleSize = subtitleAttr.size()
        cursorY -= subtitleSize.height
        subtitleAttr.draw(at: NSPoint(x: margin, y: cursorY))
        cursorY -= 16

        // --- Swatch Grid ---
        let columns = min(4, max(1, regions.count))
        let swatchPadding: CGFloat = 8
        let swatchCellWidth = (contentWidth - CGFloat(columns - 1) * swatchPadding) / CGFloat(columns)
        let swatchCellHeight: CGFloat = 90
        let swatchSquareSize: CGFloat = 20
        let labelFontSize: CGFloat = 8
        let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let labelFont = NSFont.systemFont(ofSize: labelFontSize, weight: .regular)
        let rgbFont = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)

        let rows = Int(ceil(Double(regions.count) / Double(columns)))
        let totalGridHeight = CGFloat(rows) * (swatchCellHeight + swatchPadding)
        let gridOriginY = cursorY - totalGridHeight

        for (index, region) in regions.enumerated() {
            let col = index % columns
            let row = index / columns

            let cellX = margin + CGFloat(col) * (swatchCellWidth + swatchPadding)
            let cellY = cursorY - CGFloat(row + 1) * (swatchCellHeight + swatchPadding) + swatchPadding

            // Cell background (light gray rounded rect)
            let cellRect = CGRect(x: cellX, y: cellY, width: swatchCellWidth, height: swatchCellHeight)
            let cellPath = NSBezierPath(roundedRect: cellRect, xRadius: 4, yRadius: 4)
            NSColor(white: 0.96, alpha: 1).setFill()
            cellPath.fill()

            // Color swatch square
            let swatchRect = CGRect(
                x: cellX + 8,
                y: cellY + swatchCellHeight - swatchSquareSize - 8,
                width: swatchSquareSize,
                height: swatchSquareSize
            )
            let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
            region.color.nsColor.setFill()
            swatchPath.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            swatchPath.lineWidth = 0.5
            swatchPath.stroke()

            // Region number next to swatch
            let numStr = NSAttributedString(
                string: "\(region.id + 1)",
                attributes: [
                    .font: numberFont,
                    .foregroundColor: NSColor.black,
                ]
            )
            let numSize = numStr.size()
            numStr.draw(at: NSPoint(
                x: swatchRect.maxX + 6,
                y: swatchRect.midY - numSize.height / 2
            ))

            // Color name (may wrap)
            var textY = swatchRect.minY - 4
            let nameStr = NSAttributedString(
                string: region.color.name,
                attributes: [
                    .font: labelFont,
                    .foregroundColor: NSColor.black,
                ]
            )
            let nameSize = nameStr.size()
            textY -= nameSize.height
            nameStr.draw(at: NSPoint(x: cellX + 8, y: textY))

            // RGB values
            let r = Int(round(region.color.red * 255))
            let g = Int(round(region.color.green * 255))
            let b = Int(round(region.color.blue * 255))
            let rgbText = "R:\(r)  G:\(g)  B:\(b)"
            let rgbStr = NSAttributedString(
                string: rgbText,
                attributes: [
                    .font: rgbFont,
                    .foregroundColor: NSColor.darkGray,
                ]
            )
            let rgbSize = rgbStr.size()
            textY -= rgbSize.height + 2
            rgbStr.draw(at: NSPoint(x: cellX + 8, y: textY))

            // Coverage percentage
            if region.coveragePercent > 0 {
                let coverageText = String(format: "%.1f%% of image", region.coveragePercent)
                let coverageStr = NSAttributedString(
                    string: coverageText,
                    attributes: [
                        .font: rgbFont,
                        .foregroundColor: NSColor.gray,
                    ]
                )
                let coverageSize = coverageStr.size()
                textY -= coverageSize.height + 1
                coverageStr.draw(at: NSPoint(x: cellX + 8, y: textY))
            }
        }

        cursorY = gridOriginY - 12

        // --- Adjacency Hints ---
        let adjacencyHints = buildAdjacencyHints(regions: regions, config: config)
        if !adjacencyHints.isEmpty {
            let hintHeaderAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
            let hintHeader = NSAttributedString(string: "Color Mixing Hints (Adjacent Regions)", attributes: hintHeaderAttrs)
            let hintHeaderSize = hintHeader.size()
            cursorY -= hintHeaderSize.height
            hintHeader.draw(at: NSPoint(x: margin, y: cursorY))
            cursorY -= 4

            let hintFont = NSFont.systemFont(ofSize: 8, weight: .regular)
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: hintFont,
                .foregroundColor: NSColor.darkGray,
            ]
            for hint in adjacencyHints {
                let hintStr = NSAttributedString(string: hint, attributes: hintAttrs)
                let hintSize = hintStr.size()
                cursorY -= hintSize.height + 1
                if cursorY < margin + 80 { break } // leave room for palette strip
                hintStr.draw(at: NSPoint(x: margin + 8, y: cursorY))
            }
            cursorY -= 8
        }

        // --- Palette Strip ---
        let stripHeight: CGFloat = 36
        let stripY = max(margin, cursorY - stripHeight - 8)
        let stripRect = CGRect(x: margin, y: stripY, width: contentWidth, height: stripHeight)

        // Strip border
        let stripBorderPath = NSBezierPath(roundedRect: stripRect, xRadius: 4, yRadius: 4)
        NSColor(white: 0.85, alpha: 1).setStroke()
        stripBorderPath.lineWidth = 0.5
        stripBorderPath.stroke()

        let paletteColors = config.palette.colors
        guard !paletteColors.isEmpty else {
            image.unlockFocus()
            return image
        }

        let colorWidth = contentWidth / CGFloat(paletteColors.count)
        for (i, pbnColor) in paletteColors.enumerated() {
            let colorRect = CGRect(
                x: margin + CGFloat(i) * colorWidth,
                y: stripY,
                width: colorWidth,
                height: stripHeight
            )
            // Clip to rounded rect for first/last
            pbnColor.nsColor.setFill()
            NSBezierPath(rect: colorRect).fill()

            // Number label
            let stripNumAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: contrastingTextColor(for: pbnColor.nsColor),
            ]
            let stripNum = NSAttributedString(string: "\(i + 1)", attributes: stripNumAttrs)
            let stripNumSize = stripNum.size()
            stripNum.draw(at: NSPoint(
                x: colorRect.midX - stripNumSize.width / 2,
                y: colorRect.midY - stripNumSize.height / 2
            ))
        }

        // Clip corners of the strip by re-stroking the border
        stripBorderPath.addClip()

        // --- Optional Original Image Reference ---
        if let original = originalImage {
            let refMaxHeight: CGFloat = 100
            let refMaxWidth: CGFloat = 120
            let origSize = original.size
            let aspectRatio = origSize.width / origSize.height
            var refWidth = refMaxWidth
            var refHeight = refWidth / aspectRatio
            if refHeight > refMaxHeight {
                refHeight = refMaxHeight
                refWidth = refHeight * aspectRatio
            }
            let refX = pageSize.width - margin - refWidth
            let refY = stripY - refHeight - 12
            if refY > margin {
                let refRect = NSRect(x: refX, y: refY, width: refWidth, height: refHeight)
                original.draw(in: refRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                // Border
                let refBorder = NSBezierPath(rect: refRect)
                NSColor(white: 0.7, alpha: 1).setStroke()
                refBorder.lineWidth = 0.5
                refBorder.stroke()
                // Label
                let refLabel = NSAttributedString(
                    string: "Reference",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                        .foregroundColor: NSColor.gray,
                    ]
                )
                refLabel.draw(at: NSPoint(x: refX, y: refY - 10))
            }
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Private: Template Page Drawing

    /// Draw the template page contents into a PDF CGContext.
    private func drawTemplatePage(
        in ctx: CGContext,
        templateImage: NSImage,
        config: PBNConfig,
        options: TemplateOptions,
        mediaBox: CGRect
    ) throws {
        let margin = options.margin
        let pageWidth = mediaBox.width
        let pageHeight = mediaBox.height
        let contentWidth = pageWidth - margin * 2
        let _ = pageHeight - margin * 2  // contentHeight available if needed

        // --- Title ---
        let titleText = "Paint by Numbers — \(config.name)"
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, options.titleFontSize, nil)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.black,
        ]
        let titleAttr = NSAttributedString(string: titleText, attributes: titleAttrs)
        let titleLine = CTLineCreateWithAttributedString(titleAttr)
        let titleBounds = CTLineGetBoundsWithOptions(titleLine, [])
        let titleY = pageHeight - margin - titleBounds.height
        ctx.textPosition = CGPoint(x: margin, y: titleY)
        CTLineDraw(titleLine, ctx)

        let imageAreaTop = titleY - 12
        let imageAreaHeight = imageAreaTop - margin

        // --- Template Image ---
        guard let cgTemplate = cgImage(from: templateImage) else {
            throw PBNTemplateExportError.failedToCreateCGImage
        }

        let templateAspect = CGFloat(cgTemplate.width) / CGFloat(cgTemplate.height)
        var drawWidth = contentWidth
        var drawHeight = drawWidth / templateAspect
        if drawHeight > imageAreaHeight {
            drawHeight = imageAreaHeight
            drawWidth = drawHeight * templateAspect
        }

        let drawX = margin + (contentWidth - drawWidth) / 2
        let drawY = margin + (imageAreaHeight - drawHeight) / 2
        let drawRect = CGRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

        ctx.draw(cgTemplate, in: drawRect)

        // --- Grid Lines ---
        if options.showGridLines {
            drawGridLines(
                in: ctx,
                rect: drawRect,
                spacing: options.gridSpacing,
                imagePixelWidth: CGFloat(cgTemplate.width),
                imagePixelHeight: CGFloat(cgTemplate.height)
            )
        }
    }

    /// Draw light gray dashed reference grid lines over the template area.
    private func drawGridLines(
        in ctx: CGContext,
        rect: CGRect,
        spacing: CGFloat,
        imagePixelWidth: CGFloat,
        imagePixelHeight: CGFloat
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])

        // Scale spacing relative to the drawn size vs pixel size
        let scaleX = rect.width / imagePixelWidth
        let scaleY = rect.height / imagePixelHeight
        let spacingX = spacing * scaleX
        let spacingY = spacing * scaleY

        // Use the larger of the two to keep grid roughly square
        let effectiveSpacing = max(spacingX, spacingY)

        // Vertical lines
        var x = rect.minX + effectiveSpacing
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += effectiveSpacing
        }

        // Horizontal lines
        var y = rect.minY + effectiveSpacing
        while y < rect.maxY {
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += effectiveSpacing
        }

        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Private: Adjacency Hints

    /// Build adjacency hints describing which regions border each other.
    /// Regions with consecutive threshold ranges are always adjacent; this provides
    /// useful mixing guidance for painters.
    private func buildAdjacencyHints(regions: [PBNRegion], config: PBNConfig) -> [String] {
        var hints: [String] = []
        let sortedRegions = regions.sorted { $0.id < $1.id }

        for i in 0..<sortedRegions.count {
            guard i + 1 < sortedRegions.count else { break }
            let current = sortedRegions[i]
            let next = sortedRegions[i + 1]
            let hint = "\(current.id + 1) (\(current.color.name)) borders \(next.id + 1) (\(next.color.name))"
            hints.append(hint)
        }

        return hints
    }

    // MARK: - Private: Helpers

    /// Extract a CGImage from an NSImage.
    private func cgImage(from nsImage: NSImage) -> CGImage? {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.cgImage
    }

    /// Return black or white depending on which has better contrast against the given color.
    private func contrastingTextColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .black }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.5 ? .black : .white
    }
}
