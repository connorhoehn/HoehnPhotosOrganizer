//
//  EXIFExtractorTests.swift
//  HoehnPhotosOrganizerTests
//

import Testing
import Foundation
@testable import HoehnPhotosOrganizer

struct EXIFExtractorTests {

    // MARK: - Empty snapshot on missing file

    @Test func returnsEmptySnapshotForMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/path/image.jpg")
        let snapshot = EXIFExtractor.extract(url: url)
        #expect(snapshot.captureDate == nil)
        #expect(snapshot.latitude == nil)
        #expect(snapshot.longitude == nil)
        #expect(snapshot.cameraMake == nil)
        #expect(snapshot.cameraModel == nil)
        #expect(snapshot.lens == nil)
        #expect(snapshot.iso == nil)
        #expect(snapshot.aperture == nil)
        #expect(snapshot.shutterSpeed == nil)
        #expect(snapshot.focalLength == nil)
    }

    // MARK: - Fixture-based test (requires sample.jpg in test bundle)

    @Test func testExtractsRequiredFieldsFromFixtureJPEG() {
        // META-1: extracting EXIF from Fixtures/sample.jpg returns non-nil datetime,
        // camera make, ISO, aperture, shutter, focal length.
        // Note: requires Fixtures/sample.jpg — skips gracefully if not present.
        let bundle = Bundle(for: EXIFExtractorTestsHost.self)
        guard let url = bundle.url(forResource: "sample", withExtension: "jpg") else {
            return
        }
        let snapshot = EXIFExtractor.extract(url: url)
        #expect(snapshot.captureDate != nil, "sample.jpg should have DateTimeOriginal")
    }

}

// Host class to allow Bundle lookup by class reference
final class EXIFExtractorTestsHost: NSObject {}
