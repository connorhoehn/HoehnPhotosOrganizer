// SyncToolbarIndicator.swift
// HoehnPhotosOrganizer
//
// Compact cloud sync indicator for the main toolbar strip.
// Reads from SyncProgressViewModel via @EnvironmentObject.
// Tap to show a dense popover with sync details and "Sync Now" button.

import SwiftUI

struct SyncToolbarIndicator: View {
    @EnvironmentObject private var syncProgress: SyncProgressViewModel
    @State private var showPopover = false

    var body: some View {
        switch syncProgress.overallState {
        case .disabled:
            EmptyView()

        case .idle:
            cloudButton {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            }

        case .syncing:
            cloudButton {
                HStack(spacing: 4) {
                    Image(systemName: "cloud")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse)
                    if syncProgress.queueDepth > 0 {
                        Text(progressLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

        case .error:
            cloudButton {
                ZStack {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.white)
                        .offset(x: 5, y: 5)
                }
            }

        case .paused:
            cloudButton {
                Image(systemName: "cloud")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var progressLabel: String {
        let completed: Int
        let total: Int
        switch syncProgress.progressFraction {
        case let f where f > 0 && f < 1:
            // Derive from queue depth as best approximation
            total = syncProgress.queueDepth
            completed = Int(f * Double(total))
            return "\(completed)/\(total)"
        default:
            return "\(syncProgress.queueDepth)"
        }
    }

    private func cloudButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button {
            showPopover.toggle()
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .help("Cloud sync status")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            syncPopover
        }
    }

    // MARK: - Popover

    private var syncPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Last sync time
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let lastSync = syncProgress.lastSyncTime {
                    Text(lastSync, style: .relative)
                        .font(.caption)
                } else {
                    Text("Never synced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Queue depth
            if syncProgress.queueDepth > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(syncProgress.queueDepth) queued")
                        .font(.caption)
                }
            }

            // Current phase (when syncing)
            if !syncProgress.currentPhase.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(syncProgress.currentPhase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Error message
            if let error = syncProgress.lastError {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Divider()

            // Sync Now button
            Button {
                NotificationCenter.default.post(name: .syncNowRequested, object: nil)
                showPopover = false
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 220)
    }
}
