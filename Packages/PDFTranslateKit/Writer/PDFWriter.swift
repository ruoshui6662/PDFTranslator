import Foundation
import CoreGraphics
import CoreText
import PDFKit

public struct PDFWriterConfiguration: Sendable, Codable, Equatable {
    public var fontStyle: CJKFontStyle
    public var customFontPostScriptName: String?
    public var dualLayoutMode: DualLayoutMode
    public var forceOverlayFallback: Bool

    public init(
        fontStyle: CJKFontStyle = .autoMatch,
        customFontPostScriptName: String? = nil,
        dualLayoutMode: DualLayoutMode = .sideBySide,
        forceOverlayFallback: Bool = false
    ) {
        self.fontStyle = fontStyle
        self.customFontPostScriptName = customFontPostScriptName
        self.dualLayoutMode = dualLayoutMode
        self.forceOverlayFallback = forceOverlayFallback
    }
}

public struct PDFWriterOutput: Sendable, Codable, Equatable {
    public let monoURL: URL
    public let dualURL: URL
    public let overlayFallbackPages: [Int]

    public init(monoURL: URL, dualURL: URL, overlayFallbackPages: [Int] = []) {
        self.monoURL = monoURL
        self.dualURL = dualURL
        self.overlayFallbackPages = overlayFallbackPages
    }
}

public struct PDFWriter: Sendable {
    public var configuration: PDFWriterConfiguration

    public init(configuration: PDFWriterConfiguration = PDFWriterConfiguration()) {
        self.configuration = configuration
    }

    public static func defaultOutputURLs(
        for sourceURL: URL,
        in outputDirectory: URL? = nil
    ) -> (monoURL: URL, dualURL: URL) {
        let baseDir = outputDirectory ?? sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let monoURL = baseDir.appendingPathComponent("\(stem)-zh.pdf")
        let dualURL = baseDir.appendingPathComponent("\(stem)-dual.pdf")
        return (monoURL, dualURL)
    }

    /// Generates both the translated mono PDF (`*-zh.pdf`) and the bilingual comparison dual PDF (`*-dual.pdf`).
    /// Never modifies `sourceURL`.
    public func write(
        sourceURL: URL,
        documentIR: DocumentIR,
        monoURL: URL,
        dualURL: URL,
        password: String? = nil
    ) async throws -> PDFWriterOutput {
        try Task.checkCancellation()

        // Ensure output directory exists
        let outDir = monoURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var fallbackPages = Set<Int>()

        // 1. Generate Mono PDF:
        //    Route B Hybrid Primary: PDFium removes source English text objects (preserving 100% of vector graphics,
        //    colored backgrounds, tables, and images), then CoreText draws the translated CJK paragraphs using any
        //    installed system/user font (.otf 思源宋体 / 思源黑体, .ttc 苹方 / 华文宋体 / 楷体, .ttf 仿宋, or custom font)
        //    with automatic glyph subsetting and true Bold/Regular weights — WITHOUT drawing any white mask!
        //    Route A Fallback: CoreGraphics white-mask overlay for any page where PDFium object removal failed.
        let pdfiumAvailable = await PDFiumActor.shared.isAvailable()
        if !configuration.forceOverlayFallback && pdfiumAvailable {
            let strippedTempURL = outDir.appendingPathComponent(".\(UUID().uuidString)-stripped.pdf")
            defer { try? FileManager.default.removeItem(at: strippedTempURL) }
            do {
                let failed = try await PDFiumActor.shared.removeTranslatedTextObjectsToPDF(
                    sourceURL: sourceURL,
                    outputStrippedURL: strippedTempURL,
                    documentIR: documentIR,
                    password: password
                )
                fallbackPages.formUnion(failed)
                try renderCoreTextOnStrippedPDF(
                    sourceURL: sourceURL,
                    strippedPDFURL: strippedTempURL,
                    outputMonoURL: monoURL,
                    documentIR: documentIR,
                    overlayFallbackPages: failed
                )
            } catch {
                // Full document fallback to Route A (Overlay) if PDFium writer throws
                let allTranslatedPages = Set(documentIR.pages.filter { !$0.paragraphs.isEmpty }.map(\.index))
                fallbackPages.formUnion(allTranslatedPages)
                try writeMonoPDFWithCoreGraphicsOverlay(
                    sourceURL: sourceURL,
                    outputMonoURL: monoURL,
                    documentIR: documentIR
                )
            }
        } else {
            let allTranslatedPages = Set(documentIR.pages.filter { !$0.paragraphs.isEmpty }.map(\.index))
            fallbackPages.formUnion(allTranslatedPages)
            try writeMonoPDFWithCoreGraphicsOverlay(
                sourceURL: sourceURL,
                outputMonoURL: monoURL,
                documentIR: documentIR
            )
        }

        // Copy outlines (bookmarks) and link annotations from source to Mono PDF
        copyOutlinesAndLinks(from: sourceURL, to: monoURL, isSideBySideDual: false)

        try Task.checkCancellation()

        // 2. Generate Dual PDF (PDFium N-up primary, Core Graphics fallback)
        var dualCreated = false
        if await PDFiumActor.shared.isAvailable() {
            dualCreated = await PDFiumActor.shared.writeDualPDF(
                sourceURL: sourceURL,
                monoURL: monoURL,
                outputDualURL: dualURL,
                mode: configuration.dualLayoutMode,
                password: password
            )
        }
        if !dualCreated {
            try writeDualPDFWithCoreGraphics(
                sourceURL: sourceURL,
                monoURL: monoURL,
                outputDualURL: dualURL,
                mode: configuration.dualLayoutMode
            )
        }

        // Copy outlines and links to Dual PDF
        copyOutlinesAndLinks(
            from: sourceURL,
            to: dualURL,
            isSideBySideDual: configuration.dualLayoutMode == .sideBySide
        )

        return PDFWriterOutput(
            monoURL: monoURL,
            dualURL: dualURL,
            overlayFallbackPages: fallbackPages.sorted()
        )
    }

