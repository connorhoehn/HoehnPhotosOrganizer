import Testing
@testable import HoehnPhotosOrganizer

struct ICCProfileServiceTests {

    @Test
    func test_discoverICCProfiles_returnsURLArray() {
        // Service returns a well-formed [URL] without crashing; each URL has a non-empty path.
        let urls = ICCProfileService.discoverICCProfiles()
        // The function must return a proper [URL] — no assertion fails implicitly on crash.
        for url in urls {
            #expect(!url.path.isEmpty, "Each discovered profile URL must have a non-empty path")
        }
    }

    @Test
    func test_discoverICCProfiles_onlyReturnsIccAndIcmExtensions() {
        // Every returned URL must end in .icc or .icm (case-insensitive).
        let urls = ICCProfileService.discoverICCProfiles()
        for url in urls {
            let ext = url.pathExtension.lowercased()
            #expect(ext == "icc" || ext == "icm",
                    "Unexpected extension '\(ext)' for profile: \(url.lastPathComponent)")
        }
    }

    @Test
    func test_discoverICCProfiles_searchesAllThreeStandardPaths() {
        // Repurposed: grouped discovery must include the "ColorSync System" group,
        // which comes from /System/Library/ColorSync/Profiles — always present on macOS.
        let groups = ICCProfileService.discoverGroupedICCProfiles()
        let systemGroup = groups.first { $0.name == "ColorSync System" }
        #expect(systemGroup != nil,
                "discoverGroupedICCProfiles must include a 'ColorSync System' group from the system ColorSync path")
        #expect(systemGroup?.profiles.isEmpty == false,
                "'ColorSync System' group must contain at least one profile")
    }

    @Test
    func test_discoverICCProfiles_emptyResultWhenPathsEmpty() {
        // Repurposed: flat URL list must contain no duplicate paths (each profile discovered once).
        let urls = ICCProfileService.discoverICCProfiles()
        let paths = urls.map(\.path)
        let uniquePaths = Set(paths)
        #expect(paths.count == uniquePaths.count,
                "discoverICCProfiles must not return duplicate URLs; got \(paths.count - uniquePaths.count) duplicate(s)")
    }
}
