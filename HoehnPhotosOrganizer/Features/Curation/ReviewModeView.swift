import SwiftUI
import GRDB

/// ReviewModeView is the full-screen keyboard-driven photo review interface.
/// Displays one large proxy image at a time with keyboard shortcuts for curation.
/// - P (keeper): Mark current photo as keeper and advance
/// - X (rejected): Mark current photo as rejected and advance
/// - U (needs_review): Clear to needs_review and advance
/// - Left/Right arrows: Navigate without changing curation state
/// - Escape: Close the view
struct ReviewModeView: View {
    @StateObject var viewModel: ReviewModeViewModel
    @FocusState private var isFocused: Bool
    @State private var rotationAngle: Double = 0
    @State private var proxyImage: NSImage? = nil
    @State private var showShortcutHelp = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Dark background
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Curation badge in top-right corner
                VStack(alignment: .trailing) {
                    if let photo = viewModel.currentPhoto,
                       let curationState = CurationState(rawValue: photo.curationState),
                       curationState != .needsReview {
                        HStack(spacing: 8) {
                            Text(curationState.title)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        .padding(6)
                        .background(curationState.tint)
                        .cornerRadius(4)
                        .padding(16)
                    } else {
                        Color.clear
                            .frame(height: 36)
                            .padding(16)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                // Centred proxy image
                Spacer()
                HStack {
                    Spacer()

                    if let img = proxyImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 1400, maxHeight: 900)
                            .rotationEffect(.degrees(rotationAngle))
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.gray)
                            if let photo = viewModel.currentPhoto {
                                Text(photo.canonicalName)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundColor(.gray)
                        .frame(maxWidth: 1400, maxHeight: 900)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .rotationEffect(.degrees(rotationAngle))
                    }

                    Spacer()
                }
                .task(id: viewModel.currentPhoto?.id) {
                    proxyImage = nil
                    guard let photo = viewModel.currentPhoto else { return }
                    let baseName = (photo.canonicalName as NSString).deletingPathExtension
                    let proxyURL = ProxyGenerationActor.proxiesDirectory()
                        .appendingPathComponent(baseName + ".jpg")
                    proxyImage = await Task.detached(priority: .userInitiated) {
                        NSImage(contentsOf: proxyURL)
                    }.value
                }
                Spacer()

                // Photo counter at bottom
                HStack {
                    Spacer()
                    Text("\(viewModel.currentIndex + 1) of \(viewModel.photos.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(12)
                    Spacer()
                }
            }

            // Navigation arrows (left/right) at edges
            HStack {
                Button {
                    viewModel.retreat()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(24)

                Spacer()

                Button {
                    viewModel.advance()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(24)
            }
            .frame(maxHeight: .infinity, alignment: .center)

            // Bottom toolbar: rotate + help
            HStack {
                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        rotationAngle = (rotationAngle + 90).truncatingRemainder(dividingBy: 360)
                    }
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Rotate image (R)")

                Button {
                    showShortcutHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Keyboard shortcuts (?)")

                Spacer()
            }
            .padding(.bottom, 24)
            .sheet(isPresented: $showShortcutHelp) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Keyboard Shortcuts")
                        .font(.headline)
                        .padding()
                    Divider()
                    List {
                        shortcutRow("P", "Mark as Keeper")
                        shortcutRow("X", "Mark as Rejected")
                        shortcutRow("U", "Needs Review")
                        shortcutRow("→", "Next photo")
                        shortcutRow("←", "Previous photo")
                        shortcutRow("R", "Rotate image")
                        shortcutRow("⌘Z", "Undo last mark")
                        shortcutRow("Esc", "Close review mode")
                    }
                    .frame(minHeight: 300)
                }
                .frame(width: 300)
                .presentationDetents([.medium])
            }
        }
        // Keyboard shortcuts
        .onKeyPress("p") {
            viewModel.applyCuration(.keeper)
            return .handled
        }
        .onKeyPress("x") {
            viewModel.applyCuration(.rejected)
            return .handled
        }
        .onKeyPress("u") {
            viewModel.applyCuration(.needsReview)
            return .handled
        }
        .onKeyPress("r") {
            withAnimation(.easeInOut(duration: 0.2)) {
                rotationAngle = (rotationAngle + 90).truncatingRemainder(dividingBy: 360)
            }
            return .handled
        }
        .onKeyPress("?") {
            showShortcutHelp.toggle()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            viewModel.retreat()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            viewModel.advance()
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.isActive = false
            onDismiss?()
            return .handled
        }
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
        }
        .onChange(of: viewModel.currentIndex) { _ in
            rotationAngle = 0
        }
    }
}

// MARK: - Helpers

extension ReviewModeView {
    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlColor))
                .cornerRadius(4)
            Text(description)
            Spacer()
        }
    }
}

#Preview {
    @MainActor
    func makePreview() -> some View {
        let db = try! AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let viewModel = ReviewModeViewModel(photoRepo: photoRepo)

        // Create mock photos for preview
        let mockPhotos = [
            PhotoAsset.new(canonicalName: "photo1.jpg", role: .original, filePath: "/tmp/photo1.jpg", fileSize: 1000),
            PhotoAsset.new(canonicalName: "photo2.jpg", role: .original, filePath: "/tmp/photo2.jpg", fileSize: 1000),
            PhotoAsset.new(canonicalName: "photo3.jpg", role: .original, filePath: "/tmp/photo3.jpg", fileSize: 1000),
        ]

        viewModel.loadPhotos(mockPhotos)
        return ReviewModeView(viewModel: viewModel)
    }

    return makePreview()
}
