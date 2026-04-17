import SwiftUI

// MARK: - StudioHistoryView

/// Full revision browser: filter, sort, compare side-by-side, rename, delete, batch export.
struct StudioHistoryView: View {

    @ObservedObject var viewModel: StudioViewModel

    // Selection
    @State private var primarySelection: UUID?
    @State private var secondarySelection: UUID?
    @State private var batchSelection: Set<UUID> = []
    @State private var isBatchMode = false

    // Comparison
    @State private var showComparison = false
    @State private var sliderPosition: CGFloat = 0.5

    // Filter / Sort
    @State private var filterMedium: ArtMedium?
    @State private var sortOrder: VersionSortOrder = .dateNewest

    // Inline rename
    @State private var renamingID: UUID?
    @State private var renameText: String = ""

    // Delete confirmation
    @State private var versionToDelete: StudioVersion?
    @State private var showDeleteConfirmation = false

    // MARK: - Filtered + Sorted Versions

    private var displayedVersions: [StudioVersion] {
        var result = viewModel.versions
        if let medium = filterMedium {
            result = result.filter { $0.medium == medium }
        }
        switch sortOrder {
        case .dateNewest:
            result.sort { $0.createdAt > $1.createdAt }
        case .dateOldest:
            result.sort { $0.createdAt < $1.createdAt }
        case .mediumName:
            result.sort { $0.medium.rawValue < $1.medium.rawValue }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Left: version list
            versionListPanel
                .frame(width: 300)

            Divider()

            // Right: preview / comparison / details
            previewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Delete Version?", isPresented: $showDeleteConfirmation, presenting: versionToDelete) { version in
            Button("Delete", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if primarySelection == version.id { primarySelection = nil }
                    if secondarySelection == version.id { secondarySelection = nil }
                    batchSelection.remove(version.id)
                    viewModel.deleteVersion(version)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { version in
            Text("Remove \"\(version.name)\"? The thumbnail and metadata files will be permanently deleted.")
        }
    }

    // MARK: - Version List Panel

    private var versionListPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("VERSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(displayedVersions.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Filter chips
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Sort + batch controls
            HStack(spacing: 8) {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(VersionSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(maxWidth: 130)

                Spacer()

                // Batch toggle
                Button {
                    isBatchMode.toggle()
                    if !isBatchMode { batchSelection.removeAll() }
                } label: {
                    Image(systemName: isBatchMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isBatchMode ? Color.accentColor : .secondary)
                .help("Toggle batch selection")

                if isBatchMode && !batchSelection.isEmpty {
                    Button {
                        viewModel.batchExport(versionIDs: batchSelection)
                    } label: {
                        Label("Export \(batchSelection.count)", systemImage: "square.and.arrow.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Version rows
            if displayedVersions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(displayedVersions) { version in
                            versionRow(version)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "All", icon: nil, isActive: filterMedium == nil) {
                    filterMedium = nil
                }

                // Only show mediums that appear in versions
                let usedMediums = Set(viewModel.versions.map(\.medium))
                ForEach(ArtMedium.allCases.filter { usedMediums.contains($0) }) { medium in
                    filterChip(label: medium.rawValue, icon: medium.icon, isActive: filterMedium == medium) {
                        filterMedium = filterMedium == medium ? nil : medium
                    }
                }
            }
        }
    }

    private func filterChip(label: String, icon: String?, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No versions yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Versions are created each time you render. You can also save manually from the Canvas.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
    }

    // MARK: - Version Row

    private func versionRow(_ version: StudioVersion) -> some View {
        let isPrimary = primarySelection == version.id
        let isSecondary = secondarySelection == version.id
        let isSelected = isPrimary || isSecondary
        let isBatchSelected = batchSelection.contains(version.id)

        return HStack(spacing: 10) {
            // Batch checkbox
            if isBatchMode {
                Image(systemName: isBatchSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isBatchSelected ? Color.accentColor : .secondary)
                    .onTapGesture {
                        if isBatchSelected {
                            batchSelection.remove(version.id)
                        } else {
                            batchSelection.insert(version.id)
                        }
                    }
            }

            // Thumbnail
            if let thumb = version.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: version.medium.icon).foregroundStyle(.tertiary))
            }

            // Name + metadata
            VStack(alignment: .leading, spacing: 3) {
                if renamingID == version.id {
                    TextField("Name", text: $renameText, onCommit: {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            viewModel.renameVersion(id: version.id, newName: trimmed)
                        }
                        renamingID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1))
                    .onExitCommand {
                        renamingID = nil
                    }
                } else {
                    Text(version.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            renamingID = version.id
                            renameText = version.name
                        }
                }

                HStack(spacing: 4) {
                    Image(systemName: version.medium.icon)
                        .font(.system(size: 9))
                    Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Selection badges
            if isPrimary {
                Text("A")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
            }
            if isSecondary {
                Text("B")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.orange))
            }

            // Context menu via button
            Menu {
                Button {
                    viewModel.restoreVersion(version)
                    viewModel.currentPage = .canvas
                } label: {
                    Label("Re-render with These Params", systemImage: "wand.and.stars")
                }

                Divider()

                Button {
                    primarySelection = version.id
                } label: {
                    Label("Set as A (Left)", systemImage: "rectangle.lefthalf.filled")
                }
                Button {
                    secondarySelection = version.id
                } label: {
                    Label("Set as B (Right)", systemImage: "rectangle.righthalf.filled")
                }

                if primarySelection != nil && secondarySelection != nil {
                    Button {
                        showComparison = true
                    } label: {
                        Label("Compare A vs B", systemImage: "rectangle.split.2x1")
                    }
                }

                Divider()

                Button {
                    renamingID = version.id
                    renameText = version.name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    versionToDelete = version
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.1)
                      : isBatchSelected
                        ? Color.accentColor.opacity(0.05)
                        : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isPrimary ? Color.accentColor
                    : isSecondary ? Color.orange
                    : Color.clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isBatchMode else {
                if batchSelection.contains(version.id) {
                    batchSelection.remove(version.id)
                } else {
                    batchSelection.insert(version.id)
                }
                return
            }
            // Single-tap: set as primary preview
            if primarySelection == version.id {
                primarySelection = nil
            } else {
                primarySelection = version.id
            }
        }
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if showComparison,
               let aID = primarySelection,
               let bID = secondarySelection,
               let versionA = viewModel.versions.first(where: { $0.id == aID }),
               let versionB = viewModel.versions.first(where: { $0.id == bID }),
               let imageA = versionA.thumbnail,
               let imageB = versionB.thumbnail {
                // Side-by-side comparison with slider
                comparisonView(imageA: imageA, imageB: imageB, nameA: versionA.name, nameB: versionB.name)
            } else if let selID = primarySelection,
                      let version = viewModel.versions.first(where: { $0.id == selID }) {
                // Single version detail
                versionDetailView(version)
            } else {
                // Placeholder
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a version to preview")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Click a version to see details. Use the menu to set A and B for comparison.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
    }

    // MARK: - Comparison View

    private func comparisonView(imageA: NSImage, imageB: NSImage, nameA: String, nameB: String) -> some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    Text("A: \(nameA)")
                        .font(.system(size: 11, weight: .medium))
                }
                Spacer()
                Button("Exit Compare") {
                    showComparison = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
                Spacer()
                HStack(spacing: 6) {
                    Text("B: \(nameB)")
                        .font(.system(size: 11, weight: .medium))
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Slider comparison
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // B (right) -- full width underneath
                    Image(nsImage: imageB)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // A (left) -- clipped to left portion
                    Image(nsImage: imageA)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .frame(width: geo.size.width * sliderPosition, alignment: .leading)
                        .clipped()

                    // Divider line
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: geo.size.width * sliderPosition - 1)
                        .shadow(radius: 2)

                    // Drag handle
                    Circle()
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "arrow.left.and.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                        )
                        .shadow(radius: 4)
                        .offset(x: geo.size.width * sliderPosition - 14)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    sliderPosition = max(0, min(1, value.location.x / geo.size.width))
                                }
                        )

                    // Labels
                    VStack {
                        Spacer()
                        HStack {
                            Text("A")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor))
                                .padding(12)
                            Spacer()
                            Text("B")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.orange))
                                .padding(12)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Version Detail View

