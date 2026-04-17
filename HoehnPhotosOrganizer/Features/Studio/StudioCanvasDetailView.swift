import SwiftUI

// MARK: - StudioCanvasDetailView

/// Detail view for a single canvas — shows its versions with A/B comparison.
struct StudioCanvasDetailView: View {

    @ObservedObject var viewModel: StudioViewModel
    let canvas: StudioCanvas
    let onBack: () -> Void
    let onResume: () -> Void

    @State private var versions: [StudioRevision] = []
    @State private var primaryId: String?
    @State private var secondaryId: String?
    @State private var showComparison = false
    @State private var sliderPosition: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            detailToolbar
            Divider()

            HStack(spacing: 0) {
                // Left: version list
                versionList
                    .frame(width: 260)

                Divider()

                // Center: preview
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { loadVersions() }
    }

    // MARK: - Toolbar

    private var detailToolbar: some View {
        HStack(spacing: 12) {
            Button {
                onBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Gallery")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)

            Text(canvas.name)
                .font(.system(size: 12, weight: .semibold))

            if let medium = ArtMedium(rawValue: canvas.lastMedium) {
                HStack(spacing: 3) {
                    Image(systemName: medium.icon)
                        .font(.system(size: 9))
                    Text(medium.rawValue)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onResume()
            } label: {
                Label("Resume", systemImage: "paintbrush.pointed")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Version List

    private var versionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("VERSIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(versions.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(versions, id: \.id) { rev in
                        versionRow(rev)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func versionRow(_ rev: StudioRevision) -> some View {
        let isA = primaryId == rev.id
        let isB = secondaryId == rev.id
        let medium = ArtMedium(rawValue: rev.medium)

        return HStack(spacing: 8) {
            // Thumbnail
            ZStack {
                if let path = rev.thumbnailPath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 36)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .frame(width: 48, height: 36)
                        .overlay {
                            Image(systemName: medium?.icon ?? "paintpalette")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(rev.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let m = medium {
                        Image(systemName: m.icon)
                            .font(.system(size: 8))
                    }
                    Text(rev.medium)
                        .font(.system(size: 9))
                    Text("·")
                    Text(relativeDate(rev.createdAt))
                        .font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // A/B badges
            if isA {
                Text("A")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.blue))
            }
            if isB {
                Text("B")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.orange))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isA || isB ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            primaryId = rev.id
            showComparison = false
        }
        .contextMenu {
            Button("Set as A") { primaryId = rev.id }
            Button("Set as B") { secondaryId = rev.id }
            if primaryId != nil && secondaryId != nil {
                Button("Compare A / B") { showComparison = true }
            }
        }
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        Group {
            if showComparison,
               let aId = primaryId, let bId = secondaryId,
               let aRev = versions.first(where: { $0.id == aId }),
               let bRev = versions.first(where: { $0.id == bId }),
               let aPath = aRev.thumbnailPath, let aImg = NSImage(contentsOfFile: aPath),
               let bPath = bRev.thumbnailPath, let bImg = NSImage(contentsOfFile: bPath) {
                comparisonView(imageA: aImg, imageB: bImg, nameA: aRev.name, nameB: bRev.name)
            } else if let selId = primaryId,
                      let rev = versions.first(where: { $0.id == selId }),
                      let path = rev.thumbnailPath,
                      let img = NSImage(contentsOfFile: path) {
                VStack(spacing: 8) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(20)

                    HStack(spacing: 12) {
                        Text(rev.name)
                            .font(.system(size: 13, weight: .semibold))
                        if let m = ArtMedium(rawValue: rev.medium) {
                            HStack(spacing: 3) {
                                Image(systemName: m.icon)
                                    .font(.system(size: 10))
                                Text(m.rawValue)
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                        }
                        Text(relativeDate(rev.createdAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.bottom, 16)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Select a version to preview")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Comparison

    private func comparisonView(imageA: NSImage, imageB: NSImage, nameA: String, nameB: String) -> some View {
        GeometryReader { geo in
            ZStack {
                // B (full)
                Image(nsImage: imageB)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                // A (clipped to left of slider)
                Image(nsImage: imageA)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(
                        DetailHalfClip(fraction: sliderPosition)
                    )

                // Slider line
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .position(x: sliderPosition * geo.size.width, y: geo.size.height / 2)
                    .shadow(color: .black.opacity(0.3), radius: 2)

                // Labels
                VStack {
                    Spacer()
                    HStack {
                        Text("A: \(nameA)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        Text("B: \(nameB)")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .padding(8)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        sliderPosition = max(0, min(1, value.location.x / geo.size.width))
                    }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(20)
    }

    // MARK: - Helpers

    private func loadVersions() {
        Task {
            guard let repo = viewModel.canvasRepo else { return }
            do {
                versions = try await repo.revisionsForCanvas(id: canvas.id)
                primaryId = versions.first?.id
            } catch {
                print("[CanvasDetail] Failed to load versions: \(error)")
            }
        }
    }

    private func relativeDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Half Clip Shape

private struct DetailHalfClip: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: 0, y: 0, width: rect.width * fraction, height: rect.height))
    }
}
