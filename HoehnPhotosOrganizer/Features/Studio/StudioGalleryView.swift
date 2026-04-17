import SwiftUI

// MARK: - StudioGalleryView

/// Procreate-style canvas gallery — groups all versions under their source photo.
/// Replaces the flat StudioHistoryView.
struct StudioGalleryView: View {

    @ObservedObject var viewModel: StudioViewModel

    @State private var searchText = ""
    @State private var sortOrder: CanvasSortOrder = .recent
    @State private var selectedCanvasId: String?
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var canvasToDelete: StudioCanvas?
    @State private var showDeleteConfirm = false

    private enum CanvasSortOrder: String, CaseIterable {
        case recent = "Recent"
        case name = "Name"
        case medium = "Medium"
    }

    private var filteredCanvases: [StudioCanvas] {
        var result = viewModel.canvases
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .recent:
            result.sort { $0.updatedAt > $1.updatedAt }
        case .name:
            result.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .medium:
            result.sort { $0.lastMedium < $1.lastMedium }
        }
        return result
    }

    var body: some View {
        Group {
            if let canvasId = selectedCanvasId,
               let canvas = viewModel.canvases.first(where: { $0.id == canvasId }) {
                StudioCanvasDetailView(
                    viewModel: viewModel,
                    canvas: canvas,
                    onBack: { selectedCanvasId = nil },
                    onResume: {
                        viewModel.resumeCanvas(canvas)
                    }
                )
            } else {
                galleryGrid
            }
        }
        .onAppear {
            Task { await viewModel.loadAllCanvases() }
        }
        .alert("Delete Canvas?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let canvas = canvasToDelete {
                    viewModel.deleteCanvas(canvas)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the canvas and all its versions. This cannot be undone.")
        }
    }

    // MARK: - Gallery Grid

    private var galleryGrid: some View {
        VStack(spacing: 0) {
            galleryToolbar
            Divider()

            if filteredCanvases.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)], spacing: 16) {
                        ForEach(filteredCanvases, id: \.id) { canvas in
                            canvasCard(canvas)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var galleryToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search canvases...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 220)

            Picker("", selection: $sortOrder) {
                ForEach(CanvasSortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            Text("\(filteredCanvases.count) canvas\(filteredCanvases.count == 1 ? "" : "es")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Canvas Card

    private func canvasCard(_ canvas: StudioCanvas) -> some View {
        let isSelected = selectedCanvasId == canvas.id
        let medium = ArtMedium(rawValue: canvas.lastMedium)

        return VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack {
                if let thumbPath = canvas.thumbnailPath,
                   let image = NSImage(contentsOfFile: thumbPath) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 140)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .frame(height: 140)
                        .overlay {
                            Image(systemName: medium?.icon ?? "paintpalette")
                                .font(.system(size: 32))
                                .foregroundStyle(.tertiary)
                        }
                }

                // Medium badge
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: medium?.icon ?? "paintpalette")
                                .font(.system(size: 8))
                            Text(canvas.lastMedium)
                                .font(.system(size: 8, weight: .medium))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.6))
                        )
                        .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                        .padding(6)
                    }
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                if renamingId == canvas.id {
                    TextField("Name", text: $renameText, onCommit: {
                        viewModel.renameCanvas(id: canvas.id, newName: renameText)
                        renamingId = nil
                    })
                    .font(.system(size: 11, weight: .semibold))
                    .textFieldStyle(.plain)
                } else {
                    Text(canvas.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(relativeDate(canvas.updatedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1)
        )
        .onTapGesture {
            selectedCanvasId = canvas.id
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                viewModel.resumeCanvas(canvas)
            }
        )
        .contextMenu {
            Button("Resume") {
                viewModel.resumeCanvas(canvas)
            }
            Divider()
            Button("Rename") {
                renameText = canvas.name
                renamingId = canvas.id
            }
            Button("Delete", role: .destructive) {
                canvasToDelete = canvas
                showDeleteConfirm = true
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Canvases Yet")
                .font(.title3.weight(.semibold))
            Text("Load a photo on the Canvas tab to start a new project.\nAll your work will be grouped here automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func relativeDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
