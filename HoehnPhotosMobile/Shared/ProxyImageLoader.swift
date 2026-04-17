import SwiftUI

// MARK: - ProxyImageView

/// Async image loader that reads from the app's proxy image directory.
/// Replaces 7+ duplicate proxy URL builders and async loading patterns.
struct ProxyImageView: View {
    let canonicalName: String
    var subdirectory: String = "Proxies"
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if didLoad {
                // Load failed — show placeholder
                Color(uiColor: .secondarySystemBackground)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                // Loading — shimmer
                ShimmerRect()
            }
        }
        .task(id: canonicalName) {
            didLoad = false
            image = nil
            let name = canonicalName
            let subdir = subdirectory
            let loaded = await Task.detached(priority: .utility) {
                ProxyImageLoader.loadImage(canonicalName: name, subdirectory: subdir)
            }.value
            image = loaded
            didLoad = true
        }
    }
}

// MARK: - ShimmerRect (inline, lightweight)

private struct ShimmerRect: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(HPColor.shimmerBase)
            .overlay(
                LinearGradient(
                    colors: [.clear, HPColor.shimmerHighlight, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 300
                }
            }
    }
}

// MARK: - Static Loader

enum ProxyImageLoader {
    static let proxiesDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("Proxies", isDirectory: true)
    }()

    static func proxyURL(canonicalName: String, subdirectory: String = "Proxies") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        let baseName = (canonicalName as NSString).deletingPathExtension
        return base.appendingPathComponent("\(baseName).jpg")
    }

    static func loadImage(canonicalName: String, subdirectory: String = "Proxies") -> UIImage? {
        let url = proxyURL(canonicalName: canonicalName, subdirectory: subdirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
