import Testing
@testable import HoehnPhotosOrganizer

struct UserMetadataTests {

    // MARK: - decode

    @Test
    func testDecodeFromValidJSONReturnsPopulatedMetadata() {
        let json = #"{"camera":"Nikon FM2","location":"London","iso":400,"keywords":["street","film"],"people":[]}"#
        let result = UserMetadata.decode(from: json)
        #expect(result?.camera == "Nikon FM2")
        #expect(result?.location == "London")
        #expect(result?.iso == 400)
        #expect(result?.keywords == ["street", "film"])
    }

    @Test
    func testDecodeFromNilReturnsNil() {
        #expect(UserMetadata.decode(from: nil) == nil,
                "decode(from: nil) must return nil — there is nothing to deserialize")
    }

    // MARK: - merging

    @Test
    func testMergingOverwritesExistingFieldsWithNonNilValues() {
        let base = UserMetadata(camera: "Canon AE-1", location: "Paris")
        let patch = UserMetadata(camera: "Nikon FM2", iso: 200)

        let merged = base.merging(patch)
        #expect(merged.camera == "Nikon FM2", "merging must overwrite camera with the patch value")
        #expect(merged.location == "Paris",   "merging must preserve base fields not present in patch")
        #expect(merged.iso == 200,            "merging must bring in new fields from the patch")
    }

    @Test
    func testMergingPreservesBaseFieldsWhenPatchIsEmpty() {
        let base = UserMetadata(camera: "Leica M6", filmStock: "Tri-X 400", keywords: ["portrait"])
        let empty = UserMetadata()

        let merged = base.merging(empty)
        #expect(merged.camera == "Leica M6",   "Empty patch must not clobber base camera")
        #expect(merged.filmStock == "Tri-X 400", "Empty patch must not clobber base filmStock")
        #expect(merged.keywords == ["portrait"], "Empty patch must not clobber base keywords")
    }

    @Test
    func testMergingDeduplicatesKeywords() {
        let base  = UserMetadata(keywords: ["portrait", "film"])
        let patch = UserMetadata(keywords: ["film", "street"])

        let merged = base.merging(patch)
        let keywords = Set(merged.keywords)
        #expect(keywords.contains("portrait"))
        #expect(keywords.contains("film"))
        #expect(keywords.contains("street"))
        // "film" appears in both — must not be duplicated
        #expect(merged.keywords.filter { $0 == "film" }.count == 1,
                "merging must deduplicate keywords that appear in both base and patch")
    }
}
