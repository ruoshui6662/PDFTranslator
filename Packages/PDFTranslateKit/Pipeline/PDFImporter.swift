import Foundation
import UniformTypeIdentifiers

public struct PDFImporter: Sendable {
    public init() {}

    /// Rewrites arXiv `abs` or `html` links into direct pdf download links.
    /// e.g. `https://arxiv.org/abs/2503.17213` -> `https://arxiv.org/pdf/2503.17213`
    /// Note: arXiv serves PDFs at /pdf/{id} (no .pdf suffix); adding .pdf causes 301 redirect.
    public static func normalizeURL(_ input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file" else {
            throw PDFTranslateError.notAPDFFile(trimmed)
        }

        if scheme == "file" {
            return url
        }

        if let host = url.host?.lowercased(), host.contains("arxiv.org") {
            var path = url.path
            if path.hasPrefix("/abs/") {
                path = path.replacingOccurrences(of: "/abs/", with: "/pdf/")
            } else if path.hasPrefix("/html/") {
                path = path.replacingOccurrences(of: "/html/", with: "/pdf/")
            }
            // Strip trailing .pdf if present (arXiv prefers /pdf/{id} without suffix)
            if path.hasSuffix(".pdf") {
                path = String(path.dropLast(4))
            }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.path = path
            if let rewritten = comps?.url {
                return rewritten
            }
        }

        return url
    }

    public func validateLocalFile(_ url: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFTranslateError.fileNotFound(url.lastPathComponent)
        }
        // Check `%PDF-` header signature or UTType
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magicData = try? handle.read(upToCount: 5),
              let magicStr = String(data: magicData, encoding: .ascii),
              magicStr.hasPrefix("%PDF-") else {
            throw PDFTranslateError.notAPDFFile(url.lastPathComponent)
        }
        try? handle.close()
        return url
    }

    /// Downloads a remote PDF (including arXiv links) to the temporary directory with progress reporting.
    public func downloadRemotePDF(
        from rawURLString: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let remoteURL = try Self.normalizeURL(rawURLString)
        if remoteURL.isFileURL {
            return try validateLocalFile(remoteURL)
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 60
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) PDFTranslator/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PDFTranslateError.downloadFailed("HTTP 状态异常")
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isArxivPDF = remoteURL.host?.lowercased().contains("arxiv.org") == true && remoteURL.path.hasPrefix("/pdf/")
        if !contentType.contains("application/pdf") && !contentType.contains("application/octet-stream") && !isArxivPDF {
            throw PDFTranslateError.notAPDFFile(remoteURL.absoluteString)
        }

        let expectedLength = http.expectedContentLength
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTranslatorDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var fileName = remoteURL.lastPathComponent
        if !fileName.lowercased().hasSuffix(".pdf") {
            fileName += ".pdf"
        }
        if fileName == ".pdf" || fileName.isEmpty {
            fileName = "downloaded-\(UUID().uuidString.prefix(8)).pdf"
        }
        let destinationURL = tempDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }

        var buffer = Data()
        buffer.reserveCapacity(65536)
        var totalReceived: Int64 = 0

        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 32768 {
                    try fileHandle.write(contentsOf: buffer)
                    totalReceived += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expectedLength > 0 {
                        onProgress?(min(1.0, Double(totalReceived) / Double(expectedLength)))
                    }
                }
            }
            if !buffer.isEmpty {
                try fileHandle.write(contentsOf: buffer)
                totalReceived += Int64(buffer.count)
            }
            onProgress?(1.0)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if error is CancellationError {
                throw PDFTranslateError.cancelled
            }
            throw error
        }

        return try validateLocalFile(destinationURL)
    }
}
