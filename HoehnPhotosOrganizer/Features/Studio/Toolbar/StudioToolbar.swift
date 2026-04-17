import SwiftUI

// MARK: - StudioToolbar

/// Horizontal toolbar for the Studio tab. Shows the medium picker,
/// medium-specific parameter controls, and render/undo actions.
struct StudioToolbar: View {
    @ObservedObject var viewModel: StudioViewModel
    @Binding var showComparison: Bool
    @Binding var pbnActive: Bool
    @State private var showUndoHistory = false

    var body: some View {
        HStack(spacing: 0) {
            // Source image tools
            sourceTools
            toolbarDivider

            // Medium picker
            mediumPicker
            toolbarDivider

            // Medium-specific controls (isolated to prevent re-renders from unrelated ViewModel changes)
            ScrollView(.horizontal, showsIndicators: false) {
                StudioMediumControlsView(params: viewModel.mediumParams) { newParams, name in
                    viewModel.updateParams(newParams, commandName: name)
                }
            }

            Spacer(minLength: 4)
            toolbarDivider

            // Undo/Redo
            undoRedoGroup
                .fixedSize()

            // Actions group (visible after render)
            if viewModel.renderedImage != nil {
                toolbarDivider
                actionsGroup
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .transaction { $0.animation = nil }
    }

    // MARK: - Source Tools

    private var sourceTools: some View {
        HStack(spacing: 2) {
            Button {
                viewModel.showingCropTool = true
            } label: {
                Image(systemName: "crop")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.sourceImage == nil)
            .help("Crop Image")
        }
    }

    // MARK: - Medium Picker

    private var mediumPicker: some View {
        Menu {
            ForEach(ArtMedium.allCases) { medium in
                Button {
                    viewModel.selectMedium(medium)
                } label: {
                    Label(medium.rawValue, systemImage: medium.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.selectedMedium.icon)
                    .font(.system(size: 11))
                Text(viewModel.selectedMedium.rawValue)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Undo / Redo

    private var undoRedoGroup: some View {
        HStack(spacing: 0) {
            studioToolbarButton(
                icon: "arrow.uturn.backward", label: "Undo",
                help: viewModel.commandStack.undoName.map { "Undo \($0)" } ?? "Nothing to undo",
                enabled: viewModel.commandStack.canUndo
            ) { viewModel.commandStack.undo() }

            studioToolbarButton(
                icon: "arrow.uturn.forward", label: "Redo",
                help: viewModel.commandStack.redoName.map { "Redo \($0)" } ?? "Nothing to redo",
                enabled: viewModel.commandStack.canRedo
            ) { viewModel.commandStack.redo() }

            studioToolbarButton(
                icon: "clock.arrow.circlepath", label: "History",
                help: "Undo History",
                enabled: !viewModel.commandStack.commands.isEmpty
            ) { showUndoHistory.toggle() }
            .popover(isPresented: $showUndoHistory) {
                UndoHistoryPanel(commandStack: viewModel.commandStack, viewModel: viewModel)
            }
            .onChange(of: showUndoHistory) { _, isShowing in
                if !isShowing { viewModel.restoreFromUndoPreview() }
            }
        }
    }

    // MARK: - Actions Group

    private var actionsGroup: some View {
        HStack(spacing: 0) {
            studioToolbarButton(
                icon: "square.dashed", label: "Contours",
                help: viewModel.showContours ? "Hide Contours" : "Show Contours",
                isActive: viewModel.showContours
            ) {
                viewModel.showContours.toggle()
                if !viewModel.showContours { viewModel.showNumbers = false }
                // Only render when toggling ON — toggling OFF just hides the overlay
                if viewModel.showContours { viewModel.generateOverlay() }
            }

            studioToolbarButton(
                icon: "number.square", label: "Numbers",
                help: viewModel.showNumbers ? "Hide Numbers" : "Show Numbers",
                isActive: viewModel.showNumbers
            ) {
                viewModel.showNumbers.toggle()
                if viewModel.showNumbers { viewModel.showContours = true }
                // Only render when toggling ON — toggling OFF just hides the overlay
                if viewModel.showNumbers { viewModel.generateOverlay() }
            }

            studioToolbarButton(
                icon: showComparison ? "rectangle.split.2x1" : "rectangle.lefthalf.inset.filled",
                label: "Compare",
                help: showComparison ? "Hide Comparison" : "Before / After",
                isActive: showComparison
            ) { showComparison.toggle() }

            toolbarDivider

            studioToolbarButton(
                icon: "square.and.arrow.down", label: "Save",
                help: "Save Version"
            ) { viewModel.saveVersion(name: viewModel.selectedMedium.rawValue) }

            studioToolbarButton(
                icon: "square.and.arrow.up", label: "Export",
                help: "Export"
            ) { viewModel.exportRenderedImage() }

            studioToolbarButton(
                icon: "printer.fill", label: "Print",
                help: "Send to Print Lab"
            ) {
                if let image = viewModel.renderedImage {
                    NotificationCenter.default.post(
                        name: .studioSendToPrintLab,
                        object: nil,
                        userInfo: [
                            "image": image,
                            "sourcePhotoId": viewModel.sourcePhotoId as Any,
                            "medium": viewModel.selectedMedium.rawValue,
                            "renderDate": Date()
                        ]
                    )
                }
            }

        }
    }

    // MARK: - Toolbar Button

    private func studioToolbarButton(
        icon: String, label: String, help: String,
        isActive: Bool = false, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
            }
            .foregroundStyle(isActive ? Color.accentColor : (enabled ? Color.primary : Color.secondary.opacity(0.4)))
            .frame(width: 44, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Helpers

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 24)
            .padding(.horizontal, 8)
    }

}
