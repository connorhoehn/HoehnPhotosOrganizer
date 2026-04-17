import XCTest
import MapKit
@testable import HoehnPhotosOrganizer

// MARK: - MapViewTests

/// Unit tests for MapPhotoViewModel and PhotoAnnotation.
///
/// Tests run fully in-process with an in-memory AppDatabase — no actual MapKit
/// rendering is performed, so all five tests can execute in the test host.
@MainActor
final class MapViewTests: XCTestCase {

    // MARK: Helpers

    /// Build a minimal in-memory AppDatabase for test isolation.
    private func makeDB() throws -> AppDatabase {
        try AppDatabase.makeInMemory()
    }

    /// Insert a PhotoAsset with GPS coordinates encoded in raw_exif_json.
    private func insertGeotaggedPhoto(
        db: AppDatabase,
        canonicalName: String,
        latitude: Double,
        longitude: Double
    ) async throws -> PhotoAsset {
        let repo = PhotoRepository(db: db)
        var asset = PhotoAsset.new(
            canonicalName: canonicalName,
            role: .original,
            filePath: "/test/\(canonicalName)",
            fileSize: 1_000
        )
        let exifPayload = ["latitude": latitude, "longitude": longitude]
        let exifData = try JSONEncoder().encode(exifPayload)
        asset.rawExifJson = String(data: exifData, encoding: .utf8)
        try await repo.upsert(asset)
        return asset
    }

    /// Insert a PhotoAsset with NO GPS data (no raw_exif_json).
    private func insertPhotoWithoutGPS(
        db: AppDatabase,
        canonicalName: String
    ) async throws -> PhotoAsset {
        let repo = PhotoRepository(db: db)
        let asset = PhotoAsset.new(
            canonicalName: canonicalName,
            role: .original,
            filePath: "/test/\(canonicalName)",
            fileSize: 1_000
        )
        try await repo.upsert(asset)
        return asset
    }

    // MARK: - Test 1: Annotations created for geotagged photos

