import Foundation
import PDFKit
import AppKit

final class PrintRecipeExporter {
    func generateRecipePDF(
        attempt: PrintAttempt,
        sourceImage: NSImage?,
        printPhoto: NSImage?
    ) -> PDFDocument? {
        let pdfRect = CGRect(x: 0, y: 0, width: 612, height: 792)  // Letter size
        let pdfData = NSMutableData()

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            return nil
        }

        var mediaBox = pdfRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        context.beginPDFPage(nil)

        // Safe margins and starting position
        let leftMargin: CGFloat = 40
        let rightMargin: CGFloat = 40
        let topMargin: CGFloat = 40
        let pageWidth = pdfRect.width - leftMargin - rightMargin
        var yPos = pdfRect.height - topMargin

        // 1. Title
        yPos = drawTitle(in: context, attempt: attempt, at: CGPoint(x: leftMargin, y: yPos))
        yPos -= 12

        // 2. Divider
        context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: leftMargin, y: yPos))
        context.addLine(to: CGPoint(x: pdfRect.width - rightMargin, y: yPos))
        context.strokePath()
        yPos -= 12

        // 3. Process-specific fields
        yPos = drawProcessFields(
            in: context,
            attempt: attempt,
            at: CGPoint(x: leftMargin, y: yPos),
            maxWidth: pageWidth
        )
        yPos -= 12

        // 4. Divider
        context.move(to: CGPoint(x: leftMargin, y: yPos))
        context.addLine(to: CGPoint(x: pdfRect.width - rightMargin, y: yPos))
        context.strokePath()
        yPos -= 16

        // 5. Images section
        let imageTopY = yPos
        let imageHeight: CGFloat = 150
        let imageWidth: CGFloat = 200

        if let sourceImage = sourceImage {
            drawImageWithLabel(
                in: context,
                image: sourceImage,
                label: "Source Photo",
                rect: CGRect(x: leftMargin, y: imageTopY - imageHeight, width: imageWidth, height: imageHeight)
            )
        }

        if let printPhoto = printPhoto {
            drawImageWithLabel(
                in: context,
                image: printPhoto,
                label: "Print Outcome",
                rect: CGRect(x: leftMargin + imageWidth + 20, y: imageTopY - imageHeight, width: imageWidth, height: imageHeight)
            )
        }

        yPos = imageTopY - imageHeight - 20

        // 6. Outcome notes
        if !attempt.outcomeNotes.isEmpty {
            yPos = drawOutcomeNotes(
                in: context,
                notes: attempt.outcomeNotes,
                at: CGPoint(x: leftMargin, y: yPos),
                maxWidth: pageWidth
            )
        }

        // 7. Curve file reference (if present)
        if let curveFileName = attempt.curveFileName {
            _ = drawCurveReference(
                in: context,
                fileName: curveFileName,
                at: CGPoint(x: leftMargin, y: yPos - 16)
            )
        }

        context.endPDFPage()
        context.closePDF()

        // Convert to PDFDocument
        if let pdfDocument = PDFDocument(data: pdfData as Data) {
            return pdfDocument
        }

        return nil
    }

    private func drawTitle(
        in context: CGContext,
        attempt: PrintAttempt,
        at origin: CGPoint
    ) -> CGFloat {
        let title = "Print Recipe: \(attempt.printType.displayName)"
        let font = NSFont.boldSystemFont(ofSize: 16)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]

        let nsString = title as NSString
        nsString.draw(at: origin, withAttributes: attributes)

        return origin.y - 20
    }

    private func drawProcessFields(
        in context: CGContext,
        attempt: PrintAttempt,
        at origin: CGPoint,
        maxWidth: CGFloat
    ) -> CGFloat {
        let fieldFont = NSFont.systemFont(ofSize: 10)
        let labelFont = NSFont.boldSystemFont(ofSize: 10)

        let labels = processFieldLabels(attempt: attempt)
        var yPos = origin.y

        for (label, value) in labels {
            let text = "\(label): \(value)"
            let nsString = text as NSString
            _ = nsString.size(withAttributes: [.font: fieldFont])

            // Draw with label in bold
            let labelAttr: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
            let label_ns = (label + ":") as NSString
            label_ns.draw(at: CGPoint(x: origin.x, y: yPos), withAttributes: labelAttr)

            let valueAttr: [NSAttributedString.Key: Any] = [.font: fieldFont, .foregroundColor: NSColor.darkGray]
            let value_ns = " \(value)" as NSString
            value_ns.draw(at: CGPoint(x: origin.x + label_ns.size(withAttributes: labelAttr).width, y: yPos), withAttributes: valueAttr)

            yPos -= 12
        }

        return yPos
    }

    private func drawOutcomeNotes(
        in context: CGContext,
        notes: String,
        at origin: CGPoint,
        maxWidth: CGFloat
    ) -> CGFloat {
        let header = "Outcome Notes:" as NSString
        let headerFont = NSFont.boldSystemFont(ofSize: 11)
        let headerAttr: [NSAttributedString.Key: Any] = [.font: headerFont]
        header.draw(at: origin, withAttributes: headerAttr)

        let noteFont = NSFont.systemFont(ofSize: 10)
        let noteAttr: [NSAttributedString.Key: Any] = [.font: noteFont, .foregroundColor: NSColor.darkGray]
        let note_ns = notes as NSString

        // Simple line wrapping (simplified for Phase 5)
        let yPos = origin.y - 14
        note_ns.draw(
            in: CGRect(x: origin.x, y: yPos - 40, width: maxWidth, height: 40),
            withAttributes: noteAttr
        )

        return yPos - 40
    }

    private func drawImageWithLabel(
        in context: CGContext,
        image: NSImage,
        label: String,
        rect: CGRect
    ) {
        // Draw label
        let labelFont = NSFont.systemFont(ofSize: 10)
        let labelAttr: [NSAttributedString.Key: Any] = [.font: labelFont]
        let label_ns = label as NSString
        label_ns.draw(at: CGPoint(x: rect.minX, y: rect.maxY + 4), withAttributes: labelAttr)

        // Draw image
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: rect)
        }
    }

    private func drawCurveReference(
        in context: CGContext,
        fileName: String,
        at origin: CGPoint
    ) -> CGFloat {
        let text = "Curve File: \(fileName)"
        let font = NSFont.systemFont(ofSize: 9)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.gray]
        let ns = text as NSString
        ns.draw(at: origin, withAttributes: attr)

        return origin.y - 12
    }

    private func processFieldLabels(attempt: PrintAttempt) -> [(String, String)] {
        var labels: [(String, String)] = [
            ("Paper", attempt.paper),
            ("Outcome", attempt.outcome.displayName)
        ]

        // Add type-specific fields
        switch attempt.printType {
        case .platinumPalladium:
            if let pt = attempt.processSpecificFields["platinumPercent"]?.value as? Double {
                labels.append(("Platinum %", String(format: "%.0f", pt)))
            }
            if let pd = attempt.processSpecificFields["palladiumPercent"]?.value as? Double {
                labels.append(("Palladium %", String(format: "%.0f", pd)))
            }

        case .cyanotype:
            if let exp = attempt.processSpecificFields["exposureTime"]?.value as? String {
                labels.append(("Exposure Time", exp + " min"))
            }

        case .inkjetColor:
            if let cs = attempt.processSpecificFields["colorSpace"]?.value as? String {
                labels.append(("Color Space", cs))
            }

        case .silverGelatinDarkroom:
            if let pb = attempt.processSpecificFields["paperBrand"]?.value as? String {
                labels.append(("Paper Brand", pb))
            }
            if let temp = attempt.processSpecificFields["tempC"]?.value as? String {
                labels.append(("Dev Temp", temp + "°C"))
            }

        default:
            break
        }

        return labels
    }
}