    // MARK: - Route B Hybrid: PDFium Text Removal + CoreText High-Fidelity Typeset Drawing

    private func renderCoreTextOnStrippedPDF(
        sourceURL: URL,
        strippedPDFURL: URL,
        outputMonoURL: URL,
        documentIR: DocumentIR,
        overlayFallbackPages: Set<Int>
    ) throws {
        guard let strippedDoc = CGPDFDocument(strippedPDFURL as CFURL),
              let srcDoc = CGPDFDocument(sourceURL as CFURL),
              let consumer = CGDataConsumer(url: outputMonoURL as CFURL) else {
            throw PDFTranslateError.writerFailed("CoreGraphics 无法读取去字底板 PDF")
        }

        var defaultBox = documentIR.pages.first?.mediaBox ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw PDFTranslateError.writerFailed("无法初始化 CoreGraphics PDF 上下文")
        }

        for pageIR in documentIR.pages {
            var pageBox = pageIR.mediaBox
            ctx.beginPage(mediaBox: &pageBox)

            let useWhiteMaskFallback = overlayFallbackPages.contains(pageIR.index)
            let baseDoc = useWhiteMaskFallback ? srcDoc : strippedDoc
            if let cgPage = baseDoc.page(at: pageIR.index + 1) {
                ctx.saveGState()
                ctx.drawPDFPage(cgPage)
                ctx.restoreGState()
            }

            if !pageIR.isScannedPage && !pageIR.paragraphs.isEmpty {
                drawTranslatedParagraphs(
                    on: ctx,
                    pageIR: pageIR,
                    drawWhiteBackgroundMask: useWhiteMaskFallback
                )
            }

            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: - Route A: Core Graphics Overlay Fallback

    public func writeMonoPDFWithCoreGraphicsOverlay(
        sourceURL: URL,
        outputMonoURL: URL,
        documentIR: DocumentIR
    ) throws {
        guard let srcDoc = CGPDFDocument(sourceURL as CFURL) else {
            throw PDFTranslateError.writerFailed("CoreGraphics 无法读取源 PDF")
        }
        guard let consumer = CGDataConsumer(url: outputMonoURL as CFURL) else {
            throw PDFTranslateError.writerFailed("无法创建输出文件 \(outputMonoURL.lastPathComponent)")
        }

        var defaultBox = documentIR.pages.first?.mediaBox ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else {
            throw PDFTranslateError.writerFailed("无法初始化 CoreGraphics PDF 上下文")
        }

        for pageIR in documentIR.pages {
            var pageBox = pageIR.mediaBox
            ctx.beginPage(mediaBox: &pageBox)

            if let cgPage = srcDoc.page(at: pageIR.index + 1) {
                ctx.saveGState()
                ctx.drawPDFPage(cgPage)
                ctx.restoreGState()
            }

            if !pageIR.isScannedPage && !pageIR.paragraphs.isEmpty {
                drawTranslatedParagraphs(
                    on: ctx,
                    pageIR: pageIR,
                    drawWhiteBackgroundMask: true
                )
            }

            ctx.endPage()
        }
        ctx.closePDF()
    }

    private func drawTranslatedParagraphs(
        on ctx: CGContext,
        pageIR: PageIR,
        drawWhiteBackgroundMask: Bool
    ) {
        if drawWhiteBackgroundMask {
            ctx.saveGState()
            ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            for paragraph in pageIR.paragraphs where paragraph.layout != nil {
                let maskRect = paragraph.box.insetBy(dx: -1.5, dy: -1.5)
                ctx.fill(maskRect)
            }
            ctx.restoreGState()
        }

        // Draw translated lines and formula runs using Core Text with dynamic font & weight matching
        for paragraph in pageIR.paragraphs {
            guard let layout = paragraph.layout else { continue }
            let sourceIsSerif = SystemFontCatalog.isSourceParagraphSerif(paragraph)
            let paraIsBold = SystemFontCatalog.isSourceParagraphBold(paragraph)

            for line in layout.lines {
                for run in line.runs {
                    switch run {
                    case .text(let str, let frame, let fontSize, let color, let runBold):
                        let trimmed = str.trimmingCharacters(in: .newlines)
                        if trimmed.isEmpty { continue }
                        let effectiveBold = runBold || paraIsBold
                        let psFontName = configuration.fontStyle.resolveInstalledPostScriptName(
                            isBold: effectiveBold,
                            sourceIsSerif: sourceIsSerif,
                            customPostScriptName: configuration.customFontPostScriptName
                        )
                        drawCoreTextString(
                            trimmed,
                            at: CGPoint(x: frame.minX, y: line.baselineY),
                            fontName: psFontName as CFString,
                            fontSize: fontSize,
                            color: color,
                            in: ctx
                        )
                    case .formula(_, let formulaChars, let targetFrame):
                        var cursorX = targetFrame.minX
                        let baseBaselineY = line.baselineY
                        let origRefY = formulaChars.first?.box.minY ?? baseBaselineY
                        let fallbackCJKFont = configuration.fontStyle.resolveInstalledPostScriptName(
                            isBold: false,
                            sourceIsSerif: sourceIsSerif,
                            customPostScriptName: configuration.customFontPostScriptName
                        ) as CFString

                        for (fIdx, fChar) in formulaChars.enumerated() {
                            let rawText = fChar.unicode.trimmingCharacters(in: .whitespacesAndNewlines)
                            let charText = rawText.decomposedStringWithCompatibilityMapping
                            if charText.isEmpty {
                                cursorX += max(1.5, fChar.fontSize * 0.25)
                                continue
                            }
                            if fIdx > 0 {
                                let prev = formulaChars[fIdx - 1]
                                let sameOrigLine = abs(fChar.box.midY - prev.box.midY) <= max(prev.fontSize, fChar.fontSize) * 0.9
                                let origDeltaX = fChar.box.minX - prev.box.minX
                                if sameOrigLine && origDeltaX >= 0 && origDeltaX <= prev.fontSize * 2.5 {
                                    cursorX += max(prev.box.width * 0.75, origDeltaX)
                                } else {
                                    cursorX += max(prev.fontSize * 0.45, prev.box.width)
                                }
                            }
                            let rawDy = fChar.box.minY - origRefY
                            let clampedDy: CGFloat = (abs(rawDy) <= fChar.fontSize * 0.65) ? rawDy : 0
                            let targetY = baseBaselineY + clampedDy
                            let isASCII = charText.unicodeScalars.allSatisfy { $0.value < 0x007F }
                            let mathFontName: CFString = isASCII ? ("TimesNewRomanPS-ItalicMT" as CFString) : fallbackCJKFont

                            drawCoreTextString(
                                charText,
                                at: CGPoint(x: cursorX, y: targetY),
                                fontName: mathFontName,
                                fontSize: fChar.fontSize,
                                color: fChar.color,
                                in: ctx
                            )
                        }
                    }
                }
            }
        }
    }

    private func drawCoreTextString(
        _ text: String,
        at point: CGPoint,
        fontName: CFString,
        fontSize: CGFloat,
        color: RGBAColor,
        in ctx: CGContext
    ) {
        let ctFont = CTFontCreateWithName(fontName, max(4.0, fontSize), nil)
        let cgColor = CGColor(
            srgbRed: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: CGFloat(color.a) / 255.0
        )
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        let ctLine = CTLineCreateWithAttributedString(attrStr as CFAttributedString)

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    // MARK: - Core Graphics Dual PDF Fallback

    private func writeDualPDFWithCoreGraphics(
        sourceURL: URL,
        monoURL: URL,
        outputDualURL: URL,
        mode: DualLayoutMode
    ) throws {
        guard let srcDoc = CGPDFDocument(sourceURL as CFURL),
              let monoDoc = CGPDFDocument(monoURL as CFURL),
              let consumer = CGDataConsumer(url: outputDualURL as CFURL) else {
            throw PDFTranslateError.writerFailed("无法创建对照版 PDF")
        }

        let pageCount = min(srcDoc.numberOfPages, monoDoc.numberOfPages)
        guard pageCount > 0 else { return }

        var initialBox = CGRect(x: 0, y: 0, width: 1190, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &initialBox, nil) else {
            throw PDFTranslateError.writerFailed("无法初始化对照版 PDF 上下文")
        }

        for pageNumber in 1...pageCount {
            guard let srcPage = srcDoc.page(at: pageNumber),
                  let monoPage = monoDoc.page(at: pageNumber) else { continue }
            let srcBox = srcPage.getBoxRect(.mediaBox)
            let monoBox = monoPage.getBoxRect(.mediaBox)

            switch mode {
            case .sideBySide:
                var combinedBox = CGRect(
                    x: 0,
                    y: 0,
                    width: srcBox.width + monoBox.width,
                    height: max(srcBox.height, monoBox.height)
                )
                ctx.beginPage(mediaBox: &combinedBox)
                ctx.saveGState()
                ctx.drawPDFPage(srcPage)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.translateBy(x: srcBox.width, y: 0)
                ctx.drawPDFPage(monoPage)
                ctx.restoreGState()
                ctx.endPage()

            case .alternating:
                var sBox = srcBox
                ctx.beginPage(mediaBox: &sBox)
                ctx.drawPDFPage(srcPage)
                ctx.endPage()

                var mBox = monoBox
                ctx.beginPage(mediaBox: &mBox)
                ctx.drawPDFPage(monoPage)
                ctx.endPage()
            }
        }
        ctx.closePDF()
    }

    // MARK: - Bookmark (Outline) & Link Annotation Preservation

    private func copyOutlinesAndLinks(
        from sourceURL: URL,
        to targetURL: URL,
        isSideBySideDual: Bool
    ) {
        guard let srcDoc = PDFDocument(url: sourceURL),
              let dstDoc = PDFDocument(url: targetURL) else {
            return
        }
        var modified = false

        // Copy document outline (bookmarks / table of contents)
        if let srcOutline = srcDoc.outlineRoot, dstDoc.outlineRoot == nil {
            let newRoot = PDFOutline()
            cloneOutlineChildren(from: srcOutline, to: newRoot, in: dstDoc)
            if newRoot.numberOfChildren > 0 {
                dstDoc.outlineRoot = newRoot
                modified = true
            }
        }

        // Copy link annotations
        if !isSideBySideDual && srcDoc.pageCount == dstDoc.pageCount {
            for idx in 0..<srcDoc.pageCount {
                guard let srcPage = srcDoc.page(at: idx),
                      let dstPage = dstDoc.page(at: idx) else { continue }
                let existingLinks = dstPage.annotations.filter { $0.type == "Link" }
                if !existingLinks.isEmpty { continue }

                for annot in srcPage.annotations where annot.type == "Link" {
                    let linkCopy = PDFAnnotation(bounds: annot.bounds, forType: .link, withProperties: nil)
                    if let url = annot.url {
                        linkCopy.url = url
                    } else if let dest = annot.destination,
                              let destPage = dest.page {
                        let pageIdx = srcDoc.index(for: destPage)
                        if pageIdx >= 0, pageIdx < dstDoc.pageCount, let mappedPage = dstDoc.page(at: pageIdx) {
                            linkCopy.destination = PDFDestination(page: mappedPage, at: dest.point)
                        }
                    }
                    dstPage.addAnnotation(linkCopy)
                    modified = true
                }
            }
        }

        if modified {
            dstDoc.write(to: targetURL)
        }
    }

    private func cloneOutlineChildren(
        from sourceParent: PDFOutline,
        to destParent: PDFOutline,
        in destDoc: PDFDocument
    ) {
        for i in 0..<sourceParent.numberOfChildren {
            guard let srcChild = sourceParent.child(at: i) else { continue }
            let dstChild = PDFOutline()
            dstChild.label = srcChild.label
            dstChild.isOpen = srcChild.isOpen
            if let dest = srcChild.destination,
               let srcPage = dest.page,
               let srcDoc = srcPage.document {
                let pageIdx = srcDoc.index(for: srcPage)
                if pageIdx >= 0, pageIdx < destDoc.pageCount, let mappedPage = destDoc.page(at: pageIdx) {
                    dstChild.destination = PDFDestination(page: mappedPage, at: dest.point)
                }
            }
            destParent.insertChild(dstChild, at: destParent.numberOfChildren)
            cloneOutlineChildren(from: srcChild, to: dstChild, in: destDoc)
        }
    }
}
