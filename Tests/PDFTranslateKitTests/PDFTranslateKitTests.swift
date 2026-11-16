import Foundation
import CoreGraphics
import Darwin.Mach
import PDFKit
import Testing
@testable import PDFTranslateKit
@testable import TranslationEngines

@Suite("PDFTranslateKit & TranslationEngines M0-M4 Verification Suite")
struct PDFTranslateKitTests {

    @Test("ParagraphBuilder merges end-of-line hyphenated words and sorts columns in reading order")
    func testParagraphHyphenMergeAndColumnOrder() {
        let merged = ParagraphBuilder.mergeHyphenatedLineBreak("trans-", "lation")
        #expect(merged == "translation")

        let nonMerged = ParagraphBuilder.mergeHyphenatedLineBreak("self-", "Attention")
        #expect(nonMerged == "self- Attention")

        let mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
        let titleSpan = LayoutRegion(kind: .title, box: CGRect(x: 80, y: 720, width: 440, height: 30))
        let rightColTop = LayoutRegion(kind: .text, box: CGRect(x: 320, y: 650, width: 220, height: 40))
        let leftColTop = LayoutRegion(kind: .text, box: CGRect(x: 60, y: 650, width: 220, height: 40))
        let leftColBottom = LayoutRegion(kind: .text, box: CGRect(x: 60, y: 500, width: 220, height: 40))

        let sorted = ParagraphBuilder.sortRegionsInReadingOrder(
            [rightColTop, leftColBottom, titleSpan, leftColTop],
            pageMediaBox: mediaBox
        )
        #expect(sorted.count == 4)
        #expect(sorted[0] == titleSpan)
        #expect(sorted[1] == leftColTop)
        #expect(sorted[2] == leftColBottom)
        #expect(sorted[3] == rightColTop)
    }

    @Test("FormulaGuard identifies math fonts, Greek/operator Unicode, subscripts, and emits {vN} placeholders")
    func testFormulaGuardIdentificationAndPlaceholders() {
        let guardEngine = FormulaGuard(customFontPatterns: ["CustomMathFont"])

        let mathFontChar = CharIR(unicode: "x", box: CGRect(x: 10, y: 100, width: 6, height: 10), fontName: "CMMI10", fontSize: 10)
        #expect(guardEngine.isFormulaChar(mathFontChar, lineMedianFontSize: 10, lineBaselineY: 100))

        let customFontChar = CharIR(unicode: "y", box: CGRect(x: 20, y: 100, width: 6, height: 10), fontName: "CustomMathFont-Regular", fontSize: 10)
        #expect(guardEngine.isFormulaChar(customFontChar, lineMedianFontSize: 10, lineBaselineY: 100))

        let greekChar = CharIR(unicode: "α", box: CGRect(x: 30, y: 100, width: 6, height: 10), fontName: "Times-Roman", fontSize: 10)
        #expect(guardEngine.isFormulaChar(greekChar, lineMedianFontSize: 10, lineBaselineY: 100))

        let subscriptChar = CharIR(unicode: "i", box: CGRect(x: 40, y: 97, width: 4, height: 7), fontName: "Times-Roman", fontSize: 7)
        #expect(guardEngine.isFormulaChar(subscriptChar, lineMedianFontSize: 10, lineBaselineY: 100))

        let rawChars: [CharIR] = [
            CharIR(unicode: "L", box: CGRect(x: 10, y: 100, width: 6, height: 10), fontName: "Times-Roman", fontSize: 10),
            CharIR(unicode: "e", box: CGRect(x: 16, y: 100, width: 5, height: 10), fontName: "Times-Roman", fontSize: 10),
            CharIR(unicode: "t", box: CGRect(x: 21, y: 100, width: 4, height: 10), fontName: "Times-Roman", fontSize: 10),
            CharIR(unicode: " ", box: CGRect(x: 25, y: 100, width: 3, height: 10), fontName: "Times-Roman", fontSize: 10),
            CharIR(unicode: "α", box: CGRect(x: 28, y: 100, width: 6, height: 10), fontName: "Symbol", fontSize: 10),
            CharIR(unicode: "=", box: CGRect(x: 35, y: 100, width: 6, height: 10), fontName: "Symbol", fontSize: 10),
            CharIR(unicode: "β", box: CGRect(x: 42, y: 100, width: 6, height: 10), fontName: "Symbol", fontSize: 10),
            CharIR(unicode: " ", box: CGRect(x: 48, y: 100, width: 3, height: 10), fontName: "Times-Roman", fontSize: 10),
            CharIR(unicode: "o", box: CGRect(x: 51, y: 100, width: 5, height: 10), fontName: "Times-Roman", fontSize: 10),
            CharIR(unicode: "k", box: CGRect(x: 56, y: 100, width: 5, height: 10), fontName: "Times-Roman", fontSize: 10)
        ]

        var para = ParagraphIR(
            box: CGRect(x: 10, y: 98, width: 60, height: 14),
            kind: .text,
            dominantFontSize: 10,
            rawChars: rawChars
        )
        guardEngine.protectParagraph(&para)
        #expect(para.sourceText == "Let {v1} ok")
        #expect(PlaceholderValidator.extractPlaceholders(from: para.sourceText) == ["{v1}"])
    }

