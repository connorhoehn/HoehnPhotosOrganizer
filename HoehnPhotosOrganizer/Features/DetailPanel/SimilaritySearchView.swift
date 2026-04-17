import SwiftUI

// MARK: - SimilaritySearchView
//
// Requirement: SRCH-9
// Shows a reference photo header and a scrollable grid of the most visually similar photos.
// Launched from InspectorPanel via the "Find Similar Photos" button.
//
// Layout:
//   ┌─────────────────────────────────────┐
//   │  [X]   Similar to: ref.jpg          │ ← header with dismiss button
//   ├─────────────────────────────────────┤
//   │  Reference photo preview (gradient) │
//   ├─────────────────────────────────────┤
//   │  Similar Photos (20 nearest)        │
//   │  [ card ] [ card ] [ card ]         │ ← LazyVGrid using PhotoCardAsset
//   │  [ card ] [ card ] [ card ]         │
//   │  ...                                │
//   │  (empty state / loading / error)    │
//   └─────────────────────────────────────┘

struct SimilaritySearchView: View {

    // MARK: - Input

    let referencePhoto: PhotoAsset

    // MARK: - Local state

    @State private var similarPhotos: [PhotoAsset] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showingError: Bool = false

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    // MARK: - Grid layout

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 140, maximum: 200), spacing: 14),
        count: 3
    )

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                referenceHeader
                Divider()
                contentArea
            }
            .navigationTitle("Similar Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .task {
            await loadSimilarPhotos()
        }
        .alert("Search Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    // MARK: - Sub-views

    /// Reference photo header showing gradient preview and canonical name.
    private var referenceHeader: some View {
        HStack(spacing: 14) {
            // Gradient thumbnail (same as InspectorPanel proxy placeholder)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.linearGradient(
                    colors: referencePhoto.placeholderGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.86))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Finding similar to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(referencePhoto.canonicalName)
                    .font(.headline)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Main content: loading spinner, empty state, error, or results grid.
    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            Spacer()
            ProgressView("Searching…")
                .progressViewStyle(.circular)
                .controlSize(.large)
            Spacer()
        } else if similarPhotos.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("No similar photos found")
                    .font(.title3.weight(.semibold))
                Text("This photo may not have an embedding yet, or no other photos match.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(similarPhotos) { photo in
                        PhotoCardAsset(photo: photo, isSelected: false)
                    }
                }
                .padding(18)
            }
        }
    }

    // MARK: - Data loading

    private func loadSimilarPhotos() async {
        guard let db = appDatabase else {
            errorMessage = "Database unavailable."
            showingError = true
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let embeddingRepo = EmbeddingRepository(db: db)
            let photoRepo = PhotoRepository(db: db)
            let service = SimilaritySearchService(embeddingRepo: embeddingRepo, photoRepo: photoRepo)
            similarPhotos = try await service.findSimilarPhotos(to: referencePhoto.id, limit: 20)
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }

        isLoading = false
    }
}
