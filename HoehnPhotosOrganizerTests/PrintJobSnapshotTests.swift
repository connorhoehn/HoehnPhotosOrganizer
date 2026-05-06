import Testing
@testable import HoehnPhotosOrganizer

struct PrintJobSnapshotTests {

    private func makeSnapshot(images: [PrintJobSnapshot.ImagePlacement] = []) -> PrintJobSnapshot {
        PrintJobSnapshot(
            paperWidth: 8.5, paperHeight: 11.0,
            isPortrait: true,
            marginLeft: 0.5, marginRight: 0.5, marginTop: 0.75, marginBottom: 0.75,
            templateName: "Single Image",
            templateJSON: nil,
            colorMgmt: "ColorSync Managed",
            iccProfilePath: "/Library/ColorSync/Profiles/Test.icc",
            iccProfileName: "Test Profile",
            renderingIntent: "relative",
            blackPointCompensation: true,
            printerName: "Canon Pro-1000",
            isNegative: false,
            is16Bit: true,
            simulateInkBlack: false,
            flipEmulsion: false,
            softProofEnabled: false,
            softProofProfilePath: nil,
            softProofIntent: nil,
            softProofBPC: false,
            images: images,
            printAttemptId: "attempt-abc"
        )
    }

    // MARK: - Round-trip

    @Test func testJsonStringAndDecodeRoundTrip() throws {
        let original = makeSnapshot()
        let json = try #require(original.jsonString(), "jsonString() must return non-nil for a valid snapshot")
        let decoded = try #require(PrintJobSnapshot.decode(from: json), "decode(from:) must succeed on its own encoded output")

        #expect(decoded.paperWidth == 8.5)
        #expect(decoded.paperHeight == 11.0)
        #expect(decoded.renderingIntent == "relative")
        #expect(decoded.iccProfileName == "Test Profile")
        #expect(decoded.printAttemptId == "attempt-abc")
        #expect(decoded.blackPointCompensation == true)
        #expect(decoded.is16Bit == true)
    }

    @Test func testImagePlacementsPreservedThroughRoundTrip() throws {
        let placement = PrintJobSnapshot.ImagePlacement(
            photoAssetId: "asset-001",
            canonicalName: "IMG_001.NEF",
            positionX: 1.0, positionY: 2.0,
            width: 6.0, height: 4.0,
            rotation: 0.0,
            aspectRatioLocked: true,
            borderWidthInches: 0.125,
            borderIsWhite: true,
            iccProfilePath: nil,
            brightnessOffset: 0.1,
            saturationOffset: nil,
            tileLabel: nil,
            groupLabel: nil
        )
        let snapshot = makeSnapshot(images: [placement])
        let json = try #require(snapshot.jsonString())
        let decoded = try #require(PrintJobSnapshot.decode(from: json))

        #expect(decoded.images.count == 1)
        #expect(decoded.images[0].photoAssetId == "asset-001")
        #expect(decoded.images[0].canonicalName == "IMG_001.NEF")
        #expect(abs((decoded.images[0].brightnessOffset ?? 0) - 0.1) < 1e-9)
        #expect(decoded.images[0].saturationOffset == nil)
    }

    // MARK: - decode guard cases

    @Test func testDecodeFromNilStringReturnsNil() {
        #expect(PrintJobSnapshot.decode(from: nil) == nil,
                "decode(from: nil) must return nil")
    }

    @Test func testDecodeFromInvalidJSONReturnsNil() {
        #expect(PrintJobSnapshot.decode(from: "not json") == nil)
        #expect(PrintJobSnapshot.decode(from: "{\"paperWidth\": \"wrong_type\"}") == nil,
                "Type mismatch must cause decode to return nil")
    }

    @Test func testOptionalFieldsRemainNilAfterRoundTrip() throws {
        var snapshot = makeSnapshot()
        snapshot.templateName = nil
        snapshot.iccProfilePath = nil
        snapshot.printerName = nil
        snapshot.printAttemptId = nil

        let json = try #require(snapshot.jsonString())
        let decoded = try #require(PrintJobSnapshot.decode(from: json))

        #expect(decoded.templateName == nil)
        #expect(decoded.iccProfilePath == nil)
        #expect(decoded.printerName == nil)
        #expect(decoded.printAttemptId == nil)
    }
}
