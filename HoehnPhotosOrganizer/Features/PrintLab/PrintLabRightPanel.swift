import SwiftUI
import AppKit

// MARK: - PrintLabRightPanel

/// Right panel of the redesigned Print Lab.
/// Four collapsible sections: Printer, Color Management, Position & Scaling, Page Setup.
/// Plus a Print History section at the bottom.
/// All sections start collapsed (viewModel booleans default to false).
struct PrintLabRightPanel: View {

    @ObservedObject var viewModel: PrintLabViewModel
    let onPageSetup: () -> Void   // calls NSPageLayout.runModal — owned by PrintLabView

    @Environment(\.appDatabase) private var appDatabase

    /// Becomes true whenever a technical setting changes; cleared on explicit Save.
    @State private var hasUnsavedChanges = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                printerSection
                Divider()
                colorManagementSection
                Divider()
                positionScalingSection
                Divider()
                pageSetupSection
                Divider()
                printHistorySection
                Spacer()
            }
        }
        .frame(width: 240)
        .background(Color(nsColor: .controlBackgroundColor))
        // Track technical setting changes that should be explicitly saved
        .onChange(of: viewModel.colorMgmt)         { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.iccProfileURL)     { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.relativeIntent)    { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.blackPoint)        { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.selectedPrinterName) { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.isNegative)        { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.is16Bit)           { withAnimation { hasUnsavedChanges = true } }
        .onChange(of: viewModel.simulateInkBlack)  { withAnimation { hasUnsavedChanges = true } }
    }

    // MARK: - Printer Section (PRT-5)

    private var printerSection: some View {
        PrintLabPanelSection(title: "Printer", isExpanded: $viewModel.printerExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Printer", selection: $viewModel.selectedPrinterName) {
                    ForEach(viewModel.availablePrinters, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()

                Toggle("Digital Negative", isOn: $viewModel.isNegative)
                    .font(.system(size: 11))
                Toggle("16-bit Output", isOn: $viewModel.is16Bit)
                    .font(.system(size: 11))
                Toggle("Simulate Ink Black", isOn: $viewModel.simulateInkBlack)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Color Management + ICC (PRINT-CANVAS-8)

    private var colorManagementSection: some View {
        PrintLabPanelSection(
            title: "Color Management",
            isExpanded: $viewModel.colorExpanded,
            hasUnsavedChanges: hasUnsavedChanges,
            onSave: hasUnsavedChanges ? { saveSettings() } : nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Color Mgmt", selection: $viewModel.colorMgmt) {
                    Text("No Color Management").tag("No Color Management")
                    Text("ColorSync Managed").tag("ColorSync Managed")
                    Text("Printer Manages Colors").tag("Printer Manages Colors")
                }
                .labelsHidden()
                .pickerStyle(.menu)

                // ICC profile picker — only visible when ColorSync is selected
                if viewModel.colorMgmt == "ColorSync Managed" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ICC Profile")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Picker("ICC Profile", selection: $viewModel.iccProfileURL) {
                            Text("None").tag(Optional<URL>.none)
                            ForEach(viewModel.availableICCProfiles, id: \.self) { url in
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .tag(Optional(url))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Toggle("Relative Colorimetric", isOn: $viewModel.relativeIntent)
                            .font(.system(size: 11))
                        Toggle("Black Point Compensation", isOn: $viewModel.blackPoint)
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Position & Scaling (PRINT-CANVAS-7)

    private var positionScalingSection: some View {
        PrintLabPanelSection(title: "Position & Scaling", isExpanded: $viewModel.positionExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let img = viewModel.selectedImage {
                    // Width + height with aspect lock
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("W (in)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TextField("Width", value: Binding<Double>(
                                get: { Double(img.size.width) },
                                set: { newW in viewModel.applyWidthChange(CGFloat(newW), imageID: img.id) }
                            ), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        }

                        Image(systemName: img.aspectRatioLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 12))
                            .foregroundStyle(img.aspectRatioLocked ? Color.accentColor : .secondary)
                            .onTapGesture {
                                if var updated = viewModel.selectedImage {
                                    updated.aspectRatioLocked.toggle()
                                    viewModel.updateCanvasImage(updated)
                                }
                            }
                            .help(img.aspectRatioLocked
                                  ? "Aspect ratio locked — tap to unlock"
                                  : "Aspect ratio unlocked — tap to lock")

                        VStack(alignment: .leading, spacing: 2) {
                            Text("H (in)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TextField("Height", value: Binding<Double>(
                                get: { Double(img.size.height) },
                                set: { newH in
                                    if var updated = viewModel.selectedImage {
                                        updated.size.height = CGFloat(newH)
                                        viewModel.updateCanvasImage(updated)
                                    }
                                }
                            ), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .disabled(img.aspectRatioLocked)
                            .foregroundStyle(img.aspectRatioLocked ? .secondary : .primary)
                        }
                    }

                    // Position fields
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("X (in)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TextField("X", value: Binding<Double>(
                                get: { Double(img.position.x) },
                                set: { newX in
                                    if var updated = viewModel.selectedImage {
                                        updated.position.x = CGFloat(newX)
                                        viewModel.updateCanvasImage(updated)
                                    }
                                }
                            ), format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Y (in)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            TextField("Y", value: Binding<Double>(
                                get: { Double(img.position.y) },
                                set: { newY in
                                    if var updated = viewModel.selectedImage {
                                        updated.position.y = CGFloat(newY)
                                        viewModel.updateCanvasImage(updated)
                                    }
                                }
                            ), format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        }
                    }

                    // Rotation
                    HStack {
                        Text("Rotation (\u{00B0})")
                            .font(.system(size: 11))
                        Spacer()
                        TextField("0", value: Binding(
                            get: { img.rotation },
                            set: { newR in
                                if var updated = viewModel.selectedImage {
                                    updated.rotation = newR
                                    viewModel.updateCanvasImage(updated)
                                }
                            }
                        ), format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    }
                } else {
                    Text("Select an image on the canvas to adjust position and size.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                }

                Divider()

                // Margins
                Text("Margins (in)")
                    .font(.system(size: 11, weight: .medium))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    RightPanelLabeledTextField("Left",   value: $viewModel.marginLeft)
                    RightPanelLabeledTextField("Right",  value: $viewModel.marginRight)
                    RightPanelLabeledTextField("Top",    value: $viewModel.marginTop)
                    RightPanelLabeledTextField("Bottom", value: $viewModel.marginBottom)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Page Setup

    private var pageSetupSection: some View {
        PrintLabPanelSection(title: "Page Setup", isExpanded: $viewModel.pageSetupExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paper size")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f \u{00D7} %.2f in",
                                    viewModel.paperWidth, viewModel.paperHeight))
                            .font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                    Button("Page Setup\u{2026}") { onPageSetup() }
                        .font(.system(size: 11))
                }

                // Portrait / Landscape toggle
                Picker("Orientation", selection: $viewModel.isPortrait) {
                    Image(systemName: "rectangle.portrait").tag(true).help("Portrait")
                    Image(systemName: "rectangle.landscape").tag(false).help("Landscape")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Canvas zoom
                HStack {
                    Text("Zoom").font(.system(size: 11))
                    Slider(value: $viewModel.magnify, in: 0.2...2.0)
                    Text(String(format: "%.0f%%", viewModel.magnify * 100))
                        .font(.system(size: 10))
                        .frame(width: 32, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Save Settings

    /// Persists technical settings to UserDefaults and clears the unsaved-changes indicator.
    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(viewModel.colorMgmt, forKey: "printLab.colorMgmt")
        defaults.set(viewModel.iccProfileURL?.absoluteString, forKey: "printLab.iccProfileURL")
        defaults.set(viewModel.relativeIntent, forKey: "printLab.relativeIntent")
        defaults.set(viewModel.blackPoint, forKey: "printLab.blackPoint")
        defaults.set(viewModel.selectedPrinterName, forKey: "printLab.selectedPrinterName")
        defaults.set(viewModel.isNegative, forKey: "printLab.isNegative")
        defaults.set(viewModel.is16Bit, forKey: "printLab.is16Bit")
        defaults.set(viewModel.simulateInkBlack, forKey: "printLab.simulateInkBlack")
        withAnimation(.easeInOut(duration: 0.2)) {
            hasUnsavedChanges = false
        }
    }

    // MARK: - Print History (PRT-7)

    private var printHistorySection: some View {
        PrintLabPanelSection(title: "Print History", isExpanded: .constant(false)) {
            if let photo = viewModel.canvasImages.first?.photoAsset,
               let db = appDatabase {
                PrintTimelineView(photoId: photo.id, db: db.dbPool)
                    .padding(.horizontal, 8)
            } else {
                Text("Select an image to see print history.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

// MARK: - PrintLabPanelSection

/// Reusable disclosure-style section header for the right panel.
/// Collapsed by default — caller passes @Published binding that defaults to false.
/// When `onSave` is non-nil, displays an orange unsaved-changes dot and a Save button.
struct PrintLabPanelSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var hasUnsavedChanges: Bool = false
    var onSave: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                // Toggle button fills the full header row
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)

                        if hasUnsavedChanges {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .transition(.scale.combined(with: .opacity))
                        }

                        Spacer()

                        // Invisible spacer to push chevron left of where Save button will sit
                        if hasUnsavedChanges && onSave != nil {
                            Color.clear.frame(width: 44)
                        }

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                // Save button overlaid at trailing edge — separate from toggle hit area
                if hasUnsavedChanges, let save = onSave {
                    Button("Save") {
                        save()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .padding(.trailing, 28) // leave room for the chevron
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - RightPanelLabeledTextField

private struct RightPanelLabeledTextField: View {
    let label: String
    @Binding var value: CGFloat

    init(_ label: String, value: Binding<CGFloat>) {
        self.label = label
        self._value = value
    }

    private var doubleBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(value) },
            set: { value = CGFloat($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(label, value: doubleBinding, format: .number.precision(.fractionLength(3)))
                .textFieldStyle(.roundedBorder)
        }
    }
}
