import SwiftUI
import HoehnPhotosCore

// MARK: - MobileCreativeView

/// Container view with segmented control switching between Studio, Print Lab, and Activity.
struct MobileCreativeView: View {

    enum CreativeSection: String, CaseIterable {
        case studio = "Studio"
        case printLab = "Print Lab"
        case activity = "Activity"
    }

    @State private var selectedSection: CreativeSection = .studio

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedSection) {
                ForEach(CreativeSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch selectedSection {
            case .studio:
                MobileStudioBrowseView()
            case .printLab:
                MobilePrintLabView()
            case .activity:
                MobileActivityView(isEmbedded: true)
            }
        }
    }
}

// MARK: - Placeholder Views (replaced in Sessions 9-10)

/// Temporary placeholder until Session 10 builds out the full Print Lab view.
struct MobilePrintLabPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "printer")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Print Lab")
                .font(.title3.weight(.semibold))
            Text("Print history and lab tools will appear here after syncing from your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
