import SwiftUI

// MARK: - SearchCommandPalette

/// Full-screen overlay command palette. Triggered by ⌘K.
/// Accepts text or live voice input and routes to SearchExperienceView.
struct SearchCommandPalette: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: LibraryViewModel

    @State private var query = ""
    @StateObject private var recorder = LiveSpeechRecognitionService()
    @FocusState private var fieldFocused: Bool

    private let quickActions: [(label: String, icon: String, query: String)] = [
        ("Keepers",      "star.fill",                 "keeper photos"),
        ("Needs Review", "exclamationmark.circle",    "needs review"),
        ("Rejects",      "xmark.circle",              "rejected photos"),
        ("Open Jobs",    "checklist",                 ""),          // navigation-only
        ("Activity",     "clock",                     ""),          // navigation-only
        ("Not Developed","wand.and.stars",            "keepers without adjustments"),
    ]

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Palette card
            VStack(spacing: 0) {
                inputRow
                Divider()
                quickActionRow
            }
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .offset(y: -80)  // Sit in the upper-middle of the screen
        }
        .onAppear {
            fieldFocused = true
            Task { await recorder.requestPermissions() }
        }
        .onDisappear {
            recorder.stopRecording()
        }
        // Mirror live transcript into the text field
        .onChange(of: recorder.transcript) { _, newValue in
            if !newValue.isEmpty { query = newValue }
        }
        // ESC to dismiss
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: Input row

    private var inputRow: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                MicWaveformView()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }

            TextField(
                recorder.isRecording ? "Listening…" : "Ask anything — people, places, dates, prints…",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 18))
            .focused($fieldFocused)
            .onSubmit { commitQuery() }

            // Mic button
            if recorder.permissionStatus == .authorized {
                Button {
                    if recorder.isRecording {
                        recorder.stopRecording()
                        // commit what was heard
                        if !recorder.transcript.isEmpty { commitQuery() }
                    } else {
                        recorder.startRecording()
                    }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(recorder.isRecording ? .red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(recorder.isRecording ? "Stop recording" : "Start voice search")
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // Submit
            if !query.isEmpty && !recorder.isRecording {
                Button { commitQuery() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: Quick action chips

    private var quickActionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickActions, id: \.label) { action in
                    Button {
                        if action.query.isEmpty {
                            // Navigation shortcut
                            handleNavigationAction(action.label)
                        } else {
                            query = action.query
                            commitQuery()
                        }
                    } label: {
                        Label(action.label, systemImage: action.icon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: Actions

    private func commitQuery() {
        let q = query.trimmingCharacters(in: .whitespaces)
        recorder.stopRecording()
        dismiss()
        guard !q.isEmpty else { return }
        // Route navigation intents directly
        if routeNavigationIntent(q) { return }
        // Pre-fill conversational search and navigate there
        viewModel.pendingSearchQuery = q
        viewModel.selectedSection = .search
    }

    private func handleNavigationAction(_ label: String) {
        dismiss()
        switch label {
        case "Open Jobs": viewModel.selectedSection = .jobs
        case "Activity":  viewModel.selectedSection = .activity
        default: break
        }
    }

    @discardableResult
    private func routeNavigationIntent(_ query: String) -> Bool {
        let lower = query.lowercased()
        let jobsPhrases    = ["open jobs", "show jobs", "go to jobs", "staged imports", "import queue"]
        let activityPhrases = ["open activity", "show activity", "activity feed", "recent activity", "activity log"]
        if jobsPhrases.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
            viewModel.selectedSection = .jobs; return true
        }
        if activityPhrases.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
            viewModel.selectedSection = .activity; return true
        }
        return false
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.15)) { isPresented = false }
    }
}

// MARK: - MicWaveformView

/// Animated waveform shown while recording.
private struct MicWaveformView: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3)
                    .frame(height: phase ? CGFloat([8, 18, 12, 22, 10][i]) : CGFloat([14, 10, 20, 8, 16][i]))
                    .animation(
                        .easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.07),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}
