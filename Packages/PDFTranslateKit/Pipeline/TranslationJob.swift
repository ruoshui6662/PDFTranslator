import Foundation
import OSLog
import TranslationEngines

public enum PipelineStage: String, Sendable, Codable {
    case importing = "导入文档"
    case parsing = "解析文字与坐标"
    case detectingLayout = "版面检测"
    case buildingParagraphs = "段落组装"
    case guardingFormulas = "公式与样式识别"
    case translating = "AI 翻译"
    case typesetting = "重新排版"
    case writing = "生成译文与对照 PDF"
    case completed = "已完成"
}

public struct JobCompletionReport: Sendable, Codable, Equatable {
    public let sourceURL: URL
    public let monoURL: URL
    public let dualURL: URL
    public let totalPages: Int
    public let skippedScannedPages: [Int]
    public let overlayFallbackPages: [Int]
    public let fallbackToSourceParagraphCount: Int
    public let elapsedSeconds: Double
    public let documentIR: DocumentIR

    public init(
        sourceURL: URL,
        monoURL: URL,
        dualURL: URL,
        totalPages: Int,
        skippedScannedPages: [Int],
        overlayFallbackPages: [Int],
        fallbackToSourceParagraphCount: Int,
        elapsedSeconds: Double,
        documentIR: DocumentIR
    ) {
        self.sourceURL = sourceURL
        self.monoURL = monoURL
        self.dualURL = dualURL
        self.totalPages = totalPages
        self.skippedScannedPages = skippedScannedPages
        self.overlayFallbackPages = overlayFallbackPages
        self.fallbackToSourceParagraphCount = fallbackToSourceParagraphCount
        self.elapsedSeconds = elapsedSeconds
        self.documentIR = documentIR
    }
}

public enum JobEvent: Sendable {
    case stageChanged(stage: PipelineStage, currentPage: Int, totalPages: Int, fractionCompleted: Double)
    case estimatedCharacters(Int)
    case completed(JobCompletionReport)
    case failed(String)
    case cancelled
}

public struct TranslationJobConfiguration: Sendable {
    public var sourceLanguage: Locale.Language
    public var targetLanguage: Locale.Language
    public var glossary: [GlossaryEntry]
    public var customMathFontPatterns: [String]
    public var fontStyle: CJKFontStyle
    public var customFontPostScriptName: String?
    public var dualLayoutMode: DualLayoutMode
    public var minFontScaleRatio: CGFloat
    public var maxConcurrency: Int
    public var outputDirectory: URL?
    public var password: String?
    public var forceOverlayFallback: Bool

    public init(
        sourceLanguage: Locale.Language = Locale.Language(identifier: "en"),
        targetLanguage: Locale.Language = Locale.Language(identifier: "zh-Hans"),
        glossary: [GlossaryEntry] = [],
        customMathFontPatterns: [String] = [],
        fontStyle: CJKFontStyle = .autoMatch,
        customFontPostScriptName: String? = nil,
        dualLayoutMode: DualLayoutMode = .sideBySide,
        minFontScaleRatio: CGFloat = 0.60,
        maxConcurrency: Int = 4,
        outputDirectory: URL? = nil,
        password: String? = nil,
        forceOverlayFallback: Bool = false
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.customMathFontPatterns = customMathFontPatterns
        self.fontStyle = fontStyle
        self.customFontPostScriptName = customFontPostScriptName
        self.dualLayoutMode = dualLayoutMode
        self.minFontScaleRatio = minFontScaleRatio
        self.maxConcurrency = maxConcurrency
        self.outputDirectory = outputDirectory
        self.password = password
        self.forceOverlayFallback = forceOverlayFallback
    }
}

