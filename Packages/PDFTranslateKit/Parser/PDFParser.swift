import Foundation
import PDFKit

public struct PDFParser: Sendable {
    public init() {}

    public func parse(
        url: URL,
        password: String? = nil,
        onPageProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> DocumentIR {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PDFTranslateError.fileNotFound(url.lastPathComponent)
        }

        if await PDFiumActor.shared.isAvailable() {
            return try await PDFiumActor.shared.parseDocument(
                at: url,
                password: password,
                onPageParsed: onPageProgress
            )
        } else {
            return try parseWithPDFKitFallback(url: url, password: password, onPageProgress: onPageProgress)
        }
    }

    private func parseWithPDFKitFallback(
        url: URL,
        password: String?,
        onPageProgress: (@Sendable (Int, Int) -> Void)?
    ) throws -> DocumentIR {
        guard let pdfDoc = PDFDocument(url: url) else {
            throw PDFTranslateError.notAPDFFile(url.lastPathComponent)
        }

        if pdfDoc.isEncrypted {
            if let password, !password.isEmpty {
                if !pdfDoc.unlock(withPassword: password) {
                    throw PDFTranslateError.invalidPassword
                }
            } else if pdfDoc.isLocked {
                throw PDFTranslateError.encryptedDocumentRequiresPassword
            }
        }

        let pageCount = pdfDoc.pageCount
        guard pageCount > 0 else {
            throw PDFTranslateError.emptyDocument
        }

        var pages: [PageIR] = []
        for idx in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = pdfDoc.page(at: idx) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            let pageStr = page.string ?? ""
            var chars: [CharIR] = []
            let nsString = pageStr as NSString

            for i in 0..<nsString.length {
                let sub = nsString.substring(with: NSRange(location: i, length: 1))
                guard let sel = page.selection(for: NSRange(location: i, length: 1)) else { continue }
                let bounds = sel.bounds(for: page)
                if bounds.isEmpty && sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                let attrStr = sel.attributedString
                var fontName = "Helvetica"
                var fontSize: CGFloat = max(8.0, bounds.height * 0.85)
                if let attrStr, attrStr.length > 0,
                   let font = attrStr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    fontName = font.fontName
                    fontSize = font.pointSize
                }
                chars.append(
                    CharIR(
                        unicode: sub,
                        box: bounds,
                        fontName: fontName,
                        fontSize: fontSize,
                        color: .black,
                        objectID: -1
                    )
                )
            }

            let visible = chars.filter { !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let isScanned = visible.isEmpty
            pages.append(PageIR(index: idx, mediaBox: mediaBox, isScannedPage: isScanned, chars: chars))
            onPageProgress?(idx + 1, pageCount)
        }

        return DocumentIR(sourceFileName: url.lastPathComponent, pages: pages)
    }
}
