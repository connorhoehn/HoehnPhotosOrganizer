import Testing
@testable import HoehnPhotosOrganizer

struct SearchParserTests {

    // MARK: - Location

    @Test
    func testKeywordFallbackMatchesLocation() async throws {
        // SRCH-5: with Ollama unavailable, query 'photos from England' matches location filter 'England'
        let intent = SearchParser.parse(query: "photos from England")
        #expect(intent.filter.location == "England")
    }

    @Test
    func testLocationSetsPreferMapView() {
        // Queries with a resolved location should prefer the map view.
        let intent = SearchParser.parse(query: "photos from Japan")
        #expect(intent.preferMapView == true, "A location match must set preferMapView = true")
    }

    @Test
    func testNoLocationDoesNotSetPreferMapView() {
        let intent = SearchParser.parse(query: "show me keepers")
        #expect(intent.preferMapView == false, "No location match must leave preferMapView = false")
    }

    // MARK: - Year

    @Test
    func testKeywordFallbackMatchesDateRange() async throws {
        // SRCH-5: query '2024 photos' falls back to year=2024 filter
        let intent = SearchParser.parse(query: "2024 photos")
        #expect(intent.filter.yearFrom == 2024)
        #expect(intent.filter.yearTo == 2024)
    }

    // MARK: - File type

    @Test
    func testKeywordFallbackMatchesFileType() async throws {
        // SRCH-5: query 'show me DNGs' falls back to fileType=DNG filter
        let intent = SearchParser.parse(query: "show me DNGs")
        #expect(intent.filter.fileType == "dng")
    }

    // MARK: - Curation state

    @Test
    func testCurationStateKeeper() {
        let intent = SearchParser.parse(query: "show keepers")
        #expect(intent.filter.curationState == CurationState.keeper.rawValue)
    }

    @Test
    func testCurationStateArchive() {
        let intent = SearchParser.parse(query: "archived photos")
        #expect(intent.filter.curationState == CurationState.archive.rawValue)
    }

    @Test
    func testCurationStateReject() {
        let intent = SearchParser.parse(query: "find rejects")
        #expect(intent.filter.curationState == CurationState.rejected.rawValue)
    }

    // MARK: - Time of day

    @Test
    func testTimeOfDayGoldenHour() {
        let intent = SearchParser.parse(query: "golden hour shots")
        #expect(intent.filter.timeOfDay == TimeOfDay.goldenHour.rawValue)
    }

    @Test
    func testTimeOfDayBlueHour() {
        let intent = SearchParser.parse(query: "blue hour portraits")
        #expect(intent.filter.timeOfDay == TimeOfDay.blueHour.rawValue)
    }

    @Test
    func testTimeOfDayMidday() {
        let intent = SearchParser.parse(query: "noon light")
        #expect(intent.filter.timeOfDay == TimeOfDay.midday.rawValue)
    }

    @Test
    func testTimeOfDayNight() {
        let intent = SearchParser.parse(query: "night photos")
        #expect(intent.filter.timeOfDay == TimeOfDay.night.rawValue)
    }

    // MARK: - People name matching

    @Test
    func testSingleWordPersonMatch() {
        // A known person name (single word) present in the query is resolved.
        let intent = SearchParser.parse(query: "photos of Alice", knownPeople: ["Alice"])
        #expect(intent.personNames?.contains("Alice") == true,
                "Single-word person name in query must be resolved")
    }

    @Test
    func testMultiWordPersonMatch() {
        // A two-word name matched as a sliding window over the query words.
        let intent = SearchParser.parse(query: "show me Anna Smith portraits",
                                        knownPeople: ["Anna Smith"])
        #expect(intent.personNames?.contains("Anna Smith") == true,
                "Multi-word person name must be found via sliding-window match")
    }

    @Test
    func testStopWordsAreNotMatchedAsPeople() {
        // Common stop words ('the', 'for', 'photos') must not match a person named "Photos".
        let intent = SearchParser.parse(query: "show all photos", knownPeople: ["Photos"])
        #expect(intent.personNames == nil || intent.personNames?.contains("Photos") == false,
                "Stop words must not be matched as person names")
    }

    @Test
    func testUnknownPersonNameNotResolved() {
        // A name not in knownPeople should not appear in personNames.
        let intent = SearchParser.parse(query: "photos of Marcus", knownPeople: ["Alice"])
        #expect(intent.personNames == nil || intent.personNames?.contains("Marcus") == false)
    }

    // MARK: - Multi-signal query

    @Test
    func testMultiSignalQueryCombinesFilters() {
        // A single query can hit multiple signals: year + curation state.
        let intent = SearchParser.parse(query: "2023 keepers")
        #expect(intent.filter.yearFrom == 2023)
        #expect(intent.filter.curationState == CurationState.keeper.rawValue)
    }
}
