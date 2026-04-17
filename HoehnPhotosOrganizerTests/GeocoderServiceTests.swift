//
//  GeocoderServiceTests.swift
//  HoehnPhotosOrganizerTests
//

import Testing
@testable import HoehnPhotosOrganizer

// Network-required tests are disabled by default. Mark live: true in environment to run.
@Suite(.disabled("requires live network"))
struct GeocoderServiceTests {

    @Test func testReverseGeocodeKnownCoordinatesReturnsCity() async throws {
        // META-5: coordinates 51.5, -0.1 (London) return country non-empty, city non-empty
        let service = GeocoderService()
        let info = try await service.reverseGeocode(latitude: 51.5, longitude: -0.1)
        #expect(!info.country.isEmpty, "Should return non-empty country for London coordinates")
        #expect(!info.city.isEmpty, "Should return non-empty city for London coordinates")
    }

    @Test func testLocationInfoDefaultsToEmptyStrings() throws {
        // LocationInfo should be constructable with empty strings (no optionals)
        let info = LocationInfo(country: "", region: "", city: "")
        #expect(info.country == "")
        #expect(info.region == "")
        #expect(info.city == "")
    }

}
