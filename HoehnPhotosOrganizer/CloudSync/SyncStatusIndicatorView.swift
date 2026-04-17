// SyncStatusIndicatorView.swift
// HoehnPhotosOrganizer
//
// Badge view for per-photo sync status. Displayed in the DETAIL PANEL ONLY.
// Per CONTEXT.md: sync status does NOT appear on photo grid cells.
//
// Icons:
//   localOnly   — minus.circle (secondary)
//   syncing     — ProgressView + percentage text
//   synced      — cloud.fill (green)
//   error       — exclamationmark.triangle.fill (orange)

import SwiftUI

struct SyncStatusIndicatorView: View {
    @ObservedObject var viewModel: SyncStatusViewModel
    var size: CGFloat = 16

    var body: some View {
        switch viewModel.syncStatus {
        case .localOnly:
            Image(systemName: "minus.circle")
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .help("Local only — not synced to cloud")

        case .syncing(let progress):
            HStack(spacing: 4) {
                ProgressView(value: progress)
                    .frame(width: 40)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .synced(let timestamp):
            Image(systemName: "cloud.fill")
                .font(.system(size: size))
                .foregroundStyle(.green)
                .help("Synced \(timestamp.formatted(.relative(presentation: .named)))")

        case .error(let reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: size))
                .foregroundStyle(.orange)
                .help("Sync error: \(reason)")
        }
    }
}
