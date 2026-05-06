import Testing
@testable import HoehnPhotosOrganizer

struct DictationChunkingServiceTests {

    // MARK: - Equipment: film stock

    @Test
    func testEquipmentDetectionRecognizesFilmStock() async {
        let service = DictationChunkingService()
        let result = await service.chunk(text: "I shot this on Portra 400 in natural light",
                                         knownPeople: [])
        #expect(result.equipment?.filmStock == "Portra 400",
                "Equipment extraction must identify 'Portra 400' as a film stock")
    }

    // MARK: - Equipment: camera body

    @Test
    func testEquipmentDetectionRecognizesCameraBody() async {
        let service = DictationChunkingService()
        let result = await service.chunk(text: "Grabbed the Nikon FM2 for this street session",
                                         knownPeople: [])
        #expect(result.equipment?.cameraBody == "Nikon FM2",
                "Equipment extraction must identify 'Nikon FM2' as a camera body")
    }

    // MARK: - Equipment: lens

    @Test
    func testEquipmentDetectionRecognizesLens() async {
        let service = DictationChunkingService()
        let result = await service.chunk(text: "Wide open on the 85mm f/1.8 lens",
                                         knownPeople: [])
        #expect(result.equipment?.lens == "85mm f/1.8",
                "Equipment extraction must identify '85mm f/1.8' as a lens")
    }

    // MARK: - Event pattern matching

    @Test
    func testEventPatternDetectsHolidayAndLifeEvents() async {
        let service = DictationChunkingService()
        let result = await service.chunk(text: "Photos from the wedding and our summer vacation",
                                         knownPeople: [])
        let labels = result.dates.map(\.text)
        #expect(labels.contains("wedding"), "Date extraction must detect 'wedding' as an event")
        #expect(labels.contains("vacation"), "Date extraction must detect 'vacation' as an event")
    }

    // MARK: - Empty metadata for unrecognised text

    @Test
    func testChunkReturnsEmptyMetadataForPlainText() async {
        let service = DictationChunkingService()
        // Generic text with no names, equipment, dates, or locations
        let result = await service.chunk(text: "These are some photos I took",
                                         knownPeople: [])
        #expect(result.isEmpty, "chunk must return empty metadata for plain text with no recognised entities")
    }
}
