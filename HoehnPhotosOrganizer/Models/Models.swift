import Foundation
import SwiftUI

// MARK: - StudioSendToPrintLab Notification

extension Notification.Name {
    static let studioSendToPrintLab = Notification.Name("StudioSendToPrintLab")
    static let openInStudio = Notification.Name("OpenInStudio")
}

enum AppSection: String, CaseIterable, Identifiable {
    case library
    case search
    case map
    case drives
    case imports
    case jobs
    case workflows
    case printLab
    case studio
    case people
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library:
            "Library"
        case .search:
            "Search"
        case .map:
            "Map"
        case .drives:
            "Drives"
        case .imports:
            "Imports"
        case .jobs:
            "Jobs"
        case .workflows:
            "Workflows"
        case .printLab:
            "Print Lab"
        case .studio:
            "Studio"
        case .people:
            "People"
        case .activity:
            "Activity"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            "square.grid.2x2"
        case .search:
            "magnifyingglass"
        case .map:
            "map"
        case .drives:
            "externaldrive"
        case .imports:
            "arrow.down.doc"
        case .jobs:
            "tray.2"
        case .workflows:
            "arrow.triangle.2.circlepath.circle"
        case .printLab:
            "printer.fill"
        case .studio:
            "paintpalette.fill"
        case .people:
            "person.2.fill"
        case .activity:
            "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .settings:
            "gearshape"
        }
    }
}

extension AppSection {
    /// Short tooltip shown when hovering over a sidebar button.
    var sidebarHelpText: String {
        switch self {
        case .library:   "Library — Browse and curate your photo collection"
        case .search:    "Search — Find photos by content, date, location, or people"
        case .map:       "Map — Browse photos by geographic location"
        case .drives:    "Drives — Manage connected drives and volumes"
        case .imports:   "Imports — View and manage photo import history"
        case .jobs:      "Jobs — Import workflows, triage queues, and batch operations"
        case .workflows: "Workflows — Apply image transforms and AI operations"
        case .printLab:  "Print Lab — Layouts, linearization curves, and print processes"
        case .studio:    "Studio — Artistic rendering: oil, watercolor, charcoal, and more"
        case .people:    "People — Face recognition, identity management, and grouping"
        case .activity:  "Activity — Recent events, workflow results, and system notifications"
        case .settings:  "Settings — Configure app preferences and integrations"
        }
    }
}

enum PhotoRole: String, CaseIterable, Identifiable {
    case original
    case editedExport = "edited_export"
    case proxy
    case workflowOutput = "workflow_output"
    case printReference = "print_reference"
    case externalReference = "external_reference"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            "Original"
        case .editedExport:
            "Edited Export"
        case .proxy:
            "Proxy"
        case .workflowOutput:
            "Workflow Output"
        case .printReference:
            "Print Reference"
        case .externalReference:
            "External Reference"
        }
    }
}

enum CurationState: String, CaseIterable, Identifiable {
    case keeper
    case archive
    case needsReview = "needs_review"
    case rejected
    case deleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keeper:
            "Keeper"
        case .archive:
            "Archive"
        case .needsReview:
            "Needs Review"
        case .rejected:
            "Rejected"
        case .deleted:
            "Deleted"
        }
    }

    var tint: Color {
        switch self {
        case .keeper:
            .green
        case .archive:
            .blue
        case .needsReview:
            .orange
        case .rejected:
            .red
        case .deleted:
            .gray
        }
    }

    var systemIcon: String {
        switch self {
        case .keeper:      "star.fill"
        case .archive:     "archivebox.fill"
        case .needsReview: "exclamationmark.circle.fill"
        case .rejected:    "xmark.circle.fill"
        case .deleted:     "trash.fill"
        }
    }
}

enum SyncState: String, CaseIterable, Identifiable {
    case localOnly = "local_only"
    case queued
    case synced
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localOnly:
            "Local"
        case .queued:
            "Queued"
        case .synced:
            "Synced"
        case .failed:
            "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .localOnly:
            .secondary
        case .queued:
            .orange
        case .synced:
            .green
        case .failed:
            .red
        }
    }
}

enum ProcessingState: String, CaseIterable, Identifiable {
    case indexed
    case proxyPending = "proxy_pending"
    case proxyReady = "proxy_ready"
    case metadataEnriched = "metadata_enriched"
    case syncPending = "sync_pending"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indexed:
            "Indexed"
        case .proxyPending:
            "Proxy Pending"
        case .proxyReady:
            "Proxy Ready"
        case .metadataEnriched:
            "Metadata Enriched"
        case .syncPending:
            "Sync Pending"
        }
    }
}

// NOTE: ImportTemplate is defined in Features/Import/ImportWizardView.swift

enum ImportStage: String, CaseIterable, Identifiable {
    case detectDrive
    case inventory
    case extractPreview
    case enrichMetadata
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detectDrive:
            "Detect Drive"
        case .inventory:
            "Inventory Files"
        case .extractPreview:
            "Generate Proxies"
        case .enrichMetadata:
            "Extract Metadata"
        case .review:
            "Review & Sync"
        }
    }

    var subtitle: String {
        switch self {
        case .detectDrive:
            "Find connected storage and identify previously catalogued volumes."
        case .inventory:
            "Traverse the drive and create stable catalog entries."
        case .extractPreview:
            "Generate fast local proxies for browsing and ML workflows."
        case .enrichMetadata:
            "Pull EXIF, locations, and derived time-of-day context."
        case .review:
            "Summarize results, failures, and sync eligibility."
        }
    }
}

enum ActivityKind: String, CaseIterable, Identifiable {
    case importCompleted = "import_completed"
    case printLogged = "print_logged"
    case noteAdded = "note_added"
    case searchRun = "search_run"
    case workflowGenerated = "workflow_generated"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .importCompleted:
            "externaldrive.badge.checkmark"
        case .printLogged:
            "printer.dotmatrix"
        case .noteAdded:
            "text.bubble"
        case .searchRun:
            "magnifyingglass.circle"
        case .workflowGenerated:
            "wand.and.stars"
        }
    }
}

struct PrintRecipe: Identifiable, Hashable {
    let id: UUID
    let processName: String
    let paper: String
    let curveName: String
    let notes: String
    let lastUsed: Date
}

struct DriveRecord: Identifiable, Hashable {
    let id: UUID
    let name: String
    let mountPoint: String
    let photoCount: Int
    let lastSeen: Date
    let freeSpaceTB: Double
    let totalSpaceTB: Double
    let progress: Double
    let needsAttention: Bool
}

struct ActivityRecord: Identifiable, Hashable {
    let id: UUID
    let kind: ActivityKind
    let title: String
    let detail: String
    let timestamp: Date
}

struct ThreadSnippet: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let title: String
    let body: String
}

struct PhotoRecord: Identifiable, Hashable {
    let id: UUID
    let canonicalName: String
    let displayTitle: String
    let role: PhotoRole
    let curation: CurationState
    let syncState: SyncState
    let processingState: ProcessingState
    let city: String
    let country: String
    let captureDate: Date
    let camera: String
    let lens: String
    let dimensions: String
    let fileType: String
    let keywords: [String]
    let summary: String
    let driveName: String
    let hasGPS: Bool
    let isPortfolioCandidate: Bool
    let gradient: [Color]
    let printRecipes: [PrintRecipe]
    let thread: [ThreadSnippet]
}

struct DashboardMetric: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
    let detail: String
    let tint: Color
}