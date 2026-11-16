import Foundation
import CoreGraphics
import CPDFium

/// Dedicated actor encapsulating all PDFium C library calls.
/// No PDFium opaque pointer (`FPDF_DOCUMENT`, `FPDF_PAGE`, etc.) ever crosses outside this actor.
public actor PDFiumActor {
    public static let shared = PDFiumActor()

    public init() {
        _ = cpdfium_is_loaded()
    }

    public func isAvailable() -> Bool {
        cpdfium_is_loaded() != 0
    }

    public func loadedLibraryPath() -> String {
        guard let cStr = cpdfium_loaded_path() else { return "" }
        return String(cString: cStr)
    }

    /// Parses a PDF file page-by-page using PDFium, releasing each page handle immediately after extraction.
    public func parseDocument(
        at url: URL,
        password: String? = nil,
        onPageParsed: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> DocumentIR {
        guard cpdfium_is_loaded() != 0 else {
            throw PDFTranslateError.parserFailed("PDFium 动态库未加载")
        }

        let doc: FPDF_DOCUMENT? = url.path.withCString { pathPtr in
            if let password, !password.isEmpty {
                return password.withCString { pwdPtr in
                    cpdfium_LoadDocument(pathPtr, pwdPtr)
                }
            } else {
                return cpdfium_LoadDocument(pathPtr, nil)
            }
        }

        guard let doc else {
            let errCode = Int(cpdfium_GetLastError())
            if errCode == Int(FPDF_ERR_PASSWORD) {
                throw (password == nil || password?.isEmpty == true)
                    ? PDFTranslateError.encryptedDocumentRequiresPassword
                    : PDFTranslateError.invalidPassword
            } else if errCode == Int(FPDF_ERR_FORMAT) {
                throw PDFTranslateError.notAPDFFile(url.lastPathComponent)
            }
            throw PDFTranslateError.parserFailed("错误码 \(errCode)")
        }
        defer { cpdfium_CloseDocument(doc) }

        let pageCount = Int(cpdfium_GetPageCount(doc))
        guard pageCount > 0 else {
            throw PDFTranslateError.emptyDocument
        }

        var pages: [PageIR] = []
        pages.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            let pageIR = try parseSinglePage(doc: doc, pageIndex: pageIndex)
            pages.append(pageIR)
            onPageParsed?(pageIndex + 1, pageCount)
        }

        return DocumentIR(sourceFileName: url.lastPathComponent, pages: pages)
    }

    private func parseSinglePage(doc: FPDF_DOCUMENT, pageIndex: Int) throws -> PageIR {
        guard let page = cpdfium_LoadPage(doc, Int32(pageIndex)) else {
            throw PDFTranslateError.parserFailed("无法加载第 \(pageIndex + 1) 页")
        }
        defer { cpdfium_ClosePage(page) }

        var left: Float = 0
        var bottom: Float = 0
        var right: Float = 0
        var top: Float = 0
        let mediaBox: CGRect
        if cpdfium_PageGetMediaBox(page, &left, &bottom, &right, &top) != 0, right > left, top > bottom {
            mediaBox = CGRect(
                x: CGFloat(left),
                y: CGFloat(bottom),
                width: CGFloat(right - left),
                height: CGFloat(top - bottom)
            )
        } else {
            let w = CGFloat(cpdfium_GetPageWidthF(page))
            let h = CGFloat(cpdfium_GetPageHeightF(page))
            mediaBox = CGRect(x: 0, y: 0, width: max(1, w), height: max(1, h))
        }

        // Map page object pointer -> object index on this page
        let objCount = Int(cpdfium_PageCountObjects(page))
        var objectPointerToID: [UnsafeRawPointer: Int] = [:]
        var hasImageObject = false
        for objIdx in 0..<objCount {
            if let objPtr = cpdfium_PageGetObject(page, Int32(objIdx)) {
                objectPointerToID[UnsafeRawPointer(objPtr)] = objIdx
                if cpdfium_PageObjGetType(objPtr) == FPDF_PAGEOBJ_IMAGE {
                    hasImageObject = true
                }
            }
        }

        guard let textPage = cpdfium_TextLoadPage(page) else {
            return PageIR(index: pageIndex, mediaBox: mediaBox, isScannedPage: hasImageObject)
        }
        defer { cpdfium_TextClosePage(textPage) }

        let charCount = Int(cpdfium_TextCountChars(textPage))
        var chars: [CharIR] = []
        if charCount > 0 {
            chars.reserveCapacity(charCount)
        }

        var fontNameBuffer = [CChar](repeating: 0, count: 256)

        var charIdx = 0
        while charIdx < charCount {
            defer { charIdx += 1 }
            let codepoint = cpdfium_TextGetUnicode(textPage, Int32(charIdx))
            if codepoint == 0 { continue }

            // Handle UTF-16 surrogate pairs (e.g. Mathematical Alphanumeric Symbols U+1D400..U+1D7FF)
            var resolvedCodepoint: UInt32 = codepoint
            var pairedCharIdx: Int? = nil
            if (0xD800...0xDBFF).contains(codepoint), charIdx + 1 < charCount {
                let low = cpdfium_TextGetUnicode(textPage, Int32(charIdx + 1))
                if (0xDC00...0xDFFF).contains(low) {
                    resolvedCodepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
                    pairedCharIdx = charIdx + 1
                }
            }

            guard let scalar = UnicodeScalar(resolvedCodepoint) else { continue }
            let charStr: String
            if resolvedCodepoint == 0x0002 || resolvedCodepoint == 0x00AD || resolvedCodepoint == 0xFFFE {
                // PDFium uses 0x0002 / 0xFFFE to represent end-of-line soft hyphens
                charStr = "-"
            } else {
                charStr = String(scalar)
            }

            // Skip control characters except space/newline/soft-hyphen
            if scalar.value < 0x20 && resolvedCodepoint != 0x0002 && scalar != "\n" && scalar != "\r" && scalar != "\t" {
                continue
            }

            // Skip vertically rotated margin watermarks (e.g., vertical arXiv sidebar stamps at ~90° or ~270°)
            let angle = cpdfium_TextGetCharAngle(textPage, Int32(charIdx))
            if angle > 0.35 && angle < (Float.pi * 2.0 - 0.35) {
                continue
            }

            var cLeft: Double = 0
            var cRight: Double = 0
            var cBottom: Double = 0
            var cTop: Double = 0
            var charBox = CGRect.zero

            var looseRect = FS_RECTF(left: 0, top: 0, right: 0, bottom: 0)
            if cpdfium_TextGetLooseCharBox(textPage, Int32(charIdx), &looseRect) != 0,
               looseRect.right >= looseRect.left,
               looseRect.top >= looseRect.bottom {
                charBox = CGRect(
                    x: CGFloat(looseRect.left),
                    y: CGFloat(looseRect.bottom),
                    width: CGFloat(looseRect.right - looseRect.left),
                    height: CGFloat(looseRect.top - looseRect.bottom)
                )
            } else if cpdfium_TextGetCharBox(textPage, Int32(charIdx), &cLeft, &cRight, &cBottom, &cTop) != 0 {
                let minX = min(cLeft, cRight)
                let maxX = max(cLeft, cRight)
                let minY = min(cBottom, cTop)
                let maxY = max(cBottom, cTop)
                charBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }

            if let secondIdx = pairedCharIdx {
                var secondRect = FS_RECTF(left: 0, top: 0, right: 0, bottom: 0)
                if cpdfium_TextGetLooseCharBox(textPage, Int32(secondIdx), &secondRect) != 0,
                   secondRect.right > secondRect.left, secondRect.top > secondRect.bottom {
                    let r2 = CGRect(
                        x: CGFloat(secondRect.left),
                        y: CGFloat(secondRect.bottom),
                        width: CGFloat(secondRect.right - secondRect.left),
                        height: CGFloat(secondRect.top - secondRect.bottom)
                    )
                    charBox = charBox.width > 0 ? charBox.union(r2) : r2
                }
                charIdx = secondIdx
            }

            // Preserve PDFium generated word-boundary spaces and soft hyphens by synthesizing a box right after the previous character
            if charBox.width <= 0.01 && charBox.height <= 0.01 {
                if (charStr == " " || charStr == "\u{00A0}" || charStr == "-"), let prev = chars.last {
                    if charStr == " " && prev.unicode == " " {
                        continue
                    }
                    let synthW = (charStr == "-") ? max(2.0, prev.fontSize * 0.30) : max(1.2, prev.fontSize * 0.22)
                    charBox = CGRect(x: prev.box.maxX, y: prev.box.minY, width: synthW, height: max(1.0, prev.box.height))
                } else if charStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
            }

            let objID: Int
            let textObjPtr = cpdfium_TextGetTextObject(textPage, Int32(charIdx))
            if let textObjPtr,
               let mappedID = objectPointerToID[UnsafeRawPointer(textObjPtr)] {
                objID = mappedID
            } else {
                objID = -1
            }

            let rawFontSize = CGFloat(cpdfium_TextGetFontSize(textPage, Int32(charIdx)))
            let fontSize: CGFloat
            if rawFontSize <= 1.5 {
                if let prev = chars.last, abs(prev.box.midY - charBox.midY) <= prev.fontSize {
                    fontSize = prev.fontSize
                    charBox = CGRect(x: charBox.minX, y: prev.box.minY, width: max(1.5, charBox.width), height: prev.box.height)
                } else if charBox.height > 2.0 {
                    fontSize = round(charBox.height * 2.0) / 2.0
                } else {
                    fontSize = max(1.0, rawFontSize)
                }
            } else {
                fontSize = max(1.0, rawFontSize)
            }

            var fontFlags: Int32 = 0
            let nameLen = cpdfium_TextGetFontInfo(
                textPage,
                Int32(charIdx),
                &fontNameBuffer,
                UInt(fontNameBuffer.count),
                &fontFlags
            )
            let fontName: String
            if nameLen > 0 {
                let validBytes = fontNameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                fontName = String(decoding: validBytes, as: UTF8.self)
            } else {
                fontName = "Unknown"
            }

            var r: UInt32 = 0
            var g: UInt32 = 0
            var b: UInt32 = 0
            var a: UInt32 = 255
            _ = cpdfium_TextGetFillColor(textPage, Int32(charIdx), &r, &g, &b, &a)
            let color = RGBAColor(
                r: UInt8(clamping: r),
                g: UInt8(clamping: g),
                b: UInt8(clamping: b),
                a: UInt8(clamping: a == 0 ? 255 : a)
            )

            let lowerFont = fontName.lowercased()
            let isBold = lowerFont.contains("bold") || lowerFont.contains("-bd") || (fontFlags & (1 << 18)) != 0
            let isItalic = lowerFont.contains("italic") || lowerFont.contains("oblique") || (fontFlags & (1 << 6)) != 0

            chars.append(
                CharIR(
                    unicode: charStr,
                    box: charBox,
                    fontName: fontName,
                    fontSize: fontSize,
                    color: color,
                    objectID: objID,
                    isFormula: false,
                    isBold: isBold,
                    isItalic: isItalic
                )
            )
        }

        let visibleChars = chars.filter { !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isScanned = visibleChars.isEmpty && (hasImageObject || objCount > 0)

        return PageIR(
            index: pageIndex,
            mediaBox: mediaBox,
            isScannedPage: isScanned,
            chars: chars
        )
    }

    /// Removes original English text objects belonging to translated paragraphs on a copy of the source document
    /// using PDFium object editing, while preserving 100% of vector paths, images, colored backgrounds, and untranslated text.
    /// Returns the set of page indices that failed object removal so the caller can fall back to Route A if needed.
    public func removeTranslatedTextObjectsToPDF(
        sourceURL: URL,
        outputStrippedURL: URL,
        documentIR: DocumentIR,
        password: String? = nil
    ) throws -> Set<Int> {
        guard cpdfium_is_loaded() != 0 else {
            throw PDFTranslateError.writerFailed("PDFium 动态库未加载")
        }

        let srcDoc: FPDF_DOCUMENT? = sourceURL.path.withCString { pathPtr in
            if let password, !password.isEmpty {
                return password.withCString { pwdPtr in
                    cpdfium_LoadDocument(pathPtr, pwdPtr)
                }
            } else {
                return cpdfium_LoadDocument(pathPtr, nil)
            }
        }
        guard let srcDoc else {
            throw PDFTranslateError.writerFailed("无法打开源 PDF 文档")
        }
        defer { cpdfium_CloseDocument(srcDoc) }

        guard let destDoc = cpdfium_CreateNewDocument() else {
            throw PDFTranslateError.writerFailed("无法创建目标 PDF 文档")
        }
        defer { cpdfium_CloseDocument(destDoc) }

        guard cpdfium_ImportPages(destDoc, srcDoc, nil, 0) != 0 else {
            throw PDFTranslateError.writerFailed("复制源页面到新文档失败")
        }
        _ = cpdfium_CopyViewerPreferences(destDoc, srcDoc)

        var failedPageIndices: Set<Int> = []

        for pageIR in documentIR.pages {
            try Task.checkCancellation()
            if pageIR.isScannedPage || pageIR.paragraphs.isEmpty {
                continue
            }
            if !stripTranslatedTextObjectsFromPage(destDoc: destDoc, pageIR: pageIR) {
                failedPageIndices.insert(pageIR.index)
            }
        }

        let saved = outputStrippedURL.path.withCString { outPathPtr in
            cpdfium_SaveDocumentToPath(destDoc, outPathPtr) != 0
        }
        if !saved {
            throw PDFTranslateError.writerFailed("保存去字底板 PDF 失败")
        }

        return failedPageIndices
    }

    private func stripTranslatedTextObjectsFromPage(
        destDoc: FPDF_DOCUMENT,
        pageIR: PageIR
    ) -> Bool {
        guard let page = cpdfium_LoadPage(destDoc, Int32(pageIR.index)) else {
            return false
        }
        defer { cpdfium_ClosePage(page) }

        var objectsToRemove = Set<Int>()
        for paragraph in pageIR.paragraphs where paragraph.layout != nil {
            for objID in paragraph.objectIDs where objID >= 0 {
                objectsToRemove.insert(objID)
            }
        }

        let pageObjCount = Int(cpdfium_PageCountObjects(page))
        let paraBoxes = pageIR.paragraphs.compactMap { $0.layout != nil ? $0.box.insetBy(dx: -1.5, dy: -1.5) : nil }
        for objIdx in 0..<pageObjCount where !objectsToRemove.contains(objIdx) {
            guard let obj = cpdfium_PageGetObject(page, Int32(objIdx)),
                  cpdfium_PageObjGetType(obj) == FPDF_PAGEOBJ_TEXT else { continue }
            var l: Float = 0, b: Float = 0, r: Float = 0, t: Float = 0
            if cpdfium_PageObjGetBounds(obj, &l, &b, &r, &t) != 0 {
                let objRect = CGRect(x: CGFloat(l), y: CGFloat(b), width: CGFloat(r - l), height: CGFloat(t - b))
                let center = CGPoint(x: objRect.midX, y: objRect.midY)
                if paraBoxes.contains(where: { pBox in
                    guard pBox.contains(center) else { return false }
                    let overlapW = min(pBox.maxX, objRect.maxX) - max(pBox.minX, objRect.minX)
                    return objRect.width <= 0.1 || overlapW >= objRect.width * 0.5
                }) {
                    objectsToRemove.insert(objIdx)
                }
            }
        }

        for objIdx in 0..<pageObjCount where !objectsToRemove.contains(objIdx) {
            guard let obj = cpdfium_PageGetObject(page, Int32(objIdx)) else { continue }
            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
            if cpdfium_PageObjGetFillColor(obj, &r, &g, &b, &a) != 0 {
                _ = cpdfium_PageObjSetFillColor(obj, r, g, b, a)
            }
            var sr: UInt32 = 0, sg: UInt32 = 0, sb: UInt32 = 0, sa: UInt32 = 0
            if cpdfium_PageObjGetStrokeColor(obj, &sr, &sg, &sb, &sa) != 0 {
                _ = cpdfium_PageObjSetStrokeColor(obj, sr, sg, sb, sa)
            }
        }

        for objIdx in objectsToRemove.sorted(by: >) where objIdx < pageObjCount {
            if let obj = cpdfium_PageGetObject(page, Int32(objIdx)),
               cpdfium_PageObjGetType(obj) == FPDF_PAGEOBJ_TEXT {
                if cpdfium_PageRemoveObject(page, obj) != 0 {
                    cpdfium_PageObjDestroy(obj)
                }
            }
        }

        return cpdfium_PageGenerateContent(page) != 0
    }

    /// Rewrites translated pages in-place on a copy of the source document using PDFium object editing (Route B).
    /// Returns the set of page indices that failed object-level rewriting so the caller can fall back to Route A.
    public func writeTranslatedMonoPDF(
        sourceURL: URL,
        outputMonoURL: URL,
        documentIR: DocumentIR,
        fontStyle: CJKFontStyle,
        password: String? = nil
    ) throws -> Set<Int> {
        guard cpdfium_is_loaded() != 0 else {
            throw PDFTranslateError.writerFailed("PDFium 动态库未加载")
        }

        let srcDoc: FPDF_DOCUMENT? = sourceURL.path.withCString { pathPtr in
            if let password, !password.isEmpty {
                return password.withCString { pwdPtr in
                    cpdfium_LoadDocument(pathPtr, pwdPtr)
                }
            } else {
                return cpdfium_LoadDocument(pathPtr, nil)
            }
        }
        guard let srcDoc else {
            throw PDFTranslateError.writerFailed("无法打开源 PDF 文档")
        }
        defer { cpdfium_CloseDocument(srcDoc) }

        guard let destDoc = cpdfium_CreateNewDocument() else {
            throw PDFTranslateError.writerFailed("无法创建目标 PDF 文档")
        }
        defer { cpdfium_CloseDocument(destDoc) }

        // Copy all pages from source into destination document
        guard cpdfium_ImportPages(destDoc, srcDoc, nil, 0) != 0 else {
            throw PDFTranslateError.writerFailed("复制源页面到新文档失败")
        }
        _ = cpdfium_CopyViewerPreferences(destDoc, srcDoc)

        // Collect all translated text for font subsetting
        let allTranslatedText = documentIR.pages
            .flatMap(\.paragraphs)
            .compactMap(\.translatedText)
            .joined()

        guard let ttfData = FontSubsetter.loadTrueTypeFontData(style: fontStyle, usedText: allTranslatedText) else {
            throw PDFTranslateError.writerFailed("无法加载中文字体数据")
        }

        let cjkFont: FPDF_FONT? = ttfData.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return cpdfium_TextLoadFont(destDoc, basePtr, UInt32(ttfData.count), FPDF_FONT_TRUETYPE, 1)
        }
        guard let cjkFont else {
            throw PDFTranslateError.writerFailed("PDFium 加载 TrueType 中文字体失败")
        }
        defer { cpdfium_FontClose(cjkFont) }

        let mathFallbackFont = "Times-Italic".withCString { cpdfium_TextLoadStandardFont(destDoc, $0) }
        defer {
            if let mathFallbackFont {
                cpdfium_FontClose(mathFallbackFont)
            }
        }

        var failedPageIndices: Set<Int> = []

        for pageIR in documentIR.pages {
            try Task.checkCancellation()
            if pageIR.isScannedPage || pageIR.paragraphs.isEmpty {
                continue
            }

            let ok = rewritePageObjects(
                destDoc: destDoc,
                pageIR: pageIR,
                cjkFont: cjkFont,
                mathFallbackFont: mathFallbackFont
            )
            if !ok {
                failedPageIndices.insert(pageIR.index)
            }
        }

        let saved = outputMonoURL.path.withCString { outPathPtr in
            cpdfium_SaveDocumentToPath(destDoc, outPathPtr) != 0
        }
        if !saved {
            throw PDFTranslateError.writerFailed("保存译文 PDF 到 \(outputMonoURL.lastPathComponent) 失败")
        }

        return failedPageIndices
    }

    private func rewritePageObjects(
        destDoc: FPDF_DOCUMENT,
        pageIR: PageIR,
        cjkFont: FPDF_FONT,
        mathFallbackFont: FPDF_FONT?
    ) -> Bool {
        guard let page = cpdfium_LoadPage(destDoc, Int32(pageIR.index)) else {
            return false
        }
        defer { cpdfium_ClosePage(page) }

        // Gather all object IDs belonging to translated paragraphs
        var objectsToRemove = Set<Int>()
        for paragraph in pageIR.paragraphs where paragraph.layout != nil {
            for objID in paragraph.objectIDs where objID >= 0 {
                objectsToRemove.insert(objID)
            }
        }

        // Also check if any text object inside translated paragraph boxes was not in objectIDs
        let pageObjCount = Int(cpdfium_PageCountObjects(page))
        let paraBoxes = pageIR.paragraphs.compactMap { $0.layout != nil ? $0.box.insetBy(dx: -1.5, dy: -1.5) : nil }
        for objIdx in 0..<pageObjCount where !objectsToRemove.contains(objIdx) {
            guard let obj = cpdfium_PageGetObject(page, Int32(objIdx)),
                  cpdfium_PageObjGetType(obj) == FPDF_PAGEOBJ_TEXT else { continue }
            var l: Float = 0, b: Float = 0, r: Float = 0, t: Float = 0
            if cpdfium_PageObjGetBounds(obj, &l, &b, &r, &t) != 0 {
                let objRect = CGRect(x: CGFloat(l), y: CGFloat(b), width: CGFloat(r - l), height: CGFloat(t - b))
                let center = CGPoint(x: objRect.midX, y: objRect.midY)
                if paraBoxes.contains(where: { pBox in
                    guard pBox.contains(center) else { return false }
                    let overlapW = min(pBox.maxX, objRect.maxX) - max(pBox.minX, objRect.minX)
                    return objRect.width <= 0.1 || overlapW >= objRect.width * 0.5
                }) {
                    objectsToRemove.insert(objIdx)
                }
            }
        }

        // Preserve explicit DeviceRGB fill/stroke colors on remaining objects before removing text objects
        // (prevents shared /Cs1 color-space operators inside removed text objects from leaving paths with default DeviceGray)
        for objIdx in 0..<pageObjCount where !objectsToRemove.contains(objIdx) {
            guard let obj = cpdfium_PageGetObject(page, Int32(objIdx)) else { continue }
            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
            if cpdfium_PageObjGetFillColor(obj, &r, &g, &b, &a) != 0 {
                _ = cpdfium_PageObjSetFillColor(obj, r, g, b, a)
            }
            var sr: UInt32 = 0, sg: UInt32 = 0, sb: UInt32 = 0, sa: UInt32 = 0
            if cpdfium_PageObjGetStrokeColor(obj, &sr, &sg, &sb, &sa) != 0 {
                _ = cpdfium_PageObjSetStrokeColor(obj, sr, sg, sb, sa)
            }
        }

        // Remove old body text objects in reverse index order
        for objIdx in objectsToRemove.sorted(by: >) where objIdx < pageObjCount {
            if let obj = cpdfium_PageGetObject(page, Int32(objIdx)),
               cpdfium_PageObjGetType(obj) == FPDF_PAGEOBJ_TEXT {
                if cpdfium_PageRemoveObject(page, obj) != 0 {
                    cpdfium_PageObjDestroy(obj)
                }
            }
        }

        // Insert new translated text and preserved formula runs
        var insertedCount = 0
        for paragraph in pageIR.paragraphs {
            guard let layout = paragraph.layout else { continue }
            for line in layout.lines {
                for run in line.runs {
                    switch run {
                    case .text(let str, let frame, let fontSize, let color, _):
                        let trimmed = str.trimmingCharacters(in: .newlines)
                        if trimmed.isEmpty { continue }
                        if insertTextRun(
                            doc: destDoc,
                            page: page,
                            font: cjkFont,
                            text: trimmed,
                            x: frame.minX,
                            baselineY: line.baselineY,
                            fontSize: fontSize,
                            color: color
                        ) {
                            insertedCount += 1
                        }
                    case .formula(_, let formulaChars, let targetFrame):
                        // Re-insert formula characters sequentially along the target line baseline,
                        // preserving relative subscript/superscript offsets without cross-line coordinate jumps.
                        var cursorX = targetFrame.minX
                        let baseBaselineY = line.baselineY
                        let origRefY = formulaChars.first?.box.minY ?? baseBaselineY

                        for (fIdx, fChar) in formulaChars.enumerated() {
                            let rawText = fChar.unicode.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Normalize Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF) to standard Latin/Greek glyphs
                            // so standard italic/CJK fonts can render every variable cleanly
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
                            let clampedDy: CGFloat
                            if abs(rawDy) <= fChar.fontSize * 0.65 {
                                clampedDy = rawDy
                            } else {
                                clampedDy = 0
                            }
                            let targetY = baseBaselineY + clampedDy
                            let chosenFont: FPDF_FONT
                            if let mathFallbackFont, charText.unicodeScalars.allSatisfy({ $0.value < 0x007F }) {
                                chosenFont = mathFallbackFont
                            } else {
                                chosenFont = cjkFont
                            }
                            if insertTextRun(
                                doc: destDoc,
                                page: page,
                                font: chosenFont,
                                text: charText,
                                x: cursorX,
                                baselineY: targetY,
                                fontSize: fChar.fontSize,
                                color: fChar.color
                            ) {
                                insertedCount += 1
                            }
                        }
                    }
                }
            }
        }

        let generated = cpdfium_PageGenerateContent(page) != 0
        return generated && (insertedCount > 0 || pageIR.paragraphs.isEmpty)
    }

    private func insertTextRun(
        doc: FPDF_DOCUMENT,
        page: FPDF_PAGE,
        font: FPDF_FONT,
        text: String,
        x: CGFloat,
        baselineY: CGFloat,
        fontSize: CGFloat,
        color: RGBAColor
    ) -> Bool {
        guard let textObj = cpdfium_PageObjCreateTextObj(doc, font, Float(max(4.0, fontSize))) else {
            return false
        }
        var utf16Units = Array(text.utf16)
        utf16Units.append(0)
        let setOk = utf16Units.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return false }
            return cpdfium_TextSetText(textObj, base) != 0
        }
        guard setOk else {
            cpdfium_PageObjDestroy(textObj)
            return false
        }

        _ = cpdfium_PageObjSetFillColor(
            textObj,
            UInt32(color.r),
            UInt32(color.g),
            UInt32(color.b),
            UInt32(color.a)
        )
        cpdfium_PageObjTransform(textObj, 1.0, 0.0, 0.0, 1.0, Double(x), Double(baselineY))
        cpdfium_PageInsertObject(page, textObj)
        return true
    }

    /// Creates a Dual (bilingual comparison) PDF using PDFium's page import and N-up APIs.
    public func writeDualPDF(
        sourceURL: URL,
        monoURL: URL,
        outputDualURL: URL,
        mode: DualLayoutMode,
        password: String? = nil
    ) -> Bool {
        guard cpdfium_is_loaded() != 0 else { return false }

        let srcDoc: FPDF_DOCUMENT? = sourceURL.path.withCString { pathPtr in
            if let password, !password.isEmpty {
                return password.withCString { pwdPtr in cpdfium_LoadDocument(pathPtr, pwdPtr) }
            }
            return cpdfium_LoadDocument(pathPtr, nil)
        }
        guard let srcDoc else { return false }
        defer { cpdfium_CloseDocument(srcDoc) }

        let monoDoc: FPDF_DOCUMENT? = monoURL.path.withCString { pathPtr in
            cpdfium_LoadDocument(pathPtr, nil)
        }
        guard let monoDoc else { return false }
        defer { cpdfium_CloseDocument(monoDoc) }

        let pageCount = min(Int(cpdfium_GetPageCount(srcDoc)), Int(cpdfium_GetPageCount(monoDoc)))
        guard pageCount > 0 else { return false }

        guard let interleavedDoc = cpdfium_CreateNewDocument() else { return false }
        defer { cpdfium_CloseDocument(interleavedDoc) }

        var firstPageWidth: Float = 595.0
        var firstPageHeight: Float = 842.0
        if let firstPage = cpdfium_LoadPage(srcDoc, 0) {
            firstPageWidth = max(100.0, cpdfium_GetPageWidthF(firstPage))
            firstPageHeight = max(100.0, cpdfium_GetPageHeightF(firstPage))
            cpdfium_ClosePage(firstPage)
        }

        // Interleave pages: Source 1, Mono 1, Source 2, Mono 2, ... (1-based page range in FPDF_ImportPages)
        for i in 1...pageCount {
            let rangeStr = "\(i)"
            let currentDestCount = cpdfium_GetPageCount(interleavedDoc)
            let okSrc = rangeStr.withCString { cpdfium_ImportPages(interleavedDoc, srcDoc, $0, currentDestCount) != 0 }
            let okMono = rangeStr.withCString { cpdfium_ImportPages(interleavedDoc, monoDoc, $0, currentDestCount + 1) != 0 }
            if !okSrc || !okMono { return false }
        }

        switch mode {
        case .alternating:
            return outputDualURL.path.withCString { outPtr in
                cpdfium_SaveDocumentToPath(interleavedDoc, outPtr) != 0
            }
        case .sideBySide:
            guard let nupDoc = cpdfium_ImportNPagesToOne(
                interleavedDoc,
                firstPageWidth * 2.0,
                firstPageHeight,
                2,
                1
            ) else {
                return false
            }
            defer { cpdfium_CloseDocument(nupDoc) }
            return outputDualURL.path.withCString { outPtr in
                cpdfium_SaveDocumentToPath(nupDoc, outPtr) != 0
            }
        }
    }
}
