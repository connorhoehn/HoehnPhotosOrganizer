import SwiftUI
import UniformTypeIdentifiers

struct SidebarRail: View {
    @Binding var selectedSection: AppSection
    @Binding var showImportWizard: Bool
    let onSettings: () -> Void
    let smartAlbums: [SavedSearchRule]
    let onSmartAlbumTap: (SavedSearchRule) -> Void
    let onCreateSmartAlbum: () -> Void
    var onDropToWorkflow: (([String]) -> Void)? = nil
    var onDropToPrintLab: (([String]) -> Void)? = nil
    @ObservedObject var peerSync: MacPeerSyncAdvertiser

    @State private var showSmartAlbumsPopover: Bool = false
    @State private var workflowDropTargeted: Bool = false
    @State private var printLabDropTargeted: Bool = false
    @State private var showSectionHelp: Bool = false

    private let sectionGuide: [(String, String, String)] = [
        ("Library",   "photo.on.rectangle",     "Browse, filter, and curate your photo collection"),
        ("Search",    "magnifyingglass",         "Find photos by content, date, location, or people"),
        ("Drives",    "externaldrive",           "Manage connected drives and volumes"),
        ("Jobs",      "tray.full",              "Import workflows, triage queues, and batch operations"),
        ("Print Lab", "printer",                "Layouts, linearization curves, and print processes"),
        ("Studio",    "paintbrush",             "Artistic rendering — oil, watercolor, charcoal, and more"),
        ("People",    "person.2",              "Face recognition, identity management, and grouping"),
        ("Activity",  "bell",                   "Recent events, workflow results, and system notifications"),
    ]

    private let navSections: [AppSection] = [.library, .search, .drives, .jobs, .printLab, .studio, .people, .activity]

    private let itemSize: CGFloat = 52
    private let iconPt: CGFloat = 13
    private let labelPt: CGFloat = 9
    private let cornerR: CGFloat = 11
    private let vGap: CGFloat = 6
    private let logoSize: CGFloat = 36
    private let logoCorner: CGFloat = 15

    var body: some View {
        VStack(spacing: vGap) {
                ZStack {
                    RoundedRectangle(cornerRadius: logoCorner, style: .continuous)
                        .fill(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: logoSize, height: logoSize)
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: iconPt * 1.1, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: vGap * 0.6) {
                    ForEach(navSections) { section in
                        let isDropTarget = (section == .jobs && workflowDropTargeted) ||
                                          (section == .printLab && printLabDropTargeted)
                        Button { selectedSection = section } label: {
                            VStack(spacing: 5) {
                                Image(systemName: section.systemImage)
                                    .font(.system(size: iconPt, weight: .semibold))
                                Text(section.title)
                                    .font(.system(size: labelPt, weight: .medium))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .frame(width: itemSize, height: itemSize)
                            .foregroundStyle(selectedSection == section || isDropTarget ? .white : .primary)
                            .background(
                                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                                    .fill(isDropTarget ? Color.accentColor.opacity(0.7) :
                                          selectedSection == section ? Color.accentColor : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                                    .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(section.sidebarHelpText)
                        .onDrop(of: [.plainText], isTargeted: section == .jobs ? $workflowDropTargeted : section == .printLab ? $printLabDropTargeted : .constant(false)) { providers in
                            guard section == .jobs || section == .printLab else { return false }
                            var ids: [String] = []
                            let group = DispatchGroup()
                            for provider in providers {
                                group.enter()
                                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                                    if let id = item as? String { ids.append(id) }
                                    group.leave()
                                }
                            }
                            group.notify(queue: .main) {
                                if section == .jobs { onDropToWorkflow?(ids) }
                                else if section == .printLab { onDropToPrintLab?(ids) }
                            }
                            return true
                        }
                    }
                }

                Spacer()

                // Sync status indicator
                syncIndicator

                Divider()
                    .padding(.horizontal, 10)

                Button {
                    showSectionHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 18))
                        .frame(width: itemSize, height: itemSize * 0.65)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Section guide")
                .popover(isPresented: $showSectionHelp, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Navigation Guide")
                            .font(.headline)
                            .padding(.bottom, 4)

                        ForEach(sectionGuide, id: \.0) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.1)
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.0).font(.subheadline.weight(.medium))
                                    Text(item.2).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(width: 280)
                }

                Button { onSettings() } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "gearshape")
                            .font(.system(size: iconPt, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: labelPt, weight: .medium))
                    }
                    .frame(width: itemSize, height: itemSize)
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .help("Settings — Configure app preferences and integrations")

                Button { showImportWizard = true } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: iconPt + 2, weight: .bold))
                        Text("Import")
                            .font(.system(size: labelPt, weight: .medium))
                    }
                    .frame(width: itemSize, height: itemSize)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                            .fill(.linearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 18)
        .frame(minWidth: itemSize + 16, maxWidth: itemSize + 16, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sync Indicator

    @ViewBuilder
    private var syncIndicator: some View {
        switch peerSync.state {
        case .idle:
            EmptyView()
        case .advertising:
            syncBadge(icon: "antenna.radiowaves.left.and.right", color: .orange, label: "Sync", pulse: true)
        case .pinConfirmation(_, _):
            syncBadge(icon: "lock.shield", color: .yellow, label: "PIN", pulse: true)
        case .connecting(_):
            syncBadge(icon: "arrow.triangle.2.circlepath", color: .orange, label: "Sync", pulse: true)
        case .connected(_):
            syncBadge(icon: "iphone", color: .green, label: "Ready")
        case .sending(let progress, _):
            VStack(spacing: 3) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            .frame(width: itemSize, height: itemSize * 0.7)
        case .completed(_):
            syncBadge(icon: "checkmark.circle.fill", color: .green, label: "Done")
        case .failed(_):
            syncBadge(icon: "exclamationmark.triangle", color: .red, label: "Error")
        }
    }

    private func syncBadge(icon: String, color: Color, label: String, pulse: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: pulse)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: itemSize, height: itemSize * 0.7)
    }
}

// MARK: - SmartAlbumPopoverView

struct SmartAlbumPopoverView: View {
    let albums: [SavedSearchRule]
    let onTap: (SavedSearchRule) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Smart Albums")
                    .font(.headline)
                Spacer()
                Button(action: onCreate) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if albums.isEmpty {
                Text("No smart albums yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(albums) { album in
                    Button {
                        onTap(album)
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(album.name)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280,
               minHeight: 160, idealHeight: 240, maxHeight: 400)
    }
}