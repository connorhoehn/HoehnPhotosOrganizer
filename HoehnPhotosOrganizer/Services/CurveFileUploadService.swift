import Foundation
import CryptoKit

enum CurveFileError: LocalizedError {
    case invalidExtension
    case fileTooLarge(Int)
    case invalidACVFormat
    case invalidCSVFormat
    case uploadFailed(String)
    case hashComputeFailed

    var errorDescription: String? {
        switch self {
        case .invalidExtension:
            "Only .acv, .csv, .lut, and .cube files are supported"
        case .fileTooLarge(let size):
            "File is too large (\(size) bytes). Maximum is 10 MB."
        case .invalidACVFormat:
            "Invalid .acv file format. Adobe curves must start with specific magic bytes."
        case .invalidCSVFormat:
            "Invalid .csv file format. CSV curves must have valid header."
        case .uploadFailed(let reason):
            "S3 upload failed: \(reason)"
        case .hashComputeFailed:
            "Failed to compute file hash for integrity check"
        }
    }
}

actor CurveFileUploadService {
    private let s3Client: any PresignedURLProviding

    init(s3Client: any PresignedURLProviding) {
        self.s3Client = s3Client
    }

    // MARK: - Validation

    nonisolated func validateCurveFile(_ fileURL: URL) throws {
        let fileExtension = fileURL.pathExtension.lowercased()

        // Check extension
        guard ["acv", "csv", "lut", "cube"].contains(fileExtension) else {
            throw CurveFileError.invalidExtension
        }

        // Check file size
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw CurveFileError.uploadFailed("Cannot determine file size")
        }

        let maxSize = 10 * 1024 * 1024  // 10 MB
        guard fileSize <= maxSize else {
            throw CurveFileError.fileTooLarge(fileSize)
        }

        // Validate file content by type
        let data = try Data(contentsOf: fileURL)

        if fileExtension == "acv" {
            try validateACVFormat(data)
        } else if fileExtension == "csv" {
            try validateCSVFormat(data)
        }
        // .lut and .cube are treated as opaque for now
    }

    private nonisolated func validateACVFormat(_ data: Data) throws {
        // Adobe curves start with magic bytes: 00 05
        guard data.count >= 2 else {
            throw CurveFileError.invalidACVFormat
        }

        let bytes = [UInt8](data.prefix(2))
        guard bytes[0] == 0x00 && bytes[1] == 0x05 else {
            throw CurveFileError.invalidACVFormat
        }
    }

    private nonisolated func validateCSVFormat(_ data: Data) throws {
        guard let csvString = String(data: data, encoding: .utf8) else {
            throw CurveFileError.invalidCSVFormat
        }

        let lines = csvString.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 0 else {
            throw CurveFileError.invalidCSVFormat
        }

        // Expect header like "Input,Red,Green,Blue" or similar
        let header = String(lines[0])
        guard header.contains("Input") || header.contains("input") else {
            throw CurveFileError.invalidCSVFormat
        }
    }

    // MARK: - File Operations

    nonisolated func computeFileHash(_ data: Data) throws -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Upload

    func uploadCurveFile(
        fileURL: URL,
        photoId: String,
        attemptId: String
    ) async throws -> CurveFileReference {
        // Validate before upload
        try validateCurveFile(fileURL)

        let fileData = try Data(contentsOf: fileURL)
        let fileSize = fileData.count
        let fileName = fileURL.lastPathComponent
        let contentHash = try computeFileHash(fileData)

        // Request presigned upload URL from Phase 4 service
        let s3Key = "curves/\(photoId)/\(attemptId)_\(fileName)"
        let uploadUrl = try await s3Client.presignedPutURL(
            for: s3Key,
            contentType: mimeType(for: fileURL)
        )

        // Upload to S3
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(mimeType(for: fileURL), forHTTPHeaderField: "Content-Type")
        request.httpBody = fileData

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw CurveFileError.uploadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Return reference
        return CurveFileReference(
            id: UUID().uuidString,
            originalFileName: fileName,
            s3Key: s3Key,
            fileSize: fileSize,
            uploadedAt: ISO8601DateFormatter().string(from: Date()),
            contentHash: contentHash
        )
    }

    private func mimeType(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "csv": return "text/csv"
        case "acv": return "application/octet-stream"
        case "lut": return "application/octet-stream"
        case "cube": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

// PresignedURLProviding protocol is defined in CloudSync/S3PresignedURLProvider.swift
