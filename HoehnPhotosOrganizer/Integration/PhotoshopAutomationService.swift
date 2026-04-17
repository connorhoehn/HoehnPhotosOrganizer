import Foundation
import AppKit

// MARK: - PhotoshopError

/// Errors thrown by PhotoshopAutomationService during Photoshop communication.
enum PhotoshopError: LocalizedError {
    case notRunning
    case jsxExecutionFailed(details: String)
    case communicationFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Adobe Photoshop is not running. Please launch Photoshop and open a document, then try again."
        case .jsxExecutionFailed(let details):
            return "JSX execution failed in Photoshop: \(details)"
        case .communicationFailed(let details):
            return "Communication with Photoshop failed: \(details)"
        }
    }
}

// MARK: - PhotoshopAutomationService

/// Actor that communicates with a running Adobe Photoshop instance via AppleScript (NSAppleScript).
///
/// Usage:
/// ```swift
/// let service = PhotoshopAutomationService()
/// guard try await service.detectPhotoshop() else { /* show "not running" UI */ }
/// let result = try await service.applyJSX(jsx: generatedJSX)
/// ```
///
/// Communication approach: AppleScript `do javascript` command (simplest, most reliable).
/// Alternative: Photoshop UXP socket (requires Photoshop 2022+ preference, deferred to Phase 8).
actor PhotoshopAutomationService {

    // MARK: - Photoshop bundle identifier

    /// The bundle ID used by AppleScript to target Photoshop. Covers PS 2021–2025.
    private let photoshopBundleID = "com.adobe.Photoshop"

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Check whether Adobe Photoshop is currently running.
    ///
    /// Uses `NSRunningApplication.runningApplications(withBundleIdentifier:)` for a fast,
    /// process-level check without spinning up an AppleScript interpreter.
    ///
    /// - Returns: `true` if at least one Photoshop process is running.
    func detectPhotoshop() async throws -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: photoshopBundleID)
        return !apps.isEmpty
    }

    /// Execute a JSX string in the running Photoshop instance.
    ///
    /// Sends the JSX via AppleScript `do javascript` command. Waits for completion
    /// and checks the result string for Photoshop-reported errors.
    ///
    /// - Parameter jsx: ExtendScript (JSX) string to execute.
    /// - Returns: The result string from Photoshop (may be empty on success).
    /// - Throws: `PhotoshopError.notRunning` if Photoshop isn't running.
    ///           `PhotoshopError.jsxExecutionFailed` if Photoshop returns an error.
    ///           `PhotoshopError.communicationFailed` if the AppleScript itself fails.
    func applyJSX(jsx: String) async throws -> String {
        // Guard: Photoshop must be running
        let isRunning = try await detectPhotoshop()
        guard isRunning else {
            throw PhotoshopError.notRunning
        }

        // Escape the JSX for embedding in AppleScript string
        // JSX is embedded in a quoted AppleScript string — must escape backslashes and quotes
        let escapedJSX = jsx
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Build AppleScript: tell Photoshop to execute the JSX
        let appleScriptSource = """
tell application id "\(photoshopBundleID)"
    do javascript "\(escapedJSX)"
end tell
"""

        return try await withCheckedThrowingContinuation { continuation in
            // AppleScript must run on the main thread
            DispatchQueue.main.async {
                var errorDict: NSDictionary?
                let script = NSAppleScript(source: appleScriptSource)
                let result = script?.executeAndReturnError(&errorDict)

                if let error = errorDict {
                    let description = (error[NSAppleScript.errorMessage] as? String)
                        ?? (error[NSAppleScript.errorNumber] as? NSNumber).map { "AppleScript error \($0)" }
                        ?? "Unknown AppleScript error"

                    // Check if it's a "not running" class error
                    if let errNum = error[NSAppleScript.errorNumber] as? NSNumber,
                       errNum.intValue == -600 {
                        continuation.resume(throwing: PhotoshopError.notRunning)
                    } else {
                        continuation.resume(throwing: PhotoshopError.communicationFailed(details: description))
                    }
                    return
                }

                let resultString = result?.stringValue ?? ""

                // Check if Photoshop reported a JSX error in the result
                if PhotoshopAutomationService.verifyResult(resultString) {
                    continuation.resume(returning: resultString)
                } else {
                    continuation.resume(throwing: PhotoshopError.jsxExecutionFailed(details: resultString))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Check if a Photoshop JSX result string indicates success.
    ///
    /// Photoshop embeds error messages starting with "Error:" in the return value
    /// when a JSX execution fails. Any other result (including empty) is treated as success.
    ///
    /// - Parameter result: The string returned by `do javascript` AppleScript command.
    /// - Returns: `true` if no error detected, `false` if "Error:" prefix found.
    nonisolated func verifyPhotoshopResult(_ result: String) -> Bool {
        PhotoshopAutomationService.verifyResult(result)
    }

    /// Static helper used from async contexts and DispatchQueue closures.
    nonisolated static func verifyResult(_ result: String) -> Bool {
        // Photoshop error responses start with "Error:" (case-sensitive)
        return !result.hasPrefix("Error:")
    }
}
