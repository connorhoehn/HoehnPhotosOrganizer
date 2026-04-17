import SwiftUI
import UniformTypeIdentifiers

// MARK: - PrintJobThreadView

/// GitHub-issue-style threaded view for a print job activity.
///
/// Shows the print job header with thumbnail, configuration summary,
/// and a timeline of child events (notes, scans, AI summaries, print attempts).
/// Supports "Resume in Print Lab" to restore the full canvas from the snapshot,
/// "Duplicate Job" to start a new session from the same config, and
/// "Ask AI" to request an analysis of the thread.
struct PrintJobThreadView: View {

    let event: ActivityEvent
    let children: [ActivityEvent]
    let snapshot: PrintJobSnapshot?

    /// Called when user wants to restore this job in Print Lab.
    var onResume: ((PrintJobSnapshot) -> Void)?
    /// Called when user wants to add a note to this thread.
    var onAddNote: ((String) -> Void)?
    /// Called when user wants to attach a scan file.
    var onAttachScan: (() -> Void)?
    /// Called when user wants to apply AI curve revision suggestions.
    var onApplySuggestion: ((Double, Double) -> Void)?
    /// Called when user wants AI to summarize/analyze the thread.
    var onRequestAI: (() -> Void)?

    @State private var newComment = ""
    @State private var isHoveringResume = false
    @State private var showingScanPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            jobHeader
            Divider()

            // MARK: - Config summary (collapsed by default for users, but data is there)
            if let snap = snapshot {
                configSummary(snap)
                Divider()
            }