    private func versionDetailView(_ version: StudioVersion) -> some View {
        VStack(spacing: 0) {
            // Preview image
            if let thumb = version.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(32)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: version.medium.icon)
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Details strip
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Name + medium
                    HStack(spacing: 10) {
                        Image(systemName: version.medium.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(2)
                            Text(version.medium.rawValue)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Divider()

                    // Date + file size
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CREATED")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let bytes = version.fileSizeBytes {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("FILE SIZE")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    // Parameters
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PARAMETERS")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        paramDetailRow("Brush Size", value: version.params.brushSize, max: 20)
                        paramDetailRow("Detail", value: version.params.detail, max: 1)
                        paramDetailRow("Texture", value: version.params.texture, max: 1)
                        paramDetailRow("Saturation", value: version.params.colorSaturation, max: 1)
                        paramDetailRow("Contrast", value: version.params.contrast, max: 1)
                    }

                    Divider()

                    // Quick actions
                    HStack(spacing: 8) {
                        Button {
                            viewModel.restoreVersion(version)
                            viewModel.currentPage = .canvas
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "wand.and.stars")
                                Text("Re-render")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if secondarySelection == nil || secondarySelection == version.id {
                            Button {
                                secondarySelection = version.id
                                if primarySelection == nil, let other = displayedVersions.first(where: { $0.id != version.id }) {
                                    primarySelection = other.id
                                }
                                showComparison = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "rectangle.split.2x1")
                                    Text("Compare")
                                }
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(displayedVersions.count < 2)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            renamingID = version.id
                            renameText = version.name
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                Text("Rename")
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            versionToDelete = version
                            showDeleteConfirmation = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Delete")
                            }
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                }
                .padding(16)
            }
            .frame(height: 280)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Param Detail Row

    private func paramDetailRow(_ label: String, value: Double, max: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
            ProgressView(value: value, total: max)
                .tint(.accentColor)
            Text(String(format: max > 1 ? "%.0f" : "%.2f", value))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 32)
                .foregroundStyle(.secondary)
        }
    }
}
