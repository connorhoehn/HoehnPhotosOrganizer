import SwiftUI
import AppKit
import CoreGraphics
import Combine

// MARK: - SoftProofPanelViewModel

@MainActor
final class SoftProofPanelViewModel: ObservableObject {

    // MARK: Profile picker

    @Published var profileGroups: [ICCProfileGroup] = []
    @Published var selectedProfile: ICCProfile? = nil
    @Published var profileSearch: String = ""

    // MARK: Rendering options

    @Published var intent: CGColorRenderingIntent = .relativeColorimetric
    @Published var blackPointCompensation: Bool = true

    // MARK: Preview state

    @Published var showProofed: Bool = true
    @Published var isRendering: Bool = false
    @Published var proofedImage: NSImage? = nil
    @Published var errorMessage: String? = nil

    private let service = SoftProofService()

    // MARK: Filtered profile list

    var filteredGroups: [ICCProfileGroup] {
        guard !profileSearch.isEmpty else { return profileGroups }
        return profileGroups.compactMap { group in
            let matches = group.profiles.filter {
                $0.displayName.localizedCaseInsensitiveContains(profileSearch)
                || group.name.localizedCaseInsensitiveContains(profileSearch)
            }
            return matches.isEmpty ? nil : ICCProfileGroup(name: group.name, profiles: matches)
        }
    }

    func loadProfiles() {
        profileGroups = ICCProfileService.discoverGroupedICCProfiles()
    }

    func renderPreview(source: NSImage) async {
        guard let profile = selectedProfile else { return }
        isRendering = true
        errorMessage = nil
        proofedImage = nil
        do {
            proofedImage = try await service.renderSoftProof(
                image: source,
                profileURL: profile.url,
                intent: intent,
                blackPointCompensation: blackPointCompensation
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isRendering = false
    }
}

// MARK: - SoftProofPanel

/// Sheet that lets the user select an ICC printer profile, choose rendering intent,
/// preview the soft proof, and apply it to the current canvas image.
struct SoftProofPanel: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PrintLabViewModel
    let sourceImage: NSImage

    @StateObject private var vm = SoftProofPanelViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar ──────────────────────────────────────────
            HStack {
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                Text("Soft Proof")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // ── Main content ───────────────────────────────────────
            HStack(spacing: 0) {

                // Left: Profile picker
                profilePickerColumn
                    .frame(width: 260)

                Divider()

                // Right: Preview + controls
                VStack(spacing: 0) {
                    previewSection
                    Divider()
                    controlBar
                }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear {
            vm.loadProfiles()
            // Pre-select previously used profile if any
            if let existingURL = viewModel.softProofProfileURL {
                for group in vm.profileGroups {
                    if let match = group.profiles.first(where: { $0.url == existingURL }) {
                        vm.selectedProfile = match
                        vm.intent = viewModel.softProofIntent
                        vm.blackPointCompensation = viewModel.softProofBPC
                        break
                    }
                }
            }
        }
        .onChange(of: vm.selectedProfile?.url) { _, _ in
            Task { await vm.renderPreview(source: sourceImage) }
        }
        .onChange(of: vm.intent) { _, _ in
            Task { await vm.renderPreview(source: sourceImage) }
        }
        .onChange(of: vm.blackPointCompensation) { _, _ in
            Task { await vm.renderPreview(source: sourceImage) }
        }
    }

    // MARK: - Profile Picker Column

    private var profilePickerColumn: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("ICC Profile")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search profiles…", text: $vm.profileSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !vm.profileSearch.isEmpty {
                    Button {
                        vm.profileSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            // Grouped profile list
            if vm.profileGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No ICC profiles found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Install printer profiles via macOS ColorSync.")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(vm.filteredGroups) { group in
                            Section {
                                ForEach(group.profiles) { profile in
                                    profileRow(profile)
                                }
                            } header: {
                                profileGroupHeader(group.name)
                            }
                        }
                        if vm.filteredGroups.isEmpty {
                            Text("No profiles match \"\(vm.profileSearch)\"")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func profileGroupHeader(_ name: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func profileRow(_ profile: ICCProfile) -> some View {
        let isSelected = vm.selectedProfile?.url == profile.url
        return HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 14)
            Text(profile.displayName)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { vm.selectedProfile = profile }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if vm.isRendering {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Rendering soft proof…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = vm.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            } else if vm.selectedProfile == nil {
                VStack(spacing: 8) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Select an ICC profile to preview")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                // Before / After toggle
                let displayImage = (vm.showProofed ? vm.proofedImage : nil) ?? sourceImage
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)

                // Before/after pill in top-right corner
                VStack {
                    HStack {
                        Spacer()
                        beforeAfterPill
                            .padding(10)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var beforeAfterPill: some View {
        HStack(spacing: 0) {
            Button {
                vm.showProofed = false
            } label: {
                Text("Before")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(!vm.showProofed ? Color.accentColor : Color.clear)
                    .foregroundStyle(!vm.showProofed ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)

            Button {
                vm.showProofed = true
            } label: {
                Text("After")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(vm.showProofed ? Color.accentColor : Color.clear)
                    .foregroundStyle(vm.showProofed ? Color.white : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 14) {
            // Rendering intent
            HStack(spacing: 6) {
                Text("Intent:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $vm.intent) {
                    Text("Perceptual").tag(CGColorRenderingIntent.perceptual)
                    Text("Relative").tag(CGColorRenderingIntent.relativeColorimetric)
                    Text("Absolute").tag(CGColorRenderingIntent.absoluteColorimetric)
                    Text("Saturation").tag(CGColorRenderingIntent.saturation)
                }
                .frame(width: 130)
                .labelsHidden()
            }

            // BPC toggle
            Toggle(isOn: $vm.blackPointCompensation) {
                Text("Black Point")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            Spacer()

            // Profile name badge (if selected)
            if let name = vm.selectedProfile?.displayName {
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
            }

            Divider().frame(height: 20)

            // Apply Settings Only (saves to viewModel without baking image)
            Button("Apply Settings") {
                guard let profile = vm.selectedProfile else { return }
                viewModel.softProofProfileURL = profile.url
                viewModel.softProofIntent     = vm.intent
                viewModel.softProofBPC        = vm.blackPointCompensation
                dismiss()
            }
            .disabled(vm.selectedProfile == nil)

            // Apply to Canvas (bakes proofed image into canvas tile)
            Button("Apply to Canvas") {
                guard let profile = vm.selectedProfile,
                      let proofed = vm.proofedImage else { return }
                viewModel.softProofProfileURL = profile.url
                viewModel.softProofIntent     = vm.intent
                viewModel.softProofBPC        = vm.blackPointCompensation
                viewModel.applySoftProof(
                    image: proofed,
                    profileURL: profile.url,
                    intentString: vm.intent.displayName,
                    bpc: vm.blackPointCompensation
                )
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.selectedProfile == nil || vm.proofedImage == nil || vm.isRendering)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - CGColorRenderingIntent helpers

private extension CGColorRenderingIntent {
    var displayName: String {
        switch self {
        case .perceptual:             return "perceptual"
        case .relativeColorimetric:   return "relative"
        case .absoluteColorimetric:   return "absolute"
        case .saturation:             return "saturation"
        default:                      return "relative"
        }
    }
}