            // MARK: - Timeline
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        threadEntry(child)
                        if child.id != children.last?.id {
                            timelineConnector
                        }
                    }

                    if children.isEmpty {
                        emptyTimeline
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            // MARK: - Comment bar
            commentBar
        }
    }

    // MARK: - Job Header

    private var jobHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            // Thumbnail placeholder
            thumbnailView
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(event.title)
                    .font(.system(size: 17, weight: .bold))

                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Metadata pills
                HStack(spacing: 6) {
                    if let snap = snapshot {
                        pill(snap.isNegative ? "Digital Neg" : "Positive", color: .blue)
                        if let template = snap.templateName {
                            pill(template, color: .purple)
                        }
                        pill("\(Int(snap.paperWidth))×\(Int(snap.paperHeight))\"", color: .gray)
                        if snap.iccProfileName != nil {
                            pill("ICC", color: .green)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(event.occurredAt, format: .dateTime.month().day().year().hour().minute())
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    Text("·")
                        .foregroundStyle(.quaternary)

                    Text("\(children.count) update\(children.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Action buttons
            VStack(alignment: .trailing, spacing: 8) {
                if let snap = snapshot, let resume = onResume {
                    Button {
                        resume(snap)
                    } label: {
                        Label("Resume in Print Lab", systemImage: "printer.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if onRequestAI != nil {
                    Button {
                        onRequestAI?()
                    } label: {
                        Label("Ask AI", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Config Summary

    private func configSummary(_ snap: PrintJobSnapshot) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                configRow("Paper", "\(formatInches(snap.paperWidth)) × \(formatInches(snap.paperHeight))\" \(snap.isPortrait ? "Portrait" : "Landscape")")
                configRow("Margins", "L:\(formatInches(snap.marginLeft))\" R:\(formatInches(snap.marginRight))\" T:\(formatInches(snap.marginTop))\" B:\(formatInches(snap.marginBottom))\"")
                configRow("Color Mgmt", snap.colorMgmt)
                if let icc = snap.iccProfileName {
                    configRow("ICC Profile", icc)
                }
                if let intent = snap.renderingIntent {
                    configRow("Rendering", "\(intent)\(snap.blackPointCompensation ? " + BPC" : "")")
                }
                if let printer = snap.printerName {
                    configRow("Printer", printer)
                }
                configRow("Layers", "\(snap.images.count) placed")
                if snap.isNegative { configRow("Mode", "Digital Negative") }
                if snap.is16Bit { configRow("Depth", "16-bit") }
                if snap.softProofEnabled { configRow("Soft Proof", "Enabled") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Job Configuration")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func configRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
    }

    // MARK: - Timeline Entry

    private func threadEntry(_ child: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline dot
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(colorFor(child.kind).opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: symbolFor(child.kind))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colorFor(child.kind))
                }
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(authorLabel(child))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(actionLabel(child))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(child.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Body content
                switch child.kind {
                case .note:
                    if let detail = child.detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                    }

                case .scanAttachment:
                    scanAttachmentCard(child)

                case .aiSummary:
                    aiSummaryCard(child)

                case .printAttempt:
                    printAttemptCard(child)

                default:
                    if let detail = child.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Scan Attachment Card

    private func scanAttachmentCard(_ event: ActivityEvent) -> some View {
        HStack(spacing: 12) {
            // Scan thumbnail — try loading from metadata filePath
            scanThumbnail(for: event)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.04))
                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - AI Summary Card

    private func aiSummaryCard(_ event: ActivityEvent) -> some View {
        let suggestion = parseSuggestion(from: event.metadata)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("AI Analysis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(10)
            }
            if let (center, range) = suggestion, onApplySuggestion != nil {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested curve revision")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.purple)
                        Text("Center: \(center > 0 ? "+" : "")\(String(format: "%.0f", center * 100))%  Range: \u{00B1}\(String(format: "%.0f", range * 100))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onApplySuggestion?(center, range)
                    } label: {
                        Label("Apply & Open in Print Lab", systemImage: "printer.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.04))
                .stroke(Color.purple.opacity(0.15), lineWidth: 1)
        )
    }

    private func parseSuggestion(from metadata: String?) -> (Double, Double)? {
        guard let meta = metadata,
              let data = meta.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let center = dict["refinedBrightnessCenter"] as? Double,
              let range = dict["refinedRange"] as? Double else {
            return nil
        }
        return (center, range)
    }

    // MARK: - Print Attempt Card

    private func printAttemptCard(_ event: ActivityEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "printer.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Outcome badge placeholder
            Text("Testing")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.yellow.opacity(0.2)))
                .foregroundStyle(.orange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.04))
                .stroke(Color.green.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Timeline Connector

    private var timelineConnector: some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 2, height: 16)
                .padding(.leading, 35) // align with center of 32pt dot at 20pt horizontal padding
            Spacer()
        }
    }

    // MARK: - Empty Timeline

    private var emptyTimeline: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("No updates yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Add a note, attach a scan, or run the print to start the thread.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Comment Bar

    private var commentBar: some View {
        HStack(spacing: 10) {
            // Author avatar placeholder
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 28, height: 28)
                Text("C")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            TextField("Add a comment…", text: $newComment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit {
                    submitComment()
                }

            // Attach scan button
            Button {
                showingScanPicker = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach a scan or photo")
            .fileImporter(
                isPresented: $showingScanPicker,
                allowedContentTypes: [.jpeg, .tiff, .png, .pdf],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    handleScanAttachment(url: url)
                }
            }

            Button {
                submitComment()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private var thumbnailView: some View {
        // Use proxy thumbnail for the first image referenced in the snapshot
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.06))
            Image(systemName: "printer.dotmatrix.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green.opacity(0.4))
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func authorLabel(_ event: ActivityEvent) -> String {
        switch event.kind {
        case .aiSummary:       return "AI Assistant"
        case .scanAttachment:  return "Mobile"
        case .printAttempt:    return "System"
        case .note:            return "Connor"
        default:               return "System"
        }
    }

    private func actionLabel(_ event: ActivityEvent) -> String {
        switch event.kind {
        case .note:            return "commented"
        case .scanAttachment:  return "attached a scan"
        case .aiSummary:       return "analyzed the thread"
        case .printAttempt:    return "logged a print"
        case .adjustment:      return "made an adjustment"
        case .colorGrade:      return "applied color grade"
        default:               return "updated"
        }
    }

    private func symbolFor(_ kind: ActivityEventKind) -> String {
        switch kind {
        case .note:              return "text.bubble.fill"
        case .scanAttachment:    return "doc.viewfinder.fill"
        case .aiSummary:         return "sparkles"
        case .printAttempt:      return "printer.fill"
        case .adjustment:        return "slider.horizontal.3"
        case .colorGrade:        return "paintpalette.fill"
        default:                 return "circle.fill"
        }
    }

    private func colorFor(_ kind: ActivityEventKind) -> Color {
        switch kind {
        case .note:              return .yellow
        case .scanAttachment:    return .orange
        case .aiSummary:         return .purple
        case .printAttempt:      return .green
        case .adjustment:        return .blue
        case .colorGrade:        return .purple
        default:                 return .gray
        }
    }

    private func formatInches(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.2f", v)
    }

    private func submitComment() {
        let text = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAddNote?(text)
        newComment = ""
    }

    @ViewBuilder
    private func scanThumbnail(for event: ActivityEvent) -> some View {
        if let meta = event.metadata,
           let data = meta.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let filePath = dict["filePath"] as? String,
           let nsImage = NSImage(contentsOfFile: filePath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
                .frame(width: 60, height: 60)
                .overlay {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange.opacity(0.6))
                }
        }
    }

    /// Copy the picked file into App Support/Scans/ and invoke the attach callback.
    private func handleScanAttachment(url: URL) {
        let fm = FileManager.default
        let scansDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HoehnPhotosOrganizer/Scans", isDirectory: true)
        try? fm.createDirectory(at: scansDir, withIntermediateDirectories: true)
        let dest = scansDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        do {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            try fm.copyItem(at: url, to: dest)
        } catch {
            return
        }
        onAttachScan?()
    }
}

// MARK: - Preview

#Preview("PrintJobThreadView") {
    let rootEvent = ActivityEvent(
        id: "job-001",
        kind: .printJob,
        parentEventId: nil,
        photoAssetId: "photo-123",
        title: "Pt/Pd Print — Whitby Harbor",
        detail: "Platinum Palladium on Arches Platine, 11×14\", curve v7",
        metadata: nil,
        occurredAt: Date(timeIntervalSinceNow: -7200),
        createdAt: Date()
    )

    let children: [ActivityEvent] = [
        ActivityEvent(
            id: "child-1", kind: .printAttempt, parentEventId: "job-001",
            photoAssetId: "photo-123",
            title: "Print sent to Epson P900",
            detail: "ICC: HahnemulePlatine · Relative + BPC · Calibration Strip 4×2",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -7100),
            createdAt: Date()
        ),
        ActivityEvent(
            id: "child-2", kind: .note, parentEventId: "job-001",
            photoAssetId: nil,
            title: "Connor commented",
            detail: "Tile 7 looked best — highlights are clean, shadow separation is good. Slight warmth in the midtones that I like.",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -6000),
            createdAt: Date()
        ),
        ActivityEvent(
            id: "child-3", kind: .scanAttachment, parentEventId: "job-001",
            photoAssetId: nil,
            title: "Target scan from iPhone",
            detail: "SpyderPrint target — 24 patches, scanned under D50",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -3600),
            createdAt: Date()
        ),
        ActivityEvent(
            id: "child-4", kind: .aiSummary, parentEventId: "job-001",
            photoAssetId: nil,
            title: "AI analyzed the thread",
            detail: "Print job is a Pt/Pd contact print on Arches Platine using curve v7. Calibration strip shows tile 7 (B +14%) as the winner with clean highlights and good shadow separation. Target scan attached — 24 patches under D50. Suggest: run curve revision with +14% brightness offset as the new center point, narrowing the grid to ±5% for fine-tuning.",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -3500),
            createdAt: Date()
        ),
        ActivityEvent(
            id: "child-5", kind: .note, parentEventId: "job-001",
            photoAssetId: nil,
            title: "Connor commented",
            detail: "Going to reprint with the refined grid tomorrow. Coating is drying overnight.",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -1800),
            createdAt: Date()
        ),
    ]

    let snapshot = PrintJobSnapshot(
        paperWidth: 14, paperHeight: 11, isPortrait: false,
        marginLeft: 0.5, marginRight: 0.5, marginTop: 0.5, marginBottom: 0.5,
        templateName: "Calibration Strip 4×2", templateJSON: nil,
        colorMgmt: "ColorSync Managed",
        iccProfilePath: "/Library/ColorSync/Profiles/HahnemulePlatine.icc",
        iccProfileName: "Hahnemule Platine",
        renderingIntent: "relative", blackPointCompensation: true,
        printerName: "EPSON SC-P900", isNegative: true,
        is16Bit: true, simulateInkBlack: false, flipEmulsion: false,
        softProofEnabled: true, softProofProfilePath: nil,
        softProofIntent: "relative", softProofBPC: true,
        images: [
            .init(photoAssetId: "photo-123", canonicalName: "whitby_harbor_001.dng",
                  positionX: 0.5, positionY: 0.5, width: 10, height: 8,
                  rotation: 0, aspectRatioLocked: true,
                  borderWidthInches: 0, borderIsWhite: false,
                  iccProfilePath: nil, brightnessOffset: 0.14, saturationOffset: 0,
                  tileLabel: nil, groupLabel: nil)
        ],
        printAttemptId: "attempt-001"
    )

    PrintJobThreadView(
        event: rootEvent,
        children: children,
        snapshot: snapshot,
        onResume: { _ in },
        onAddNote: { _ in },
        onAttachScan: {},
        onApplySuggestion: { _, _ in },
        onRequestAI: {}
    )
    .frame(width: 600, height: 700)
}
