import SwiftUI
import AppKit

// MARK: - LibraryPickerSheet

/// Modal photo picker that shows the app catalog instead of Finder.
/// Presented as a sheet; user selects photos and confirms with "Add N Images".
/// Follows the pattern of ReviewModeView for grid rendering.
struct LibraryPickerSheet: View {

    // MARK: - Input
    let photos: [PhotoAsset]
    let onSelect: ([PhotoAsset]) -> Void

    // MARK: - State
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var searchText: String = ""

    // MARK: - Computed
    private var filteredPhotos: [PhotoAsset] {
        guard !searchText.isEmpty else { return photos }
        return photos.filter {
            $0.canonicalName.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search by filename", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                if filteredPhotos.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text(photos.isEmpty ? "No photos in library." : "No results.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                            spacing: 4
                        ) {
                            ForEach(filteredPhotos) { photo in
                                PickerPhotoCell(
                                    photo: photo,
                                    isSelected: selectedIDs.contains(photo.id)
                                )
                                .onTapGesture {
                                    toggleSelection(photo.id)
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .navigationTitle("Add from Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedIDs.count) Image\(selectedIDs.count == 1 ? "" : "s")") {
                        let selected = photos.filter { selectedIDs.contains($0.id) }
                        onSelect(selected)
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: - Helpers
    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

// MARK: - PickerPhotoCell

private struct PickerPhotoCell: View {
    let photo: PhotoAsset
    let isSelected: Bool

    private var proxyImage: NSImage? {
        // Load from proxies directory using canonical filename (without extension)
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        return NSImage(contentsOf: proxyURL)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = proxyImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .separatorColor)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 130, height: 110)
            .clipped()
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            // Selection checkmark badge
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(4)
            }
        }
    }
}
