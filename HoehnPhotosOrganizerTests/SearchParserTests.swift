import Testing
@testable import HoehnPhotosOrganizer

struct SearchParserTests {

    @Test
    func testKeywordFallbackMatchesLocation() async throws {
        // SRCH-5: with Ollama unavailable, query 'photos from England' matches location filter 'England'
        let intent = SearchParser.parse(query: "photos from England")
        #expect(intent.filter.location == "England")
    }

    @Test
    func testKeywordFallbackMatchesDateRange() async throws {
        // SRCH-5: query '2024 photos' falls back to year=2024 filter
        let intent = SearchParser.parse(query: "2024 photos")
        #expect(intent.filter.yearFrom == 2024)
        #expect(intent.filter.yearTo == 2024)
    }

    @Test
    func testKeywordFallbackMatchesFileType() async throws {
        // SRCH-5: query 'show me DNGs' falls back to fileType=DNG filter
        let intent = SearchParser.parse(query: "show me DNGs")
        #expect(intent.filter.fileType == "dng")
    }
}
