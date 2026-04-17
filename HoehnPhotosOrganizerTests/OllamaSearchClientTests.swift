import Testing
@testable import HoehnPhotosOrganizer

@Suite(.disabled("requires Anthropic API key"))
struct SearchClientTests {

    @Test
    func testParsesEnglandLocationQuery() async throws {
        // SRCH-1: query 'photos from England' → SearchIntentRaw with location='England'
        let client = SearchClient()
        let intent = try await client.parse(query: "photos from England")
        #expect(intent.filter.location == "England")
    }

    @Test
    func testParsesDateRangeQuery() async throws {
        // SRCH-1: query 'photos from 2024' → SearchIntentRaw with yearFrom=2024, yearTo=2024
        let client = SearchClient()
        let intent = try await client.parse(query: "photos from 2024")
        #expect(intent.filter.yearFrom == 2024)
        #expect(intent.filter.yearTo == 2024)
    }

    @Test
    func testParsesPersonName() async throws {
        let client = SearchClient()
        let intent = try await client.parse(query: "pictures of Morgan", knownPeople: ["Morgan", "Connor"])
        #expect(intent.personNames?.contains("Morgan") == true)
    }
}
