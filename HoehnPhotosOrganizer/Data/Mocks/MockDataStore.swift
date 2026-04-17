import Foundation
import SwiftUI
import Combine

@MainActor
final class MockDataStore: ObservableObject {
    @Published var selectedSection: AppSection = .library
    @Published var selectedPhotoID: PhotoRecord.ID?
    @Published var searchText = "Photos from England with dark skies"
    @Published var selectedImportStage: ImportStage = .detectDrive
    @Published var isShowingImportWizard = false
    @Published var isDragOverWindow = false
    @Published var gridColumns = 4.0

    let photos: [PhotoRecord]
    let drives: [DriveRecord]
    let activities: [ActivityRecord]

    init() {
        let formatter = ISO8601DateFormatter()

        let platinumRecipe = PrintRecipe(
            id: UUID(),
            processName: "Platinum Palladium",
            paper: "Arches Platine",
            curveName: "pt-pd-v7.curve",
            notes: "Increase highlights slightly and keep shadow separation gentle.",
            lastUsed: formatter.date(from: "2026-03-08T10:30:00Z") ?? .now
        )

        let inkjetRecipe = PrintRecipe(
            id: UUID(),
            processName: "Inkjet B&W",
            paper: "Hahnemühle Photo Rag",
            curveName: "rag-neutral-v2.curve",
            notes: "Lift midtones and add a touch more density.",
            lastUsed: formatter.date(from: "2026-03-10T17:10:00Z") ?? .now
        )

        let englandThread = [
            ThreadSnippet(
                id: UUID(),
                date: formatter.date(from: "2026-03-09T21:00:00Z") ?? .now,
                title: "Trip context",
                body: "Late afternoon in Whitby. Heavy clouds, sea wind, strong tonal separation in the sky."
            ),
            ThreadSnippet(
                id: UUID(),
                date: formatter.date(from: "2026-03-10T08:10:00Z") ?? .now,
                title: "Print note",
                body: "Promising for platinum if the clouds remain open in the highlights."
            )
        ]

        let parisThread = [
            ThreadSnippet(
                id: UUID(),
                date: formatter.date(from: "2026-03-07T18:00:00Z") ?? .now,
                title: "Series idea",
                body: "Could become a small Paris street sequence if paired with the quieter stairwell images."
            ),
            ThreadSnippet(
                id: UUID(),
                date: formatter.date(from: "2026-03-08T09:45:00Z") ?? .now,
                title: "AI note extract",
                body: "Keywords surfaced locally: Paris, dusk, reflections, wet pavement, solitary figure."
            )
        ]

        let scanThread = [
            ThreadSnippet(
                id: UUID(),
                date: formatter.date(from: "2026-03-06T14:30:00Z") ?? .now,
                title: "Film scan batch",
                body: "Six-frame TIFF from lab sleeve 24A. Needs segmentation and per-frame notes."
            )
        ]

        // Curated hero records (5)
        let heroRecords: [PhotoRecord] = [
            PhotoRecord(
                id: UUID(),
                canonicalName: "L1004821.DNG",
                displayTitle: "Whitby Rooftops",
                role: .original,
                curation: .keeper,
                syncState: .queued,
                processingState: .metadataEnriched,
                city: "Whitby",
                country: "England",
                captureDate: formatter.date(from: "2024-10-21T16:42:00Z") ?? .now,
                camera: "Leica Q3",
                lens: "Summilux 28mm",
                dimensions: "9520 × 6336",
                fileType: "DNG",
                keywords: ["England", "storm light", "rooftops", "travel"],
                summary: "Strong keeper candidate with dramatic dark cloud structure and clear print potential.",
                driveName: "TravelArchive-01",
                hasGPS: true,
                isPortfolioCandidate: true,
                gradient: [.indigo, .cyan],
                printRecipes: [platinumRecipe, inkjetRecipe],
                thread: englandThread
            ),
            PhotoRecord(
                id: UUID(),
                canonicalName: "DSC_1044.ARW",
                displayTitle: "Paris Stair Light",
                role: .editedExport,
                curation: .keeper,
                syncState: .synced,
                processingState: .syncPending,
                city: "Paris",
                country: "France",
                captureDate: formatter.date(from: "2023-05-14T19:20:00Z") ?? .now,
                camera: "Sony A7R IV",
                lens: "55mm f/1.8",
                dimensions: "7000 × 4667",
                fileType: "JPG",
                keywords: ["Paris", "stairs", "reflection", "sequence"],
                summary: "Edited export with strong geometric structure. Worth threading against other Paris sequence images.",
                driveName: "Edits-02",
                hasGPS: true,
                isPortfolioCandidate: true,
                gradient: [.purple, .pink],
                printRecipes: [inkjetRecipe],
                thread: parisThread
            ),
            PhotoRecord(
                id: UUID(),
                canonicalName: "ROLL24A_SCAN_MASTER.TIF",
                displayTitle: "Roll 24A Contact Scan",
                role: .original,
                curation: .needsReview,
                syncState: .localOnly,
                processingState: .proxyReady,
                city: "Unknown",
                country: "Unknown",
                captureDate: formatter.date(from: "2022-08-03T12:00:00Z") ?? .now,
                camera: "Epson V850",
                lens: "Scan",
                dimensions: "12400 × 8200",
                fileType: "TIFF",
                keywords: ["film", "scan", "6-frame", "lab batch"],
                summary: "Multi-frame scan awaiting segmentation into individual negatives and metadata assignment.",
                driveName: "FilmScans",
                hasGPS: false,
                isPortfolioCandidate: false,
                gradient: [.orange, .brown],
                printRecipes: [],
                thread: scanThread
            ),
            PhotoRecord(
                id: UUID(),
                canonicalName: "L1010007.DNG",
                displayTitle: "Pennsylvania Treeline",
                role: .original,
                curation: .archive,
                syncState: .failed,
                processingState: .proxyPending,
                city: "Bucks County",
                country: "United States",
                captureDate: formatter.date(from: "2024-01-09T22:18:00Z") ?? .now,
                camera: "Leica Q3",
                lens: "Summilux 28mm",
                dimensions: "9520 × 6336",
                fileType: "DNG",
                keywords: ["Pennsylvania", "winter", "treeline"],
                summary: "Archive image with good atmosphere but not yet curated into an active project.",
                driveName: "TravelArchive-01",
                hasGPS: true,
                isPortfolioCandidate: false,
                gradient: [.teal, .mint],
                printRecipes: [],
                thread: []
            ),
            PhotoRecord(
                id: UUID(),
                canonicalName: "PARIS_001.JPG",
                displayTitle: "Paris 001",
                role: .editedExport,
                curation: .needsReview,
                syncState: .queued,
                processingState: .syncPending,
                city: "Paris",
                country: "France",
                captureDate: formatter.date(from: "2023-05-13T20:02:00Z") ?? .now,
                camera: "Sony A7R IV",
                lens: "55mm f/1.8",
                dimensions: "6240 × 4160",
                fileType: "JPG",
                keywords: ["Paris", "export", "edited"],
                summary: "Edited variant with unclear source linkage. Good example of why derivative tracking matters.",
                driveName: "Edits-02",
                hasGPS: false,
                isPortfolioCandidate: true,
                gradient: [.blue, .indigo],
                printRecipes: [],
                thread: parisThread
            )
        ]

        // Synthetic fixture records DSC_0001.ARW–DSC_0045.ARW (45 records) for M1.2 >= 50 total
        let cameras = ["Sony A7R IV", "Leica Q3", "Canon EOS R5", "Nikon Z9", "Fujifilm GFX 100S"]
        let lenses = ["55mm f/1.8", "Summilux 28mm", "RF 50mm f/1.2", "Z 85mm f/1.8", "GF 110mm f/2"]
        let cities = ["New York", "London", "Tokyo", "Berlin", "Rome", "Barcelona", "Lisbon", "Prague", "Vienna", "Amsterdam"]
        let countries = ["United States", "England", "Japan", "Germany", "Italy", "Spain", "Portugal", "Czech Republic", "Austria", "Netherlands"]
        let gradientPairs: [[Color]] = [[.red, .orange], [.green, .teal], [.blue, .purple], [.yellow, .orange], [.pink, .red], [.cyan, .blue], [.mint, .green], [.brown, .orange], [.gray, .secondary], [.indigo, .purple]]
        let driveNames = ["TravelArchive-01", "Edits-02", "FilmScans"]
        let processingStates: [ProcessingState] = [.indexed, .proxyPending, .proxyReady, .metadataEnriched, .syncPending]
        let curationStates: [CurationState] = [.keeper, .archive, .needsReview, .rejected]
        let syncStates: [SyncState] = [.localOnly, .queued, .synced, .failed]

        // Year/month pairs spanning 2018–2024 for varied capture dates
        let yearMonths: [(Int, Int)] = [
            (2018, 3), (2018, 7), (2018, 11), (2019, 2), (2019, 6),
            (2019, 9), (2020, 1), (2020, 4), (2020, 8), (2020, 12),
            (2021, 3), (2021, 5), (2021, 10), (2022, 1), (2022, 4),
            (2022, 7), (2022, 11), (2023, 2), (2023, 4), (2023, 8),
            (2023, 11), (2024, 1), (2024, 3), (2024, 6), (2024, 9),
            (2024, 11), (2018, 5), (2019, 1), (2019, 8), (2020, 6),
            (2021, 7), (2021, 12), (2022, 3), (2022, 9), (2023, 1),
            (2023, 6), (2023, 10), (2024, 2), (2024, 5), (2024, 8),
            (2018, 9), (2019, 4), (2020, 10), (2021, 2), (2022, 6)
        ]

        var cal = DateComponents()
        cal.timeZone = TimeZone(identifier: "UTC")

        let syntheticRecords: [PhotoRecord] = (1...45).map { i in
            let idx = i - 1
            let (year, month) = yearMonths[idx % yearMonths.count]
            cal.year = year
            cal.month = month
            cal.day = (idx % 28) + 1
            cal.hour = (idx % 12) + 6
            cal.minute = (idx * 7) % 60
            let captureDate = Calendar(identifier: .gregorian).date(from: cal) ?? .now
            let locationIdx = idx % cities.count
            let fileNumber = String(format: "%04d", i)
            return PhotoRecord(
                id: UUID(),
                canonicalName: "DSC_\(fileNumber).ARW",
                displayTitle: "\(cities[locationIdx]) \(fileNumber)",
                role: idx % 5 == 0 ? .editedExport : .original,
                curation: curationStates[idx % curationStates.count],
                syncState: syncStates[idx % syncStates.count],
                processingState: processingStates[idx % processingStates.count],
                city: cities[locationIdx],
                country: countries[locationIdx],
                captureDate: captureDate,
                camera: cameras[idx % cameras.count],
                lens: lenses[idx % lenses.count],
                dimensions: "7952 × 5304",
                fileType: "ARW",
                keywords: [countries[locationIdx].lowercased(), "travel", year % 2 == 0 ? "monochrome" : "colour"],
                summary: "Fixture record \(i) — synthetic data for UI development and test coverage.",
                driveName: driveNames[idx % driveNames.count],
                hasGPS: idx % 3 != 0,
                isPortfolioCandidate: idx % 4 == 0,
                gradient: gradientPairs[idx % gradientPairs.count],
                printRecipes: [],
                thread: []
            )
        }

        photos = heroRecords + syntheticRecords

        drives = [
            DriveRecord(
                id: UUID(),
                name: "TravelArchive-01",
                mountPoint: "/Volumes/TravelArchive-01",
                photoCount: 48213,
                lastSeen: formatter.date(from: "2026-03-11T05:20:00Z") ?? .now,
                freeSpaceTB: 1.8,
                totalSpaceTB: 4.0,
                progress: 0.84,
                needsAttention: false
            ),
            DriveRecord(
                id: UUID(),
                name: "Edits-02",
                mountPoint: "/Volumes/Edits-02",
                photoCount: 18244,
                lastSeen: formatter.date(from: "2026-03-10T22:15:00Z") ?? .now,
                freeSpaceTB: 0.4,
                totalSpaceTB: 2.0,
                progress: 0.63,
                needsAttention: true
            ),
            DriveRecord(
                id: UUID(),
                name: "FilmScans",
                mountPoint: "/Volumes/FilmScans",
                photoCount: 3912,
                lastSeen: formatter.date(from: "2026-03-09T15:50:00Z") ?? .now,
                freeSpaceTB: 3.2,
                totalSpaceTB: 8.0,
                progress: 0.41,
                needsAttention: true
            )
        ]

        activities = [
            ActivityRecord(
                id: UUID(),
                kind: .importCompleted,
                title: "Drive inventory refreshed",
                detail: "TravelArchive-01 scanned: 48,213 photos, 1,242 new proxies queued.",
                timestamp: formatter.date(from: "2026-03-11T05:20:00Z") ?? .now
            ),
            ActivityRecord(
                id: UUID(),
                kind: .printLogged,
                title: "Platinum recipe updated",
                detail: "Whitby Rooftops received a new platinum-palladium recipe with revised highlight curve.",
                timestamp: formatter.date(from: "2026-03-10T17:10:00Z") ?? .now
            ),
            ActivityRecord(
                id: UUID(),
                kind: .noteAdded,
                title: "Paris sequence annotated",
                detail: "A local note-to-metadata pass extracted dusk, reflection, and solitary figure tags.",
                timestamp: formatter.date(from: "2026-03-10T08:10:00Z") ?? .now
            ),
            ActivityRecord(
                id: UUID(),
                kind: .workflowGenerated,
                title: "Film scan marked for splitting",
                detail: "Roll 24A scan was flagged for six-frame segmentation and sleeve linking.",
                timestamp: formatter.date(from: "2026-03-09T14:30:00Z") ?? .now
            )
        ]

        selectedPhotoID = photos.first?.id
    }