public actor TranslationJob {
    private let logger = Logger(subsystem: "com.pdftranslator.app", category: "TranslationJob")
    private let inputURL: URL
    private let engine: any TranslationEngine
    private let cache: TranslationCache
    private let configuration: TranslationJobConfiguration

    public init(
        inputURL: URL,
        engine: any TranslationEngine,
        cache: TranslationCache = .shared,
        configuration: TranslationJobConfiguration = TranslationJobConfiguration()
    ) {
        self.inputURL = inputURL
        self.engine = engine
        self.cache = cache
        self.configuration = configuration
    }

    /// Streams `JobEvent` updates across all 7 pipeline stages.
    public nonisolated func events() -> AsyncStream<JobEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.executePipeline(continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Runs the full pipeline and returns the final `JobCompletionReport`.
    public func run(
        onEvent: (@Sendable (JobEvent) -> Void)? = nil
    ) async throws -> JobCompletionReport {
        var finalReport: JobCompletionReport?
        var failureMessage: String?

        for await event in events() {
            onEvent?(event)
            switch event {
            case .completed(let report):
                finalReport = report
            case .failed(let message):
                failureMessage = message
            case .cancelled:
                throw PDFTranslateError.cancelled
            default:
                break
            }
        }

        if let finalReport {
            return finalReport
        }
        throw PDFTranslateError.writerFailed(failureMessage ?? "未知错误")
    }

    private func executePipeline(continuation: AsyncStream<JobEvent>.Continuation) async {
        let startTime = Date()
        var partialMonoURL: URL?
        var partialDualURL: URL?

        do {
            // Stage 1: Validate / Import PDF
            try Task.checkCancellation()
            continuation.yield(.stageChanged(stage: .importing, currentPage: 0, totalPages: 1, fractionCompleted: 0.02))
            let importer = PDFImporter()
            let localPDFURL: URL
            if inputURL.isFileURL {
                localPDFURL = try importer.validateLocalFile(inputURL)
            } else {
                localPDFURL = try await importer.downloadRemotePDF(from: inputURL.absoluteString) { progress in
                    continuation.yield(.stageChanged(stage: .importing, currentPage: 0, totalPages: 1, fractionCompleted: 0.02 + progress * 0.06))
                }
            }

            let outURLs = PDFWriter.defaultOutputURLs(for: localPDFURL, in: configuration.outputDirectory)
            partialMonoURL = outURLs.monoURL
            partialDualURL = outURLs.dualURL

            // Stage 2: Parse PDF characters & coordinates
            try Task.checkCancellation()
            let parser = PDFParser()
            var documentIR = try await parser.parse(url: localPDFURL, password: configuration.password) { page, total in
                let frac = 0.08 + (Double(page) / Double(max(1, total))) * 0.12
                continuation.yield(.stageChanged(stage: .parsing, currentPage: page, totalPages: total, fractionCompleted: frac))
            }

            let totalPages = documentIR.pages.count
            if documentIR.skippedScannedPages.count == totalPages {
                throw PDFTranslateError.scannedDocumentOnly(pageIndices: documentIR.skippedScannedPages)
            }

            // Stage 3: Layout Detection
            try Task.checkCancellation()
            try await LayoutDetector.shared.detect(document: &documentIR, pdfURL: localPDFURL) { page, total in
                let frac = 0.20 + (Double(page) / Double(max(1, total))) * 0.12
                continuation.yield(.stageChanged(stage: .detectingLayout, currentPage: page, totalPages: total, fractionCompleted: frac))
            }

            // Stage 4: Paragraph Assembly
            try Task.checkCancellation()
            continuation.yield(.stageChanged(stage: .buildingParagraphs, currentPage: totalPages, totalPages: totalPages, fractionCompleted: 0.35))
            let paragraphBuilder = ParagraphBuilder()
            paragraphBuilder.buildParagraphs(document: &documentIR)

            // Stage 5: Formula & Style Guard
            try Task.checkCancellation()
            continuation.yield(.stageChanged(stage: .guardingFormulas, currentPage: totalPages, totalPages: totalPages, fractionCompleted: 0.40))
            let formulaGuard = FormulaGuard(customFontPatterns: configuration.customMathFontPatterns)
            formulaGuard.protectFormulas(document: &documentIR)

            let estimatedChars = documentIR.totalTranslatableCharacters
            continuation.yield(.estimatedCharacters(estimatedChars))

            // Stage 6: AI Translation (with batching, bounded concurrency, retry, placeholder validation, SQLite cache)
            try Task.checkCancellation()
            var allUnits: [TranslationUnit] = []
            for page in documentIR.pages where !page.isScannedPage {
                for para in page.paragraphs
                where !para.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !para.overlapsNonTranslatableRegion {
                    allUnits.append(TranslationUnit(id: para.id, text: para.sourceText))
                }
            }

            let dispatcher = TranslationDispatcher(
                engine: engine,
                cache: cache,
                maxConcurrency: configuration.maxConcurrency
            )

            let results = try await dispatcher.translateAll(
                allUnits,
                from: configuration.sourceLanguage,
                to: configuration.targetLanguage,
                glossary: configuration.glossary
            ) { doneUnits, totalUnits in
                let unitRatio = totalUnits > 0 ? Double(doneUnits) / Double(totalUnits) : 1.0
                let estPage = max(1, Int( round(unitRatio * Double(totalPages)) ))
                let frac = 0.42 + unitRatio * 0.36
                continuation.yield(.stageChanged(stage: .translating, currentPage: min(totalPages, estPage), totalPages: totalPages, fractionCompleted: frac))
            }

            let resultMap = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            var fallbackParagraphCount = 0
            for pIdx in 0..<documentIR.pages.count {
                for paraIdx in 0..<documentIR.pages[pIdx].paragraphs.count {
                    let paraID = documentIR.pages[pIdx].paragraphs[paraIdx].id
                    if let res = resultMap[paraID] {
                        documentIR.pages[pIdx].paragraphs[paraIdx].translatedText = res.text
                        documentIR.pages[pIdx].paragraphs[paraIdx].fellBackToSource = res.fellBackToSource
                        if res.fellBackToSource {
                            fallbackParagraphCount += 1
                        }
                    } else {
                        // Either no translation unit was emitted (e.g. paragraph overlaps a figure/table region) or the
                        // dispatcher skipped it. Keep the source text so PDFium's text-removal phase leaves the
                        // original object untouched and the bitmap/vector art underneath remains legible.
                        documentIR.pages[pIdx].paragraphs[paraIdx].translatedText = documentIR.pages[pIdx].paragraphs[paraIdx].sourceText
                    }
                }
            }

            // Stage 7: Core Text Typesetting
            try Task.checkCancellation()
            continuation.yield(.stageChanged(stage: .typesetting, currentPage: totalPages, totalPages: totalPages, fractionCompleted: 0.82))
            let typesetter = Typesetter(
                configuration: TypesetterConfiguration(
                    fontStyle: configuration.fontStyle,
                    customFontPostScriptName: configuration.customFontPostScriptName,
                    minFontScaleRatio: configuration.minFontScaleRatio
                )
            )
            typesetter.typesetDocument(&documentIR)

            // Save IR checkpoint for debugging / resume
            Self.saveIRCheckpoint(documentIR, for: localPDFURL)

            // Stage 8: Write Mono & Dual PDFs
            try Task.checkCancellation()
            continuation.yield(.stageChanged(stage: .writing, currentPage: totalPages, totalPages: totalPages, fractionCompleted: 0.90))
            let writer = PDFWriter(
                configuration: PDFWriterConfiguration(
                    fontStyle: configuration.fontStyle,
                    customFontPostScriptName: configuration.customFontPostScriptName,
                    dualLayoutMode: configuration.dualLayoutMode,
                    forceOverlayFallback: configuration.forceOverlayFallback
                )
            )
            let writeOutput = try await writer.write(
                sourceURL: localPDFURL,
                documentIR: documentIR,
                monoURL: outURLs.monoURL,
                dualURL: outURLs.dualURL,
                password: configuration.password
            )

            let elapsed = Date().timeIntervalSince(startTime)
            logger.info("Finished translating PDF (\(totalPages, privacy: .public) pages) in \(elapsed, privacy: .public)s")

            let report = JobCompletionReport(
                sourceURL: localPDFURL,
                monoURL: writeOutput.monoURL,
                dualURL: writeOutput.dualURL,
                totalPages: totalPages,
                skippedScannedPages: documentIR.skippedScannedPages,
                overlayFallbackPages: writeOutput.overlayFallbackPages,
                fallbackToSourceParagraphCount: fallbackParagraphCount,
                elapsedSeconds: elapsed,
                documentIR: documentIR
            )
            continuation.yield(.stageChanged(stage: .completed, currentPage: totalPages, totalPages: totalPages, fractionCompleted: 1.0))
            continuation.yield(.completed(report))
            continuation.finish()

        } catch is CancellationError {
            cleanupPartialFiles(mono: partialMonoURL, dual: partialDualURL)
            continuation.yield(.cancelled)
            continuation.finish()
        } catch let err as PDFTranslateError where err == .cancelled {
            cleanupPartialFiles(mono: partialMonoURL, dual: partialDualURL)
            continuation.yield(.cancelled)
            continuation.finish()
        } catch {
            cleanupPartialFiles(mono: partialMonoURL, dual: partialDualURL)
            let userMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Translation job failed: \(userMsg, privacy: .public)")
            continuation.yield(.failed(userMsg))
            continuation.finish()
        }
    }

    private func cleanupPartialFiles(mono: URL?, dual: URL?) {
        if let mono, FileManager.default.fileExists(atPath: mono.path) {
            try? FileManager.default.removeItem(at: mono)
        }
        if let dual, FileManager.default.fileExists(atPath: dual.path) {
            try? FileManager.default.removeItem(at: dual)
        }
    }

    public static func saveIRCheckpoint(_ ir: DocumentIR, for sourceURL: URL) {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let checkpointDir = cachesDir.appendingPathComponent("com.pdftranslator.app/checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let fileURL = checkpointDir.appendingPathComponent("\(stem)-ir.json")
        if let data = try? JSONEncoder().encode(ir) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public static func loadIRCheckpoint(for sourceURL: URL) -> DocumentIR? {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let fileURL = cachesDir.appendingPathComponent("com.pdftranslator.app/checkpoints/\(stem)-ir.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DocumentIR.self, from: data)
    }

    /// Re-translates only a single page (`pageIndex`) in an already-parsed `JobCompletionReport`,
    /// invalidating cache entries for that page's paragraphs, re-typesetting the page, and updating both output PDFs.
    public static func retranslateSinglePage(
        pageIndex: Int,
        existingReport: JobCompletionReport,
        engine: any TranslationEngine,
        cache: TranslationCache = .shared,
        configuration: TranslationJobConfiguration = TranslationJobConfiguration()
    ) async throws -> JobCompletionReport {
        let startTime = Date()
        var documentIR = existingReport.documentIR
        guard pageIndex >= 0, pageIndex < documentIR.pages.count else {
            return existingReport
        }

        var pageUnits: [TranslationUnit] = []
        for para in documentIR.pages[pageIndex].paragraphs {
            let trimmed = para.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let key = TranslationCache.makeKey(
                engineID: engine.id,
                model: engine.modelName,
                sourceLanguage: configuration.sourceLanguage,
                targetLanguage: configuration.targetLanguage,
                sourceText: para.sourceText
            )
            await cache.remove(forKey: key)
            pageUnits.append(TranslationUnit(id: para.id, text: para.sourceText))
        }

        let dispatcher = TranslationDispatcher(
            engine: engine,
            cache: cache,
            maxConcurrency: configuration.maxConcurrency
        )
        let results = try await dispatcher.translateAll(
            pageUnits,
            from: configuration.sourceLanguage,
            to: configuration.targetLanguage,
            glossary: configuration.glossary
        )
        let resultMap = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

        for paraIdx in 0..<documentIR.pages[pageIndex].paragraphs.count {
            let pid = documentIR.pages[pageIndex].paragraphs[paraIdx].id
            if let res = resultMap[pid] {
                documentIR.pages[pageIndex].paragraphs[paraIdx].translatedText = res.text
                documentIR.pages[pageIndex].paragraphs[paraIdx].fellBackToSource = res.fellBackToSource
            }
        }

        let typesetter = Typesetter(
            configuration: TypesetterConfiguration(
                fontStyle: configuration.fontStyle,
                customFontPostScriptName: configuration.customFontPostScriptName,
                minFontScaleRatio: configuration.minFontScaleRatio
            )
        )
        typesetter.typesetPage(&documentIR.pages[pageIndex])
        saveIRCheckpoint(documentIR, for: existingReport.sourceURL)

        let writer = PDFWriter(
            configuration: PDFWriterConfiguration(
                fontStyle: configuration.fontStyle,
                customFontPostScriptName: configuration.customFontPostScriptName,
                dualLayoutMode: configuration.dualLayoutMode,
                forceOverlayFallback: configuration.forceOverlayFallback
            )
        )
        let writeOutput = try await writer.write(
            sourceURL: existingReport.sourceURL,
            documentIR: documentIR,
            monoURL: existingReport.monoURL,
            dualURL: existingReport.dualURL,
            password: configuration.password
        )

        let totalFallbacks = documentIR.pages.flatMap(\.paragraphs).filter(\.fellBackToSource).count
        return JobCompletionReport(
            sourceURL: existingReport.sourceURL,
            monoURL: writeOutput.monoURL,
            dualURL: writeOutput.dualURL,
            totalPages: documentIR.pages.count,
            skippedScannedPages: documentIR.skippedScannedPages,
            overlayFallbackPages: writeOutput.overlayFallbackPages,
            fallbackToSourceParagraphCount: totalFallbacks,
            elapsedSeconds: Date().timeIntervalSince(startTime),
            documentIR: documentIR
        )
    }

    /// Re-typesets and re-renders the entire document using the updated font or layout settings
    /// without re-running the AI translation step.
    public static func retypesetDocument(
        existingReport: JobCompletionReport,
        configuration: TranslationJobConfiguration
    ) async throws -> JobCompletionReport {
        let startTime = Date()
        var documentIR = existingReport.documentIR
        let typesetter = Typesetter(
            configuration: TypesetterConfiguration(
                fontStyle: configuration.fontStyle,
                customFontPostScriptName: configuration.customFontPostScriptName,
                minFontScaleRatio: configuration.minFontScaleRatio
            )
        )
        typesetter.typesetDocument(&documentIR)
        saveIRCheckpoint(documentIR, for: existingReport.sourceURL)

        let writer = PDFWriter(
            configuration: PDFWriterConfiguration(
                fontStyle: configuration.fontStyle,
                customFontPostScriptName: configuration.customFontPostScriptName,
                dualLayoutMode: configuration.dualLayoutMode,
                forceOverlayFallback: configuration.forceOverlayFallback
            )
        )
        let writeOutput = try await writer.write(
            sourceURL: existingReport.sourceURL,
            documentIR: documentIR,
            monoURL: existingReport.monoURL,
            dualURL: existingReport.dualURL,
            password: configuration.password
        )

        let totalFallbacks = documentIR.pages.flatMap(\.paragraphs).filter(\.fellBackToSource).count
        return JobCompletionReport(
            sourceURL: existingReport.sourceURL,
            monoURL: writeOutput.monoURL,
            dualURL: writeOutput.dualURL,
            totalPages: documentIR.pages.count,
            skippedScannedPages: documentIR.skippedScannedPages,
            overlayFallbackPages: writeOutput.overlayFallbackPages,
            fallbackToSourceParagraphCount: totalFallbacks,
            elapsedSeconds: Date().timeIntervalSince(startTime),
            documentIR: documentIR
        )
    }
}
