import AppKit
import CoreGraphics
import Foundation

/// A single film frame detected within a scan, pending user review before import.
///
/// `@unchecked Sendable` because `NSImage` is a reference type that is not `Sendable`.
/// Instances are created on a background thread and then only read on the main actor.
struct DetectedFrame: Identifiable, @unchecked Sendable {
    let id: UUID
    /// Source scan file this frame was detected in.
    let sourceScanURL: URL
    /// Frame bounding rect in source image pixel coordinates (top-left origin).
    let cropRect: CGRect
    /// Downsampled thumbnail for display in the review grid.
    let thumbnail: NSImage
    /// 1-based index within the source scan.
    let frameIndex: Int
    /// Whether the user has chosen to keep (import) this frame.
    var isKept: Bool = true

    /// Short identifier shown in the review grid (e.g. "Roll_001_03").
    var displayName: String {
        let base = sourceScanURL.deletingPathExtension().lastPathComponent
        return String(format: "%@_%02d", base, frameIndex)
    }

    /// Label identifying which scan this frame comes from.
    var scanLabel: String {
        sourceScanURL.deletingPathExtension().lastPathComponent
    }
}
