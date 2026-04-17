// ConflictBannerView.swift
// HoehnPhotosOrganizer
//
// Non-modal banner that appears at the top of the workspace when a sync conflict
// is resolved. Shows "IMG_1234 edited on another device" with auto-dismiss after
// 5 seconds. Reads from SyncProgressViewModel.pendingConflicts.

import SwiftUI
import Combine

// MARK: - ConflictBannerView

struct ConflictBannerView: View {
    @ObservedObject var viewModel: SyncProgressViewModel

    var body: some View {
        if let notification = viewModel.pendingConflicts.first {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)

                Text("\(notification.photoId) edited on another device")
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                Button("Dismiss") {
                    withAnimation {
                        viewModel.dismissFirst()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notification.photoId) {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation {
                    viewModel.dismissFirst()
                }
            }
        }
    }
}
