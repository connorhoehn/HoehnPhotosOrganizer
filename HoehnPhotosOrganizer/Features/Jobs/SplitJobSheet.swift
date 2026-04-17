import SwiftUI

// MARK: - SplitJobSheet

/// Shown when the user clicks "Split Job" on a large job.
/// Two-step flow:
///   1. Review — AI-proposed clusters displayed as editable cards (rename, remove).
///   2. Confirm — summary of what will be created, with a final commit button.
/// On confirm, creates child TriageJobs under the parent and reassigns photos.
struct SplitJobSheet: View {

    let parentJob: TriageJob
    let photos: [PhotoAsset]
    let onComplete: () async -> Void

    @Environment(\.appDatabase) private var db
    @Environment(\.dismiss) private var dismiss
    @Environment(\.activityEventService) private var activityService

    @State private var clusters: [PhotoCluster] = []
    @State private var isAnalysing = true
    @State private var isCreating = false
    @State private var showConfirmation = false
    @State private var error: String?

    private let bucketingService = JobBucketingService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()

            if isAnalysing {
                analysingView
            } else if isCreating {
                creatingView
            } else if let error {
                errorView(error)
            } else if clusters.isEmpty {
                noSplitView
            } else if showConfirmation {
                confirmationView
            } else {
                clusterList
            }

            Divider()
            footerView
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await analyse() }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(showConfirmation ? "Confirm Split" : "Split Job into Sub-Jobs")
                .font(.headline)
            if showConfirmation {
                Text("Review the summary below before creating sub-jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Analysing \(photos.count) photos by time and location to propose focused sub-jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - States

    private var analysingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Clustering photos by time gaps and GPS location...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private var creatingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Creating \(clusters.count) sub-jobs...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private var noSplitView: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("All photos appear to be from a single session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("No split is recommended.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - Cluster List (Step 1: Review & Rename)

    private var clusterList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(clusters.indices, id: \.self) { idx in
                    ClusterCard(
                        cluster: $clusters[idx],
                        index: idx + 1,
                        onRemove: { clusters.remove(at: idx) }
                    )
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 400)
    }

    // MARK: - Confirmation View (Step 2: Summary)

    private var confirmationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Summary line
            let totalPhotos = clusters.reduce(0) { $0 + $1.photoCount }
            Text("Will create \(clusters.count) sub-job\(clusters.count == 1 ? "" : "s") from \(totalPhotos) photos:")
                .font(.callout.weight(.medium))

            // Sub-job list
            ForEach(clusters.indices, id: \.self) { idx in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 24, height: 24)
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(clusters[idx].suggestedTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(clusters[idx].photoCount) photo\(clusters[idx].photoCount == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if let range = clusters[idx].dateRange {
                        Text(confirmDateLabel(range))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            // Warning about parent job
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Photos will be moved into sub-jobs. The parent job \"\(parentJob.title)\" will remain as a container.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(20)
    }

    private func confirmDateLabel(_ interval: DateInterval) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        if Calendar.current.isDate(interval.start, inSameDayAs: interval.end) {
            return df.string(from: interval.start)
        }
        return "\(df.string(from: interval.start)) – \(df.string(from: interval.end))"
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if showConfirmation {
                Button("Back") {
                    showConfirmation = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Spacer()

            if !isAnalysing && !isCreating && !clusters.isEmpty {
                if showConfirmation {
                    let count = clusters.count
                    Button("Create \(count) Sub-Job\(count == 1 ? "" : "s")") {
                        Task { await createSubJobs() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    let count = clusters.count
                    Button("Review \(count) Sub-Job\(count == 1 ? "" : "s")") {
                        showConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clusters.isEmpty)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Analysis

    private func analyse() async {
        let timestamps = JobBucketingService.extractTimestamps(
            from: photos.map { (id: $0.id, rawExifJson: $0.rawExifJson) }
        )
        let proposed = await bucketingService.proposeCluster(photos: timestamps, enableAINaming: true)

        // Only show split UI if > 1 cluster
        if proposed.count <= 1 {
            clusters = []
        } else {
            clusters = proposed
        }
        isAnalysing = false
    }

    // MARK: - Create Sub-Jobs

    private func createSubJobs() async {
        guard let database = db, !clusters.isEmpty else { return }
        isCreating = true
        showConfirmation = false

        let jobRepo = TriageJobRepository(db: database)

        for cluster in clusters {
            let child = TriageJob.newChildJob(
                parentId: parentJob.id,
                title: cluster.suggestedTitle,
                photoCount: cluster.photoCount,
                source: .split
            )
            do {
                try await jobRepo.insert(child)
                try await jobRepo.addPhotos(jobId: child.id, photoIds: cluster.photoIds)
            } catch {
                print("[SplitJob] Failed to create child job '\(cluster.suggestedTitle)': \(error)")
            }
        }

        // Fire-and-forget activity event — never blocks split completion.
        if let activityService {
            let parentId = parentJob.id
            let parentTitle = parentJob.title
            let childCount = clusters.count
            Task { try? await activityService.emitJobSplit(parentJobId: parentId, parentTitle: parentTitle, childCount: childCount) }
        }

        await onComplete()
        // Dismiss after onComplete finishes so the parent view has
        // already reloaded jobs/children before the sheet animates away.
        // A tiny yield lets SwiftUI process the state updates from
        // onComplete before the dismiss animation begins, avoiding a
        // race where the list refreshes before new children are visible.
        try? await Task.sleep(for: .milliseconds(150))
        dismiss()
    }
}

// MARK: - ClusterCard

private struct ClusterCard: View {
    @Binding var cluster: PhotoCluster
    let index: Int
    let onRemove: () -> Void

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Cluster number badge
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Text("\(index)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Always-editable inline title
                TextField("Sub-job title", text: $cluster.suggestedTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($titleFocused)

                HStack(spacing: 8) {
                    Text("\(cluster.photoCount) photo\(cluster.photoCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    if let range = cluster.dateRange {
                        Text("\u{00B7}")
                            .foregroundStyle(.quaternary)
                        Text(dateRangeLabel(range))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    if cluster.centroidLatitude != nil {
                        Image(systemName: "location.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.green.opacity(0.6))
                    }
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this sub-job (photos stay in parent)")
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
