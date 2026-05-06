//
//  GeocoderServiceTests.swift
//  HoehnPhotosOrganizerTests
//

import Testing
@testable import HoehnPhotosOrganizer

// Network-required tests are disabled by default. Mark live: true in environment to run.
@Suite(.disabled("requires live network"))
struct GeocoderServiceNetworkTests {

    @Test func testReverseGeocodeKnownCoordinatesReturnsCity() async throws {
        // META-5: coordinates 51.5, -0.1 (London) return country non-empty, city non-empty
        let service = GeocoderService()
        let info = try await service.reverseGeocode(latitude: 51.5, longitude: -0.1)
        #expect(!info.country.isEmpty, "Should return non-empty country for London coordinates")
        #expect(!info.city.isEmpty, "Should return non-empty city for London coordinates")
    }
}

struct GeocoderServiceTests {

    @Test func testLocationInfoDefaultsToEmptyStrings() throws {
        // LocationInfo should be constructable with empty strings (no optionals)
        let info = LocationInfo(country: "", region: "", city: "")
        #expect(info.country == "")
        #expect(info.region == "")
        #expect(info.city == "")
    }

    @Test func testCacheHitReturnsSeedValue() async throws {
        // seedCacheForTesting seeds the actor-isolated cache so the second call for the
        // same coordinates returns the cached value without touching CLGeocoder.
        let service = GeocoderService()
        let seeded = LocationInfo(country: "UK", region: "England", city: "London")
        await service.seedCacheForTesting(latitude: 51.5, longitude: -0.1, info: seeded)

        let result = try await service.reverseGeocode(latitude: 51.5, longitude: -0.1)
        #expect(result.city == "London", "Cache hit must return seeded city")
        #expect(result.country == "UK", "Cache hit must return seeded country")
        #expect(result.region == "England", "Cache hit must return seeded region")
    }

    @Test func testDifferentCoordinatesAreNotSharedInCache() async throws {
        // Two distinct coordinates must not share a cache entry.
        let service = GeocoderService()
        await service.seedCacheForTesting(latitude: 51.5, longitude: -0.1,
                                          info: LocationInfo(country: "UK", region: "England", city: "London"))
        await service.seedCacheForTesting(latitude: 48.8, longitude: 2.35,
                                          info: LocationInfo(country: "FR", region: "Île-de-France", city: "Paris"))

        let london = try await service.reverseGeocode(latitude: 51.5, longitude: -0.1)
        let paris  = try await service.reverseGeocode(latitude: 48.8, longitude: 2.35)
        #expect(london.city == "London")
        #expect(paris.city == "Paris")
    }

}
