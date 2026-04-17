//
//  HoehnPhotosOrganizerTests.swift
//  HoehnPhotosOrganizerTests
//
//  Created by Connor Hoehn on 3/11/26.
//

import Testing
@testable import HoehnPhotosOrganizer

struct HoehnPhotosOrganizerTests {

    @Test @MainActor func mockDataBootstrapsPhaseOneShell() async throws {
        let store = MockDataStore()

        #expect(store.photos.count >= 5)
        #expect(store.drives.count >= 3)
        #expect(store.selectedPhoto != nil)
        #expect(store.metrics.count == 4)
    }

}
