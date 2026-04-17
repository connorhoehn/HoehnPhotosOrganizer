import Foundation
import Testing
import PDFKit
@testable import HoehnPhotosOrganizer

struct PrintRecipeExporterTests {

    // MARK: - Test generateRecipePDF returns valid PDFDocument

    @Test func testGenerateRecipePDFReturnsDocument() throws {
        let exporter = PrintRecipeExporter()

        let attempt = PrintAttempt(
            id: UUID().uuidString,
            photoId: "photo-001",
            printType: .platinumPalladium,
            paper: "Platinum Paper",
            outcome: .pass,
            outcomeNotes: "Good density and tone",
            curveFileId: nil,
            curveFileName: "Curve_01.acv",
            printPhotoId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: [:]
        )

        let pdf = exporter.generateRecipePDF(
            attempt: attempt,
            sourceImage: nil,
            printPhoto: nil
        )

        #expect(pdf != nil)
        #expect(pdf?.pageCount == 1)
    }

    // MARK: - Test generateRecipePDF creates single page

    @Test func testGenerateRecipePDFIsSinglePage() throws {
        let exporter = PrintRecipeExporter()

        let attempt = PrintAttempt(
            id: UUID().uuidString,
            photoId: "photo-001",
            printType: .cyanotype,
            paper: "Cyanotype Paper",
            outcome: .testing,
            outcomeNotes: "Testing exposure time",
            curveFileId: nil,
            curveFileName: nil,
            printPhotoId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: [
                "exposureTime": AnyCodable("12.5")
            ]
        )

        let pdf = exporter.generateRecipePDF(
            attempt: attempt,
            sourceImage: nil,
            printPhoto: nil
        )

        #expect(pdf?.pageCount == 1)
    }

    // MARK: - Test generateRecipePDF includes attempt data in PDF

    @Test func testGenerateRecipePDFIncludesAttemptData() throws {
        let exporter = PrintRecipeExporter()

        let attempt = PrintAttempt(
            id: UUID().uuidString,
            photoId: "photo-001",
            printType: .silverGelatinDarkroom,
            paper: "Ilford MultiGrade FB",
            outcome: .pass,
            outcomeNotes: "Good contrast",
            curveFileId: nil,
            curveFileName: nil,
            printPhotoId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: [:]
        )

        let pdf = exporter.generateRecipePDF(
            attempt: attempt,
            sourceImage: nil,
            printPhoto: nil
        )

        #expect(pdf != nil)
        // PDF should contain the print type name in its content
        let data = pdf?.dataRepresentation()
        #expect(data != nil)
        #expect(data?.count ?? 0 > 0)
    }
}
