import XCTest
import AppKit
@testable import HoehnPhotosOrganizer

final class ICCProfileAndSoftProofTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestImage(width: Int = 10, height: Int = 10, gray: CGFloat = 0.5) -> NSImage {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor(white: gray, alpha: 1).setFill()
        NSRect(origin: .zero, size: img.size).fill()
        img.unlockFocus()
        return img
    }

    private func makeCorrection(
        profilePath: String = "/tmp/test.icc",
        profileDisplayName: String = "Test Profile",
        printer: String = "Test Printer",
        renderingIntent: String = "relative",
        brightnessOffset: Double = 0.0,
        saturationOffset: Double = 0.0,
        date: Date = Date(),
        sourceJobID: String? = nil,
        notes: String = ""
    ) -> ICCProfileCorrection {
        ICCProfileCorrection(
            id: UUID(),
            profilePath: profilePath,
            profileDisplayName: profileDisplayName,
            printer: printer,
            renderingIntent: renderingIntent,
            brightnessOffset: brightnessOffset,
            saturationOffset: saturationOffset,
            dateCalibrated: date,
            sourceJobID: sourceJobID,
            notes: notes
        )
    }

    private func encodeDecodeRoundTrip(_ correction: ICCProfileCorrection) throws -> ICCProfileCorrection {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(correction)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ICCProfileCorrection.self, from: data)
    }

    // MARK: - ICC Profile Discovery (real filesystem)

    func test_discoverICCProfiles_returnsNonEmpty() {
        let urls = ICCProfileService.discoverICCProfiles()
        XCTAssertFalse(urls.isEmpty, "Expected at least some ICC profiles on this Mac")
    }

    func test_discoverICCProfiles_allHaveIccOrIcmExtension() {
        let urls = ICCProfileService.discoverICCProfiles()
        for url in urls {
            let ext = url.pathExtension.lowercased()
            XCTAssertTrue(
                ext == "icc" || ext == "icm",
                "Profile \(url.lastPathComponent) has unexpected extension: \(ext)"
            )
        }
    }

    func test_discoverGroupedProfiles_hasGroups() {
        let groups = ICCProfileService.discoverGroupedICCProfiles()
        XCTAssertFalse(groups.isEmpty, "Expected at least 1 ICC profile group")
    }

    func test_discoverGroupedProfiles_groupsHaveNames() {
        let groups = ICCProfileService.discoverGroupedICCProfiles()
        for group in groups {
            XCTAssertFalse(group.name.isEmpty, "Group name must not be empty")
        }
    }

    func test_discoverGroupedProfiles_profilesHaveDisplayNames() {
        let groups = ICCProfileService.discoverGroupedICCProfiles()
        for group in groups {
            for profile in group.profiles {
                XCTAssertFalse(
                    profile.displayName.isEmpty,
                    "Profile in group '\(group.name)' has an empty displayName"
                )
            }
        }
    }

    func test_discoverGroupedProfiles_systemProfilesExist() {
        let groups = ICCProfileService.discoverGroupedICCProfiles()
        let systemGroup = groups.first { $0.name == "ColorSync System" }
        XCTAssertNotNil(systemGroup, "Expected a 'ColorSync System' group")
        XCTAssertFalse(systemGroup?.profiles.isEmpty ?? true, "ColorSync System group should have profiles")
    }

    func test_discoverGroupedProfiles_sRGBExists() {
        let groups = ICCProfileService.discoverGroupedICCProfiles()
        let allProfiles = groups.flatMap(\.profiles)
        let hasSRGB = allProfiles.contains { $0.displayName.contains("sRGB") }
        XCTAssertTrue(hasSRGB, "Expected at least one profile containing 'sRGB' in its display name")
    }

    // MARK: - ICC Profile Model

    func test_iccProfile_idIsURL() {
        let url = URL(fileURLWithPath: "/tmp/test.icc")
        let profile = ICCProfile(url: url, displayName: "Test", groupName: "Test Group")
        XCTAssertEqual(profile.id, url)
    }

    func test_iccProfile_equatable() {
        let url = URL(fileURLWithPath: "/tmp/same.icc")
        let a = ICCProfile(url: url, displayName: "A", groupName: "Group A")
        let b = ICCProfile(url: url, displayName: "B", groupName: "Group B")
        XCTAssertEqual(a, b, "ICCProfiles with the same URL should be equal")
    }

    func test_iccProfileGroup_idIsName() {
        let group = ICCProfileGroup(name: "My Printers", profiles: [])
        XCTAssertEqual(group.id, "My Printers")
    }

    // MARK: - Soft Proof Service

    func test_softProof_invalidProfile_throwsInvalidProfile() async {
        let service = SoftProofService()
        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent_profile_\(UUID()).icc")
        let image = makeTestImage()

        do {
            _ = try await service.renderSoftProof(
                image: image,
                profileURL: fakeURL,
                intent: .defaultIntent,
                blackPointCompensation: false
            )
            XCTFail("Expected SoftProofError.invalidProfile to be thrown")
        } catch let error as SoftProofService.SoftProofError {
            if case .invalidProfile = error {
                // expected
            } else {
                XCTFail("Expected invalidProfile, got \(error)")
            }
        } catch {
            // Data(contentsOf:) throws for non-existent file, which is acceptable
        }
    }

    func test_softProof_validSystemProfile_returnsImage() async throws {
        let service = SoftProofService()
        let profileURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("sRGB system profile not found at expected path")
        }

        let source = makeTestImage()
        let result = try await service.renderSoftProof(
            image: source,
            profileURL: profileURL,
            intent: .defaultIntent,
            blackPointCompensation: false
        )
        XCTAssertNotNil(result)
    }

    func test_softProof_resultImageHasSameDimensions() async throws {
        let service = SoftProofService()
        let profileURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("sRGB system profile not found at expected path")
        }

        let source = makeTestImage(width: 20, height: 15)
        let result = try await service.renderSoftProof(
            image: source,
            profileURL: profileURL,
            intent: .defaultIntent,
            blackPointCompensation: false
        )

        guard let tiff = result.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            XCTFail("Could not get bitmap rep from result")
            return
        }

        // Compare pixel dimensions from the source bitmap
        guard let srcTiff = source.tiffRepresentation,
              let srcRep = NSBitmapImageRep(data: srcTiff) else {
            XCTFail("Could not get bitmap rep from source")
            return
        }

        XCTAssertEqual(rep.pixelsWide, srcRep.pixelsWide, "Width mismatch")
        XCTAssertEqual(rep.pixelsHigh, srcRep.pixelsHigh, "Height mismatch")
    }

    func test_softProof_relativeColorimetricIntent() async throws {
        let service = SoftProofService()
        let profileURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("sRGB system profile not found at expected path")
        }

        let source = makeTestImage()
        _ = try await service.renderSoftProof(
            image: source,
            profileURL: profileURL,
            intent: .relativeColorimetric,
            blackPointCompensation: false
        )
    }

    func test_softProof_perceptualIntent() async throws {
        let service = SoftProofService()
        let profileURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")

        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw XCTSkip("sRGB system profile not found at expected path")
        }

        let source = makeTestImage()
        _ = try await service.renderSoftProof(
            image: source,
            profileURL: profileURL,
            intent: .perceptual,
            blackPointCompensation: false
        )
    }

    // MARK: - ICC Profile Correction Store

    func test_correctionStore_saveAndRetrieve() async throws {
        let store = ICCProfileCorrectionStore.shared
        let path = "/tmp/test_save_retrieve_\(UUID()).icc"
        let correction = makeCorrection(
            profilePath: path,
            brightnessOffset: 1.5,
            saturationOffset: -0.3
        )

        try await store.save(correction)
        let retrieved = try await store.correction(forProfilePath: path)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.profilePath, path)
        XCTAssertEqual(retrieved?.brightnessOffset, 1.5)
        XCTAssertEqual(retrieved?.saturationOffset, -0.3)

        // Clean up
        try await store.remove(forProfilePath: path)
    }

    func test_correctionStore_overwritesByPath() async throws {
        let store = ICCProfileCorrectionStore.shared
        let path = "/tmp/test_overwrite_\(UUID()).icc"

        let first = makeCorrection(profilePath: path, brightnessOffset: 1.0)
        let second = makeCorrection(profilePath: path, brightnessOffset: 2.0)

        try await store.save(first)
        try await store.save(second)

        let retrieved = try await store.correction(forProfilePath: path)
        XCTAssertEqual(retrieved?.brightnessOffset, 2.0, "Second save should overwrite the first")

        // Clean up
        try await store.remove(forProfilePath: path)
    }

    func test_correctionStore_removeClearsEntry() async throws {
        let store = ICCProfileCorrectionStore.shared
        let path = "/tmp/test_remove_\(UUID()).icc"

        try await store.save(makeCorrection(profilePath: path))
        try await store.remove(forProfilePath: path)

        let retrieved = try await store.correction(forProfilePath: path)
        XCTAssertNil(retrieved, "Correction should be nil after removal")
    }

    func test_correctionStore_allCorrections_returnsAll() async throws {
        let store = ICCProfileCorrectionStore.shared
        let paths = (0..<3).map { "/tmp/test_all_\(UUID())_\($0).icc" }

        for path in paths {
            try await store.save(makeCorrection(profilePath: path))
        }

        let all = try await store.allCorrections()
        for path in paths {
            XCTAssertTrue(all.contains { $0.profilePath == path }, "Missing correction for \(path)")
        }

        // Clean up
        for path in paths {
            try await store.remove(forProfilePath: path)
        }
    }

    func test_correctionStore_correctionCodable() throws {
        let original = makeCorrection(
            profilePath: "/Library/Printers/test.icc",
            profileDisplayName: "Canon Pro-1000",
            printer: "Canon iPF Pro-1000",
            renderingIntent: "perceptual",
            brightnessOffset: -0.5,
            saturationOffset: 1.2,
            sourceJobID: "job-42",
            notes: "Calibrated with i1Pro3"
        )

        let decoded = try encodeDecodeRoundTrip(original)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.profilePath, original.profilePath)
        XCTAssertEqual(decoded.profileDisplayName, original.profileDisplayName)
        XCTAssertEqual(decoded.printer, original.printer)
        XCTAssertEqual(decoded.renderingIntent, original.renderingIntent)
        XCTAssertEqual(decoded.brightnessOffset, original.brightnessOffset)
        XCTAssertEqual(decoded.saturationOffset, original.saturationOffset)
        XCTAssertEqual(decoded.sourceJobID, original.sourceJobID)
        XCTAssertEqual(decoded.notes, original.notes)
    }

    func test_correctionStore_datePreserved() throws {
        let now = Date()
        let original = makeCorrection(date: now)
        let decoded = try encodeDecodeRoundTrip(original)

        // ISO8601 truncates to seconds, so compare within 1 second
        XCTAssertEqual(
            decoded.dateCalibrated.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 1.0,
            "Date should survive ISO8601 encode/decode within 1s"
        )
    }

    // MARK: - ICCProfileCorrection Model

    func test_iccProfileCorrection_codingKeys() throws {
        let correction = makeCorrection()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(correction)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let expectedKeys: Set<String> = [
            "id", "profile_path", "profile_display_name", "printer",
            "rendering_intent", "brightness_offset", "saturation_offset",
            "date_calibrated", "source_job_id", "notes"
        ]

        for key in expectedKeys {
            // source_job_id may be absent if nil
            if key == "source_job_id" && correction.sourceJobID == nil { continue }
            XCTAssertTrue(
                json.keys.contains(key),
                "Expected snake_case key '\(key)' in JSON output, got keys: \(json.keys.sorted())"
            )
        }

        // Verify camelCase keys are NOT present
        XCTAssertNil(json["profilePath"], "Should use snake_case, not camelCase")
        XCTAssertNil(json["renderingIntent"], "Should use snake_case, not camelCase")
        XCTAssertNil(json["brightnessOffset"], "Should use snake_case, not camelCase")
    }

    func test_iccProfileCorrection_allRenderingIntents() throws {
        let intents = ["relative", "perceptual", "absolute", "saturation"]

        for intent in intents {
            let original = makeCorrection(renderingIntent: intent)
            let decoded = try encodeDecodeRoundTrip(original)
            XCTAssertEqual(
                decoded.renderingIntent, intent,
                "Rendering intent '\(intent)' should survive roundtrip"
            )
        }
    }
}
