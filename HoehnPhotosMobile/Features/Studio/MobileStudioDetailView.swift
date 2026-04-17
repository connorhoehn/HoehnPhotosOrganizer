import SwiftUI
import HoehnPhotosCore

// MARK: - MobileStudioDetailView

/// Full-bleed detail view for a Studio revision, presented as a sheet.
/// Shows the render image with pinch-to-zoom, metadata bar with parameters,
/// and source photo information.
struct MobileStudioDetailView: View {
    let revision: StudioRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase
    @State private var fullImage: UIImage?
    @State private var sourcePhoto: PhotoAsset?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = fullImage {
                    ZoomableImageView(image: img)
                } else if revision.fullResPath != nil {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Loading render...")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: revision.studioMedium.icon)
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Full resolution not synced")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                metadataBar
            }
            .navigationTitle(revision.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                await loadFullRes()
                await loadSourcePhoto()
            }
        }
    }

    // MARK: - Metadata Bar

    private var metadataBar: some View {
        VStack(spacing: 8) {
            // Medium + date row
            HStack(spacing: 12) {
                Label(revision.studioMedium.rawValue, systemImage: revision.studioMedium.icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(formattedDate(revision.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Parameters row
            if let params = revision.parameters {
                HStack(spacing: 16) {
                    paramPill("Brush", value: String(format: "%.0f", params.brushSize))
                    paramPill("Detail", value: String(format: "%.0f%%", params.detail * 100))
                    paramPill("Texture", value: String(format: "%.0f%%", params.texture * 100))
                    paramPill("Sat", value: String(format: "%.0f%%", params.colorSaturation * 100))
                    paramPill("Contrast", value: String(format: "%.0f%%", params.contrast * 100))
                }
            }

            // Source photo info
            if let photo = sourcePhoto {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(photo.canonicalName ?? "Source photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private func paramPill(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    private func loadFullRes() async {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let studioDir = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("studio")

        // Try full-res first
        if let fullPath = revision.fullResPath {
            let url = studioDir.appendingPathComponent(fullPath)
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                fullImage = img
                return
            }
        }

        // Fall back to thumbnail
        if let thumbPath = revision.thumbnailPath {
            let url = studioDir.appendingPathComponent(thumbPath)
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                fullImage = img
            }
        }
    }

    private func loadSourcePhoto() async {
        guard let db = appDatabase else { return }
        do {
            sourcePhoto = try await MobilePhotoRepository(db: db).fetchById(revision.photoId)
        } catch {
            print("[StudioDetail] Source photo load error: \(error)")
        }
    }

    private func formattedDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .long
            display.timeStyle = .short
            return display.string(from: date)
        }
        return isoString
    }
}

// MARK: - ZoomableImageView

/// UIKit-backed pinch-to-zoom image view wrapped for SwiftUI.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