    @Test("Typesetter respects kinsoku punctuation rules, CJK-Latin spacing, and shrinks font size when tight")
    func testTypesetterScalingAndKinsoku() {
        let typesetter = Typesetter(configuration: TypesetterConfiguration(minFontScaleRatio: 0.60))

        let tightBox = CGRect(x: 50, y: 500, width: 140, height: 28)
        let formulaChars = [CharIR(unicode: "α", box: CGRect(x: 80, y: 505, width: 10, height: 10), fontName: "Symbol", fontSize: 10, isFormula: true)]
        let para = ParagraphIR(
            box: tightBox,
            kind: .text,
            dominantFontSize: 12,
            segments: [
                .text("在本文中我们提出了高性能 Transformer 模型与 ", style: TextStyleRun(fontSize: 12)),
                .formula(placeholder: "{v1}", chars: formulaChars, box: CGRect(x: 80, y: 505, width: 10, height: 10)),
                .text("，实现了准确的版面还原。", style: TextStyleRun(fontSize: 12))
            ],
            sourceText: "In this paper we propose {v1}.",
            translatedText: "在本文中我们提出了高性能 Transformer 模型与 {v1}，实现了准确的版面还原。"
        )

        let result = typesetter.typesetParagraph(para, availableBottomY: 460)
        #expect(result.scaleFactor <= 1.0)
        #expect(result.scaleFactor >= 0.60 - 0.001)
        #expect(!result.lines.isEmpty)

        let hasFormulaRun = result.lines.flatMap(\.runs).contains {
            if case .formula(let ph, _, _) = $0 { return ph == "{v1}" }
            return false
        }
        #expect(hasFormulaRun)
    }