    func testMapViewDisplaysPhotoAnnotations() async throws {
        let db = try makeDB()
        let repo = PhotoRepository(db: db)

        // Insert three photos with GPS
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "A.jpg", latitude: 37.7749, longitude: -122.4194)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "B.jpg", latitude: 48.8566, longitude:   2.3522)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "C.jpg", latitude: 35.6762, longitude: 139.6503)

        // Load via view model
        let vm = await MapPhotoViewModel(photoRepo: repo)
        await vm.loadPhotos()

        let annotations = await vm.photoAnnotations
        XCTAssertEqual(annotations.count, 3, "All three geotagged photos should produce annotations")

        let names = annotations.map { $0.displayName }.sorted()
        XCTAssertEqual(names, ["A.jpg", "B.jpg", "C.jpg"])

        // Coordinates round-trip correctly
        let sfAnnotation = annotations.first { $0.displayName == "A.jpg" }
        XCTAssertNotNil(sfAnnotation)
        XCTAssertEqual(sfAnnotation!.coordinate.latitude,  37.7749, accuracy: 0.0001)
        XCTAssertEqual(sfAnnotation!.coordinate.longitude, -122.4194, accuracy: 0.0001)
    }

    // MARK: - Test 2: Clustering identifier grouping at low zoom levels

    /// MapKit native clustering groups annotations that share the same clusteringIdentifier
    /// when they are within ~40 pt of each other at the current zoom level.
    /// This test verifies the view model correctly builds annotation objects that
    /// are eligible for clustering (same-type, valid coordinates, stable IDs).
    func testClusteringGroupsNearbyPhotos() async throws {
        let db = try makeDB()
        let repo = PhotoRepository(db: db)

        // Insert photos clustered near San Francisco (< 1 km apart)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "SF1.jpg", latitude: 37.7749,  longitude: -122.4194)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "SF2.jpg", latitude: 37.7751,  longitude: -122.4196)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "SF3.jpg", latitude: 37.7748,  longitude: -122.4190)
        // One outlier far away (Paris)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "Paris.jpg", latitude: 48.8566, longitude: 2.3522)

        let vm = await MapPhotoViewModel(photoRepo: repo)
        await vm.loadPhotos()

        let annotations = await vm.photoAnnotations
        XCTAssertEqual(annotations.count, 4, "All geotagged photos should have annotations")

        // At a wide zoom level covering San Francisco only, all SF photos are visible
        let sfRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )

        let vm2 = await MapPhotoViewModel(photoRepo: repo)
        await vm2.loadPhotos()
        await vm2.updateVisiblePhotos(for: sfRegion)

        let visible = await vm2.visibleAnnotations
        // All three SF annotations should be visible; Paris should be excluded
        XCTAssertEqual(visible.count, 3, "Wide SF region should show 3 SF annotations")
        XCTAssertFalse(visible.contains { $0.displayName == "Paris.jpg" },
                       "Paris annotation should not be visible in SF region")

        // MapKit clusters nearby annotations at runtime — we verify all annotations have
        // valid, distinct coordinates (prerequisite for native clustering to activate).
        let uniqueCoordinates = Set(annotations.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" })
        XCTAssertEqual(uniqueCoordinates.count, annotations.count,
                       "Each annotation must have a unique coordinate for MapKit clustering")
    }

    // MARK: - Test 3: Tap cluster filters results to region

    func testTapClusterFiltersResults() async throws {
        let db = try makeDB()
        let repo = PhotoRepository(db: db)

        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "X1.jpg", latitude: 40.7128, longitude: -74.0060)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "X2.jpg", latitude: 40.7138, longitude: -74.0070)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "Y1.jpg", latitude: 51.5074, longitude:  -0.1278)

        let vm = await MapPhotoViewModel(photoRepo: repo)
        await vm.loadPhotos()

        let annotations = await vm.photoAnnotations
        let nycAnnotation = annotations.first { $0.displayName == "X1.jpg" }!

        // Simulate tapping an annotation and choosing "Filter to region"
        let tapRegion = await vm.regionForAnnotation(nycAnnotation)
        await vm.selectRegion(tapRegion)

        let selectedRegion = await vm.selectedRegion
        XCTAssertNotNil(selectedRegion, "selectedRegion must be set after selectRegion(_:)")

        let filtered = await vm.filteredAnnotations
        // The 5 km region around X1.jpg should include X1 and X2 but not Y1 (London)
        XCTAssertTrue(filtered.contains { $0.displayName == "X1.jpg" })
        XCTAssertFalse(filtered.contains { $0.displayName == "Y1.jpg" },
                       "London photo should be filtered out when NYC region is selected")
    }

    // MARK: - Test 4: Photos without GPS do not crash and are excluded

    func testMapViewHandlesPhotosWithoutLocation() async throws {
        let db = try makeDB()
        let repo = PhotoRepository(db: db)

        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "WithGPS.jpg",   latitude: 48.8566, longitude: 2.3522)
        _ = try await insertPhotoWithoutGPS(db: db, canonicalName: "NoGPS.dng")
        _ = try await insertPhotoWithoutGPS(db: db, canonicalName: "NoGPS2.tif")

        let vm = await MapPhotoViewModel(photoRepo: repo)
        await vm.loadPhotos()

        let annotations = await vm.photoAnnotations
        // Only the geotagged photo should appear; no crash from missing GPS
        XCTAssertEqual(annotations.count, 1,
                       "Only photos with valid GPS should produce annotations")
        XCTAssertEqual(annotations.first?.displayName, "WithGPS.jpg")

        let error = await vm.loadError
        XCTAssertNil(error, "No load error should occur when some photos lack GPS")
    }

    // MARK: - Test 5: Zooming in updates visibleAnnotations via region change

    func testMapViewRegionUpdatesOnZoom() async throws {
        let db = try makeDB()
        let repo = PhotoRepository(db: db)

        // Two tight clusters: NYC and London
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "NYC1.jpg", latitude: 40.7128, longitude: -74.0060)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "NYC2.jpg", latitude: 40.7130, longitude: -74.0062)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "LON1.jpg", latitude: 51.5074, longitude:  -0.1278)
        _ = try await insertGeotaggedPhoto(db: db, canonicalName: "LON2.jpg", latitude: 51.5076, longitude:  -0.1280)

        let vm = await MapPhotoViewModel(photoRepo: repo)
        await vm.loadPhotos()

        // Wide region (world view) — all four annotations visible
        let worldRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.0, longitude: -37.0),
            span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 180)
        )
        await vm.updateVisiblePhotos(for: worldRegion)
        let allVisible = await vm.visibleAnnotations
        XCTAssertEqual(allVisible.count, 4, "World region should include all 4 geotagged photos")

        // Zoom into NYC region only
        let nycZoomedRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        await vm.updateVisiblePhotos(for: nycZoomedRegion)
        let nycVisible = await vm.visibleAnnotations
        XCTAssertEqual(nycVisible.count, 2, "NYC-zoomed region should show only 2 NYC photos")
        XCTAssertTrue(nycVisible.allSatisfy { $0.displayName.hasPrefix("NYC") },
                      "Only NYC annotations should be visible after zoom-in")
    }
}
