import SwiftUI

// MARK: - PrintLabHostView

/// Top-level wrapper for Print Lab that adds sub-page navigation.
/// Routes between: Print Layout, Curves, Processes.
/// The Curves page has its own sub-page navigation (Gallery, Creator, Linearize, Blend).
struct PrintLabHostView: View {

    @ObservedObject var viewModel: PrintLabViewModel
    @StateObject private var curveLabVM = CurveLabViewModel()
    @Environment(\.activityEventService) private var activityEventService
    let libraryPhotos: [PhotoAsset]
    @State private var showOnboarding = false
    @State private var assistantCollapsed = true

    var body: some View {
        VStack(spacing: 0) {
            pageTabStrip
            Divider()

            HStack(spacing: 0) {
                Group {
                    switch curveLabVM.currentPage {
                case .printLayout:
                    PrintLabView(viewModel: viewModel, libraryPhotos: libraryPhotos)

                case .curveBuilder:
                    curvesSection

                case .processes:
                    ProcessesView(viewModel: curveLabVM)

                case .printers:
                    PrintQueueView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Persistent chat panel across all PrintLab pages
            CurveLabChatPanel(viewModel: curveLabVM, isCollapsed: $assistantCollapsed)
        }
        }
        .sheet(isPresented: $showOnboarding) {
            CurveLabOnboardingView()
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "curveLabOnboardingSeen") {
                showOnboarding = true
                UserDefaults.standard.set(true, forKey: "curveLabOnboardingSeen")
            }
            curveLabVM.activityEventService = activityEventService
            syncBreadcrumb()
        }
        .onChange(of: activityEventService != nil) { _, _ in
            curveLabVM.activityEventService = activityEventService
        }
        .onChange(of: curveLabVM.currentPage) { _, _ in syncBreadcrumb() }
        .onChange(of: curveLabVM.curvesSubPage) { _, _ in syncBreadcrumb() }
        .alert("Unsaved Changes", isPresented: $curveLabVM.showUnsavedChangesAlert) {
            Button("Save & Continue") { curveLabVM.saveSessionAndNavigate() }
            Button("Discard", role: .destructive) { curveLabVM.discardSessionAndNavigate() }
            Button("Cancel", role: .cancel) { curveLabVM.pendingSubPageNavigation = nil }
        } message: {
            Text("You have unsaved changes to your curve. Save before leaving?")
        }
        .environmentObject(curveLabVM)
    }

    // MARK: - Breadcrumb Sync

    private func syncBreadcrumb() {
        let page = curveLabVM.currentPage
        if page == .curveBuilder {
            viewModel.breadcrumbSubtitle = "\(page.rawValue) › \(curveLabVM.curvesSubPage.rawValue)"
        } else {
            viewModel.breadcrumbSubtitle = page.rawValue
        }
    }

    // MARK: - Curves Section (sub-page host)

    private var curvesSection: some View {
        VStack(spacing: 0) {
            curvesSubNav
            Divider()

            Group {
                switch curveLabVM.curvesSubPage {
                case .gallery:
                    CurveGalleryView(viewModel: curveLabVM)

                case .creator:
                    if curveLabVM.showCreatorWizard {
                        CurveCreatorWizard(viewModel: curveLabVM)
                    } else {
                        CurveBuilderView(viewModel: curveLabVM)
                    }

                case .linearize:
                    CurveLinearizeView(viewModel: curveLabVM)

                case .blend:
                    CurveBlendView(viewModel: curveLabVM)

                case .remap:
                    CurveRemapView(viewModel: curveLabVM)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Curves Sub-Navigation

    private var curvesSubNav: some View {
        HStack(spacing: 2) {
            ForEach(CurvesSubPage.allCases) { subPage in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        curveLabVM.navigateToCurvesSubPage(subPage)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: subPage.icon)
                            .font(.system(size: 10))
                        Text(subPage.rawValue)
                            .font(.system(size: 10, weight: curveLabVM.curvesSubPage == subPage ? .semibold : .regular))
                    }
                    .foregroundStyle(curveLabVM.curvesSubPage == subPage ? .primary : .tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(curveLabVM.curvesSubPage == subPage ? Color.primary.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Session indicator
            if let session = curveLabVM.editSession {
                HStack(spacing: 4) {
                    Circle()
                        .fill(session.isDirty ? .orange : .green)
                        .frame(width: 6, height: 6)
                    Text(session.sourceFileName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if session.isDirty {
                        Text("(unsaved)")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Page Tab Strip

    private var pageTabStrip: some View {
        HStack(spacing: 2) {
            ForEach(PrintLabPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        curveLabVM.currentPage = page
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: page.icon)
                            .font(.system(size: 10))
                        Text(page.rawValue)
                            .font(.system(size: 10, weight: curveLabVM.currentPage == page ? .semibold : .regular))
                    }
                    .foregroundStyle(curveLabVM.currentPage == page ? .primary : .tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(curveLabVM.currentPage == page ? Color.primary.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