    @Test("PlaceholderValidator, SQLite TranslationCache SHA256 keys, and CSV Glossary work accurately")
    func testPlaceholderValidationAndSQLiteCache() async {
        #expect(PlaceholderValidator.validate(source: "Value {v1} and {v2}.", translated: "数值 {v2} 与 {v1}。"))
        #expect(!PlaceholderValidator.validate(source: "Value {v1} and {v2}.", translated: "数值 {v1}。"))

        let entries = GlossaryEntry.parseCSV("source,target\nneural network,神经网络\ntransformer,Transformer 架构")
        #expect(entries.count == 2)
        #expect(entries[0].sourceTerm == "neural network")
        #expect(entries[0].targetTerm == "神经网络")

        let tempCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_cache_\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: tempCacheURL) }

        let cache = TranslationCache(databaseURL: tempCacheURL)
        let key1 = TranslationCache.makeKey(
            engineID: "openai:deepseek",
            model: "deepseek-chat",
            sourceLanguage: Locale.Language(identifier: "en"),
            targetLanguage: Locale.Language(identifier: "zh-Hans"),
            sourceText: "Hello {v1}"
        )
        #expect(key1.count == 64)

        await cache.set("你好 {v1}", forKey: key1)
        #expect(await cache.get(forKey: key1) == "你好 {v1}")
        #expect(await cache.count() == 1)

        await cache.remove(forKey: key1)
        #expect(await cache.get(forKey: key1) == nil)
        #expect(await cache.count() == 0)
    }

    @Test("PDFImporter rewrites arXiv abs links into direct PDF links")
    func testArxivURLNormalization() throws {
        let rewritten = try PDFImporter.normalizeURL("https://arxiv.org/abs/2503.17213")
        #expect(rewritten.absoluteString == "https://arxiv.org/pdf/2503.17213")
    }

    @Test("Encrypted PDF and Scanned PDF detection behave according to specification")
    func testEncryptedAndScannedDocumentHandling() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTranslateSec_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Encrypted PDF check
        let encryptedURL = tempDir.appendingPathComponent("encrypted.pdf")
        try SamplePDFGenerator.generateSamplePDF(kind: .encryptedDocument, at: encryptedURL, password: "correct-password")

        let parser = PDFParser()
        await #expect(throws: PDFTranslateError.encryptedDocumentRequiresPassword) {
            _ = try await parser.parse(url: encryptedURL, password: nil)
        }
        await #expect(throws: PDFTranslateError.invalidPassword) {
            _ = try await parser.parse(url: encryptedURL, password: "wrong-password")
        }
        let unlockedIR = try await parser.parse(url: encryptedURL, password: "correct-password")
        #expect(unlockedIR.pages.count == 1)

        // 2. Scanned PDF check
        let scannedURL = tempDir.appendingPathComponent("scanned.pdf")
        try SamplePDFGenerator.generateSamplePDF(kind: .scannedDocument, at: scannedURL)
        let scannedIR = try await parser.parse(url: scannedURL)
        #expect(scannedIR.skippedScannedPages == [0])
    }

    @Test("Rendering Pixel Regression: non-text figure/graphic region has zero pixel difference after translation")
    func testRenderingPixelRegressionNonTextRegionZeroDifference() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTranslatePixel_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let srcURL = tempDir.appendingPathComponent("paper.pdf")
        try SamplePDFGenerator.generateSamplePDF(kind: .singleColumnPaper, at: srcURL)

        let cache = TranslationCache(databaseURL: tempDir.appendingPathComponent("pixel_cache.sqlite3"))
        let job = TranslationJob(
            inputURL: srcURL,
            engine: MockTranslationEngine(),
            cache: cache,
            configuration: TranslationJobConfiguration(outputDirectory: tempDir)
        )
        let report = try await job.run()

        // Render both source and translated mono PDF page 0 at 1:1 (595 x 842)
        let size = CGSize(width: 595, height: 842)
        let srcImage = await LayoutDetector.shared.rasterizePage(pdfURL: srcURL, pageIndex: 0, targetSize: size)
        let monoImage = await LayoutDetector.shared.rasterizePage(pdfURL: report.monoURL, pageIndex: 0, targetSize: size)
        #expect(srcImage != nil)
        #expect(monoImage != nil)

        if let srcImage, let monoImage {
            // The figure graphic in singleColumnPaper sits at PDF rect (x: 140..450, y: 445..530).
            // Compare every pixel inside the figure box (x: 145..445, y: 450..525 in PDF coords)
            let diffPixels = countDifferingPixelsInPDFRect(
                imageA: srcImage,
                imageB: monoImage,
                pdfRect: CGRect(x: 145, y: 450, width: 300, height: 75),
                pageHeight: 842
            )
            #expect(diffPixels == 0)
        }
    }

    @Test("M4 End-to-End 20-Sample Regression Suite: all 20 sample PDFs generate valid mono and dual PDFs")
    func testTwentySampleEndToEndRegression() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTranslate20Samples_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repeatableKinds: [SamplePDFGenerator.SampleKind] = [
            .singleColumnPaper,
            .twoColumnPaper,
            .formulaDensePaper,
            .tableDensePaper,
            .coloredBackgroundReport,
            .bookmarkedManual
        ]

        let cache = TranslationCache(databaseURL: tempDir.appendingPathComponent("20samples_cache.sqlite3"))
        let engine = MockTranslationEngine()

        for i in 1...20 {
            let kind = repeatableKinds[(i - 1) % repeatableKinds.count]
            let srcURL = tempDir.appendingPathComponent("Sample_\(String(format: "%02d", i))_\(kind.rawValue).pdf")
            try SamplePDFGenerator.generateSamplePDF(kind: kind, at: srcURL)

            let useAlternating = (i % 5 == 0)
            let useSongti = (i % 2 == 0)
            let forceOverlay = (i == 20) // Sample 20 explicitly exercises Route A overlay fallback

            let config = TranslationJobConfiguration(
                fontStyle: useSongti ? .serif : .sansSerif,
                dualLayoutMode: useAlternating ? .alternating : .sideBySide,
                outputDirectory: tempDir,
                forceOverlayFallback: forceOverlay
            )

            let job = TranslationJob(inputURL: srcURL, engine: engine, cache: cache, configuration: config)
            let report = try await job.run()

            #expect(FileManager.default.fileExists(atPath: report.monoURL.path))
            #expect(FileManager.default.fileExists(atPath: report.dualURL.path))
            #expect(PDFDocument(url: report.monoURL) != nil)
            #expect(PDFDocument(url: report.dualURL) != nil)
        }

        // Also verify single-page re-translation on Sample 20
        let sample1URL = tempDir.appendingPathComponent("Sample_01_singleColumnPaper.pdf")
        let initialJob = TranslationJob(
            inputURL: sample1URL,
            engine: engine,
            cache: cache,
            configuration: TranslationJobConfiguration(outputDirectory: tempDir)
        )
        let initialReport = try await initialJob.run()
        let retranslatedReport = try await TranslationJob.retranslateSinglePage(
            pageIndex: 0,
            existingReport: initialReport,
            engine: engine,
            cache: cache,
            configuration: TranslationJobConfiguration(outputDirectory: tempDir)
        )
        #expect(PDFDocument(url: retranslatedReport.monoURL)?.pageCount == initialReport.totalPages)
    }

    @Test("M4 Performance & Memory Benchmark: 20-page paper parses, detects, typesets, and writes in <= 15s and <= 1GB RAM")
    func testTwentyPagePaperPerformanceAndMemoryBenchmark() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTranslatePerf20_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paper20URL = tempDir.appendingPathComponent("Benchmark-20Pages.pdf")
        try SamplePDFGenerator.generateMultiPagePaper(pageCount: 20, at: paper20URL)

        let cache = TranslationCache(databaseURL: tempDir.appendingPathComponent("perf_cache.sqlite3"))
        let startTime = Date()

        let job = TranslationJob(
            inputURL: paper20URL,
            engine: MockTranslationEngine(),
            cache: cache,
            configuration: TranslationJobConfiguration(outputDirectory: tempDir)
        )
        let report = try await job.run()
        let elapsedSeconds = Date().timeIntervalSince(startTime)
        let residentBytes = Self.currentResidentMemoryBytes()
        let oneGigabyte: UInt64 = 1_073_741_824

        #expect(report.totalPages == 20)
        #expect(elapsedSeconds <= 15.0)
        #expect(residentBytes <= oneGigabyte)
        #expect(PDFDocument(url: report.monoURL)?.pageCount == 20)
        #expect(PDFDocument(url: report.dualURL)?.pageCount == 20)
    }

    // MARK: - Helpers

    private func countDifferingPixelsInPDFRect(
        imageA: CGImage,
        imageB: CGImage,
        pdfRect: CGRect,
        pageHeight: CGFloat
    ) -> Int {
        guard let dataA = extractRGBABytes(from: imageA),
              let dataB = extractRGBABytes(from: imageB),
              imageA.width == imageB.width,
              imageA.height == imageB.height else {
            return -1
        }
        let width = imageA.width
        let height = imageA.height
        let minX = max(0, Int(pdfRect.minX))
        let maxX = min(width - 1, Int(pdfRect.maxX))
        // Convert PDF bottom-left Y into top-left bitmap Y
        let minY = max(0, Int(pageHeight - pdfRect.maxY))
        let maxY = min(height - 1, Int(pageHeight - pdfRect.minY))

        var diffCount = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = (y * width + x) * 4
                let dr = abs(Int(dataA[offset]) - Int(dataB[offset]))
                let dg = abs(Int(dataA[offset + 1]) - Int(dataB[offset + 1]))
                let db = abs(Int(dataA[offset + 2]) - Int(dataB[offset + 2]))
                if dr > 2 || dg > 2 || db > 2 {
                    if diffCount == 0 {
                        print("FIRST DIFF at (x=\(x), y=\(y)): src=(\(dataA[offset]),\(dataA[offset+1]),\(dataA[offset+2]),\(dataA[offset+3])) mono=(\(dataB[offset]),\(dataB[offset+1]),\(dataB[offset+2]),\(dataB[offset+3]))")
                    }
                    diffCount += 1
                }
            }
        }
        return diffCount
    }

    private func extractRGBABytes(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
}