    var selectedPhoto: PhotoRecord? {
        photos.first(where: { $0.id == selectedPhotoID }) ?? photos.first
    }

    var filteredPhotos: [PhotoRecord] {
        switch selectedSection {
        case .library:
            photos
        case .search:
            photos.filter { photo in
                photo.country.localizedCaseInsensitiveContains("England") ||
                photo.keywords.contains(where: { $0.localizedCaseInsensitiveContains("dark") || $0.localizedCaseInsensitiveContains("England") }) ||
                photo.summary.localizedCaseInsensitiveContains("dark")
            }
        case .map:
            photos.filter { $0.hasGPS }
        case .drives, .imports:
            photos
        case .jobs:
            photos
        case .workflows:
            photos
        case .printLab:
            photos.filter { !$0.printRecipes.isEmpty }
        case .people:
            photos
        case .studio:
            photos
        case .activity:
            photos.filter { $0.isPortfolioCandidate }
        case .settings:
            photos
        }
    }

    var metrics: [DashboardMetric] {
        [
            DashboardMetric(title: "Catalogued", value: "100k+", detail: "Target library size across all connected drives", tint: .blue),
            DashboardMetric(title: "Keepers", value: "1,500", detail: "Working set for active review, print, and sync", tint: .green),
            DashboardMetric(title: "Proxy Queue", value: "1,242", detail: "Files still waiting for local preview generation", tint: .orange),
            DashboardMetric(title: "Sync Issues", value: "12", detail: "Assets that need retry or conflict review", tint: .red)
        ]
    }

    func select(_ photo: PhotoRecord) {
        selectedPhotoID = photo.id
    }
}