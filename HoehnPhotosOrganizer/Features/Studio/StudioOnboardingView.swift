import SwiftUI

// MARK: - OnboardingStep

private enum OnboardingStep {
    case pickMedium
    case pickPhoto
}

// MARK: - StudioOnboardingView

/// Full-canvas overlay shown when no source image is loaded.
/// Two-step flow: pick a medium, then pick a photo from the library.
struct StudioOnboardingView: View {

    @ObservedObject var viewModel: StudioViewModel
    let libraryPhotos: [PhotoAsset]
    let onSelectPhoto: (PhotoAsset, NSImage) -> Void

    @State private var step: OnboardingStep = .pickMedium
    @State private var hoveredMedium: ArtMedium? = nil
    @State private var focusedIndex: Int = 0
    @State private var photoSearchText: String = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let allMediums = ArtMedium.allCases

    var body: some View {
        ZStack {
            // Background
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                switch step {
                case .pickMedium:
                    pickMediumStep
                        .frame(maxWidth: 560)
                        .padding(32)
                case .pickPhoto:
                    pickPhotoStep
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step 1: Pick a Medium

    private var pickMediumStep: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Choose a Medium")
                    .font(.system(size: 16, weight: .semibold))
                Text("Select an artistic style to get started")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(allMediums.enumerated()), id: \.element.id) { index, medium in
                    mediumCard(medium, index: index)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    step = .pickPhoto
                }
            } label: {
                Text("Choose Photo")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .onKeyPress(.leftArrow) { moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { moveFocus(-3); return .handled }
        .onKeyPress(.downArrow) { moveFocus(3); return .handled }
        .onKeyPress(.return) {
            let medium = allMediums[focusedIndex]
            viewModel.selectMedium(medium)
            withAnimation(.easeInOut(duration: 0.2)) { step = .pickPhoto }
            return .handled
        }
    }

    // MARK: - Step 2: Pick a Photo from Library

    private var pickPhotoStep: some View {
        VStack(spacing: 0) {
            // Header with back button and medium indicator
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = .pickMedium
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                        Text("Back")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 16)

                HStack(spacing: 4) {
                    Image(systemName: viewModel.selectedMedium.icon)
                        .font(.system(size: 11))
                    Text(viewModel.selectedMedium.rawValue)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text("Choose a photo from your library")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $photoSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 120)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Photo grid
            if filteredPhotos.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(libraryPhotos.isEmpty ? "No photos in library" : "No results")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 5),
                        spacing: 3
                    ) {
                        ForEach(filteredPhotos) { photo in
                            photoCell(photo)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var filteredPhotos: [PhotoAsset] {
        guard !photoSearchText.isEmpty else { return libraryPhotos }
        return libraryPhotos.filter {
            $0.canonicalName.localizedCaseInsensitiveContains(photoSearchText)
        }
    }

    private func photoCell(_ photo: PhotoAsset) -> some View {
        let available = isPhotoAvailable(photo)
        return Button {
            loadPhoto(photo)
        } label: {
            ZStack {
                Color(nsColor: .controlBackgroundColor)

                if let proxyPath = photo.proxyPath, let img = NSImage(contentsOfFile: proxyPath) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let img = NSImage(contentsOfFile: photo.filePath) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }

                // Unavailable overlay
                if !available {
                    Color.black.opacity(0.45)
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(height: 120)
            .clipped()
            .contentShape(Rectangle())
            .cornerRadius(4)
            .overlay(
                VStack {
                    Spacer()
                    Text(photo.canonicalName)
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.5))
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(available ? photo.canonicalName : "Source drive not connected")
    }

    /// Check if the photo's image can be loaded from any source.
    private func isPhotoAvailable(_ photo: PhotoAsset) -> Bool {
        if FileManager.default.fileExists(atPath: photo.filePath) { return true }
        if let pp = photo.proxyPath, FileManager.default.fileExists(atPath: pp) { return true }
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        return FileManager.default.fileExists(atPath: proxyURL.path)
    }

    private func loadPhoto(_ photo: PhotoAsset) {
        // Try full-res first, fall back to proxy, then proxy directory convention
        if let img = NSImage(contentsOfFile: photo.filePath) {
            withAnimation(.easeOut(duration: 0.35)) {
                onSelectPhoto(photo, img)
            }
        } else if let proxyPath = photo.proxyPath, let img = NSImage(contentsOfFile: proxyPath) {
            withAnimation(.easeOut(duration: 0.35)) {
                onSelectPhoto(photo, img)
            }
        } else {
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let proxyURL = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            if let img = NSImage(contentsOf: proxyURL) {
                withAnimation(.easeOut(duration: 0.35)) {
                    onSelectPhoto(photo, img)
                }
            }
        }
    }

    // MARK: - Medium Card

    private func mediumCard(_ medium: ArtMedium, index: Int) -> some View {
        let isSelected = viewModel.selectedMedium == medium
        let isHovered = hoveredMedium == medium
        let isFocused = focusedIndex == index

        return Button {
            viewModel.selectMedium(medium)
            focusedIndex = index
        } label: {
            VStack(spacing: 6) {
                Image(systemName: medium.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(height: 22)

                Text(medium.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(shortDescription(for: medium))
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : medium.paperColor.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor :
                        (isFocused ? Color.accentColor.opacity(0.6) :
                        (isHovered ? Color.primary.opacity(0.15) : Color.clear)),
                        lineWidth: isSelected ? 2 : (isFocused ? 1.5 : 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { over in hoveredMedium = over ? medium : nil }
    }

    private func shortDescription(for medium: ArtMedium) -> String {
        switch medium {
        case .oil:         return "Rich textured brushstrokes"
        case .watercolor:  return "Transparent washes & bleeding"
        case .charcoal:    return "Deep blacks, soft gradations"
        case .troisCrayon: return "Sanguine, sepia & white chalk"
        case .graphite:    return "Fine hatching & tonal range"
        case .inkWash:     return "Brush painting, ink dilution"
        case .pastel:      return "Soft chalky color & strokes"
        case .penAndInk:   return "Cross-hatching & stippling"
        }
    }

    private func moveFocus(_ delta: Int) {
        let newIndex = focusedIndex + delta
        guard newIndex >= 0, newIndex < allMediums.count else { return }
        focusedIndex = newIndex
        viewModel.selectMedium(allMediums[newIndex])
    }
}
