import SwiftUI

// MARK: - StudioHostView

/// Top-level Studio wrapper with sub-page navigation.
/// Same layout pattern as PrintLabHostView.
struct StudioHostView: View {

    @ObservedObject var viewModel: StudioViewModel
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.activityEventService) private var activityEventService
    let libraryPhotos: [PhotoAsset]

    @State private var showPrintLabAlert = false

    var body: some View {
        VStack(spacing: 0) {
            pageNavBar
            Divider()

            Group {
                switch viewModel.currentPage {
                case .canvas:
                    StudioCanvasView(viewModel: viewModel, libraryPhotos: libraryPhotos)
                case .mediums:
                    StudioMediumsView(viewModel: viewModel)
                case .history:
                    StudioHistoryView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if let db = appDatabase {
                viewModel.configure(db: db)
            }
            viewModel.activityEventService = activityEventService
        }
        .onChange(of: activityEventService != nil) { _, _ in
            viewModel.activityEventService = activityEventService
        }
    }

    private var pageNavBar: some View {
        HStack(spacing: 2) {
            ForEach(StudioPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.currentPage = page
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: page.icon)
                            .font(.system(size: 11))
                        Text(page.rawValue)
                            .font(.system(size: 11, weight: viewModel.currentPage == page ? .semibold : .regular))
                    }
                    .foregroundStyle(viewModel.currentPage == page ? .white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(viewModel.currentPage == page ? Color.accentColor : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Send to Print Lab
            if let image = viewModel.renderedImage {
                Button {
                    NotificationCenter.default.post(
                        name: .studioSendToPrintLab,
                        object: nil,
                        userInfo: ["image": image]
                    )
                    let medium = viewModel.selectedMedium.rawValue
                    let svc = activityEventService
                    Task { try? await svc?.emitStudioSentToPrintLab(medium: medium) }
                } label: {
                    Label("Send to Print Lab", systemImage: "printer.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .alert("Send to Print Lab", isPresented: $showPrintLabAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Save the rendered image via File > Export, then drag it into the Print Lab canvas.")
                }
            }

            HStack(spacing: 4) {
                Text("Studio")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if viewModel.currentPage != .canvas {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                    Text(viewModel.currentPage.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
