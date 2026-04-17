import SwiftUI

// MARK: - CurveApplicationView

/// SwiftUI sheet for applying an editorial feedback curve to the active Photoshop document.
///
/// Workflow:
/// 1. On appear: check if Photoshop is running (updates `photoshopDetected` state)
/// 2. If detected: "Apply Curve" button is enabled
/// 3. On tap "Apply Curve": calls `LibraryViewModel.applyCurveToPhotoshop(_:)`
/// 4. Result: shows success or error message
struct CurveApplicationView: View {

    // MARK: - Dependencies

    let curveData: CurveData
    @ObservedObject var viewModel: LibraryViewModel

    @Environment(\.dismiss) private var dismiss

    // MARK: - Local state

    @State private var photoshopDetected: Bool = false
    @State private var isCheckingPhotoshop: Bool = true
    @State private var isApplying: Bool = false
    @State private var resultMessage: String?
    @State private var resultIsError: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                    .padding(.top, 24)

                Text("Apply Curve to Photoshop")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text("This will apply the curve adjustment to the active document in Photoshop.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Divider()
                .padding(.vertical, 16)

            // Curve info
            curveInfoSection
                .padding(.horizontal, 24)

            Divider()
                .padding(.vertical, 16)

            // Photoshop detection status
            photoshopStatusSection
                .padding(.horizontal, 24)

            // Result message
            if let result = resultMessage {
                resultBanner(message: result, isError: resultIsError)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            Spacer()

            // Action buttons
            actionButtonsSection
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 400, height: 380)
        .task {
            await checkPhotoshopStatus()
        }
    }

    // MARK: - Sub-views

    private var curveInfoSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Editorial Curve")
                    .font(.headline)
                Text("\(curveData.format.uppercased()) • \(curveData.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.08))
        )
    }

    @ViewBuilder
    private var photoshopStatusSection: some View {
        HStack(spacing: 10) {
            if isCheckingPhotoshop {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(width: 20, height: 20)
                Text("Checking for Photoshop…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if photoshopDetected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("Photoshop detected")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text("Photoshop not running")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if !isCheckingPhotoshop {
                Button("Refresh") {
                    Task { await checkPhotoshopStatus() }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(photoshopDetected ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        )
    }

    private func resultBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.callout)
                .foregroundStyle(isError ? .red : .green)
                .multilineTextAlignment(.leading)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isError ? Color.red.opacity(0.08) : Color.green.opacity(0.08))
        )
    }

    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape)

            Spacer()

            if isApplying {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text("Applying…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if resultMessage != nil && !resultIsError {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            } else {
                Button("Apply Curve") {
                    Task { await applyToPhotoshop() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!photoshopDetected || isCheckingPhotoshop)
            }
        }
    }

    // MARK: - Actions

    private func checkPhotoshopStatus() async {
        isCheckingPhotoshop = true
        let service = PhotoshopAutomationService()
        photoshopDetected = (try? await service.detectPhotoshop()) ?? false
        isCheckingPhotoshop = false
    }

    private func applyToPhotoshop() async {
        isApplying = true
        resultMessage = nil
        resultIsError = false

        do {
            let jsxGenerator = PhotoshopJSXGenerator()
            let jsx = try await jsxGenerator.generateJSX(from: curveData)

            let automationService = PhotoshopAutomationService()
            _ = try await automationService.applyJSX(jsx: jsx)

            resultMessage = "Curve applied successfully"
            resultIsError = false
        } catch let error as PhotoshopError {
            resultMessage = error.localizedDescription
            resultIsError = true
        } catch let error as JSXGenerationError {
            resultMessage = error.localizedDescription
            resultIsError = true
        } catch {
            resultMessage = error.localizedDescription
            resultIsError = true
        }

        isApplying = false
    }
}
