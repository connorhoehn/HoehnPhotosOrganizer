import Foundation
import SwiftUI

// MARK: - Photo Enums (shared between macOS and iOS)

public enum PhotoRole: String, CaseIterable, Identifiable {
    case original
    case editedExport = "edited_export"
    case proxy
    case workflowOutput = "workflow_output"
    case printReference = "print_reference"
    case externalReference = "external_reference"

    public var id: String { rawValue }
}

public enum CurationState: String, CaseIterable, Identifiable {
    case keeper
    case archive
    case needsReview = "needs_review"
    case rejected
    case deleted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keeper:      "Keeper"
        case .archive:     "Archive"
        case .needsReview: "Needs Review"
        case .rejected:    "Rejected"
        case .deleted:     "Deleted"
        }
    }

    public var tint: Color {
        switch self {
        case .keeper:      .green
        case .archive:     .blue
        case .needsReview: .orange
        case .rejected:    .red
        case .deleted:     .gray
        }
    }

    public var systemIcon: String {
        switch self {
        case .keeper:      "star.fill"
        case .archive:     "archivebox.fill"
        case .needsReview: "exclamationmark.circle.fill"
        case .rejected:    "xmark.circle.fill"
        case .deleted:     "trash.fill"
        }
    }
}

public enum SyncState: String, CaseIterable, Identifiable {
    case localOnly = "local_only"
    case queued
    case synced
    case failed

    public var id: String { rawValue }
}

public enum ProcessingState: String, CaseIterable, Identifiable {
    case indexed
    case proxyPending = "proxy_pending"
    case proxyReady = "proxy_ready"
    case metadataEnriched = "metadata_enriched"
    case syncPending = "sync_pending"

    public var id: String { rawValue }
}
