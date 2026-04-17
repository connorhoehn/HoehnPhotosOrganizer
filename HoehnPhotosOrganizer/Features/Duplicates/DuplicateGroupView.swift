import SwiftUI

struct DuplicateGroupView: View {
    @StateObject private var viewModel: DuplicateGroupViewModel
    private let photoRepo: PhotoRepository

    init(db: AppDatabase, photoRepo: PhotoRepository) {
        _viewModel = StateObject(wrappedValue: DuplicateGroupViewModel(db: db))
        self.photoRepo = photoRepo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if viewModel.isScanning {
                ProgressView("Scanning for near-duplicates...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.groups.isEmpty {
                emptyState
            } else {
                groupList
            }
        }
        .navigationTitle("Near-Duplicate Review")
        .frame(minWidth: 600, minHeight: 400)
    }

    private var toolbar: some View {
        HStack {
            Button("Scan Library") {
                Task { await viewModel.scan() }
            }
            .disabled(viewModel.isScanning)
            Spacer()
            if !viewModel.selectedForDeletion.isEmpty {
                Button("Reject Selected (\(viewModel.selectedForDeletion.count))") {
                    Task { await viewModel.rejectSelected(photoRepo: photoRepo) }
                }
                .foregroundColor(.red)
            }
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No near-duplicates found")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Tap 'Scan Library' to check for bracketing sequences and near-identical shots.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupList: some View {
        List {
            ForEach(viewModel.groups) { group in
                Section {
                    groupRow(group)
                } header: {
                    Text("Group — \(group.photoIds.count) photos")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(zip(group.photoIds, group.proxyPaths)), id: \.0) { (photoId, proxyPath) in
                    let isSelected = viewModel.selectedForDeletion.contains(photoId)
                    ZStack(alignment: .topTrailing) {
                        if let nsImage = NSImage(contentsOfFile: proxyPath) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 90)
                                .clipped()
                                .border(isSelected ? Color.red : Color.clear, width: 3)
                        } else {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 120, height: 90)
                        }
                        if isSelected {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .padding(4)
                        }
                    }
                    .onTapGesture {
                        viewModel.toggleSelection(photoId: photoId)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}
