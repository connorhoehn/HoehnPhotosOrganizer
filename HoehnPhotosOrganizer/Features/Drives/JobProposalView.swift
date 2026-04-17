import SwiftUI

// MARK: - JobProposalView

/// Shown after a drive scan completes, before the import begins.
/// Displays AI-proposed job buckets as editable cards for user review.
struct JobProposalView: View {

    let proposals: [ProposedJob]
    @Binding var approvedJobs: [ProposedJob]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    // Track which titles the user has edited inline
    @State private var editingTitles: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            jobList
            Divider()
            footerView
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Pre-populate approved list with all proposals
            if approvedJobs.isEmpty {
                approvedJobs = proposals
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Proposed Import Jobs")
                .font(.headline)
            Text("Claude analysed the scan and suggested \(proposals.count) job\(proposals.count == 1 ? "" : "s"). Edit titles, remove any you don't want, then confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Job list

    private var jobList: some View {
        ScrollView {
            VStack(spacing: 10) {
                if approvedJobs.isEmpty {
                    Text("All proposed jobs removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach($approvedJobs) { $job in
                        JobCard(job: $job, onDelete: {
                            approvedJobs.removeAll { $0.id == job.id }
                        })
                    }
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Skip / Import Without Jobs") { onCancel() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)

            Spacer()

            let count = approvedJobs.count
            Button("Confirm \(count) Job\(count == 1 ? "" : "s")") {
                onConfirm()
            }
            .buttonStyle(.borderedProminent)
            .disabled(approvedJobs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - JobCard

private struct JobCard: View {

    @Binding var job: ProposedJob
    let onDelete: () -> Void

    @State private var isEditingTitle = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Kind badge
            kindIcon
                .frame(width: 32, height: 32)
                .background(kindColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                // Editable title
                if isEditingTitle {
                    TextField("Job title", text: $job.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { isEditingTitle = false }
                } else {
                    Text(job.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            isEditingTitle = true
                            titleFocused   = true
                        }
                }

                Text(job.rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    kindBadge
                    Text("\(job.photoCount) photo\(job.photoCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let range = job.dateRange {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(dateRangeLabel(range))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this job proposal")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Kind visuals

    private var kindIcon: some View {
        Image(systemName: kindSystemImage)
            .font(.system(size: 15))
            .foregroundStyle(kindColor)
    }

    private var kindBadge: some View {
        Text(kindLabel)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(kindColor.opacity(0.15))
            .foregroundStyle(kindColor)
            .clipShape(Capsule())
    }

    private var kindSystemImage: String {
        switch job.jobKind {
        case .timeCluster:     return "clock"
        case .locationCluster: return "map.pin"
        case .filmScan:        return "film"
        case .catchAll:        return "tray"
        }
    }

    private var kindColor: Color {
        switch job.jobKind {
        case .timeCluster:     return .blue
        case .locationCluster: return .green
        case .filmScan:        return .purple
        case .catchAll:        return .orange
        }
    }

    private var kindLabel: String {
        switch job.jobKind {
        case .timeCluster:     return "Time"
        case .locationCluster: return "Location"
        case .filmScan:        return "Film"
        case .catchAll:        return "Mixed"
        }
    }

    // MARK: - Date range label

    private func dateRangeLabel(_ interval: DateInterval) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        if Calendar.current.isDate(interval.start, inSameDayAs: interval.end) {
            return df.string(from: interval.start)
        }
        return "\(df.string(from: interval.start)) – \(df.string(from: interval.end))"
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    let iso = ISO8601DateFormatter()
    let proposals: [ProposedJob] = [
        ProposedJob(
            title: "Scotland Trip — Day 1",
            rationale: "42 photos from same GPS cluster, March 15",
            photoCount: 42,
            representativePhotoIds: ["a1","a2","a3"],
            dateRange: DateInterval(
                start: iso.date(from: "2024-03-15T09:00:00Z")!,
                end:   iso.date(from: "2024-03-15T18:30:00Z")!
            ),
            jobKind: .locationCluster
        ),
        ProposedJob(
            title: "Scotland Trip — Day 2",
            rationale: "31 photos from March 16",
            photoCount: 31,
            representativePhotoIds: ["b1","b2"],
            dateRange: DateInterval(
                start: iso.date(from: "2024-03-16T08:00:00Z")!,
                end:   iso.date(from: "2024-03-16T20:00:00Z")!
            ),
            jobKind: .timeCluster
        ),
        ProposedJob(
            title: "Film Scan Roll",
            rationale: "12 photos with no EXIF date — likely film scans",
            photoCount: 12,
            representativePhotoIds: ["c1","c2"],
            dateRange: nil,
            jobKind: .filmScan
        )
    ]
    @State var approved = proposals
    return JobProposalView(
        proposals: proposals,
        approvedJobs: $approved,
        onConfirm: {},
        onCancel: {}
    )
}
#endif
