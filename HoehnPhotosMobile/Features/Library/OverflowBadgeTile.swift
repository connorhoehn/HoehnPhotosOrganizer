import SwiftUI
import HoehnPhotosCore

/// The 6th tile in a bento section when the month has more than 6 photos.
/// Shows the 6th photo as a background with a dark scrim and "+N more" label.
/// Tapping expands the month to show all remaining photos.
struct OverflowBadgeTile: View {
    let photo: PhotoAsset        // The 6th photo (used as background image)
    let remainingCount: Int      // Number of additional photos beyond the 6 shown
    let onTap: () -> Void

    @State private var image: UIImage?

    private var proxyURL: URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            }
            Color.black.opacity(0.55)
            Text("+\(remainingCount) more")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }
        .accessibilityLabel("Show all photos. Plus \(remainingCount) more.")
        .accessibilityHint("Double tap to expand and show all photos")
        .task(id: photo.id) {
            let url = proxyURL
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                self.image = img
            }
        }
    }
}
