import SwiftUI

/// A sidebar section listing all manual and smart collections from CollectionRepository.
/// Displays a collection icon, name, and "Smart" badge for smart collections.
/// Uses .task { } for async loading (macOS 14+ standard pattern).
/// No create-collection UI — collection creation is deferred to a future plan.
struct CollectionSidebarSection: View {
    @State private var collections: [PhotoCollection] = []
    let collectionRepo: CollectionRepository
    var onSelectCollection: (PhotoCollection) -> Void

    var body: some View {
        Section("Collections") {
            if collections.isEmpty {
                Text("No collections")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(collections) { col in
                    Button(action: {
                        onSelectCollection(col)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: col.kind == "smart" ? "sparkles" : "rectangle.stack")
                                .foregroundColor(.secondary)

                            Text(col.name)
                                .lineLimit(1)

                            Spacer()

                            // Kind badge for smart collections
                            if col.kind == "smart" {
                                Text("Smart")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task {
            do {
                collections = try await collectionRepo.fetchAllCollections()
            } catch {
                // Silently log fetch failure; don't crash the sidebar
                print("Error fetching collections: \(error)")
            }
        }
    }
}

// Preview not available for CollectionSidebarSection due to actor CollectionRepository.
// CollectionSidebarSection is best previewed in context of a larger view that provides
// the collectionRepo parameter from the dependency injection chain.
