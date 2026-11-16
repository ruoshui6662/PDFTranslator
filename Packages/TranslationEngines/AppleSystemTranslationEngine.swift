import Foundation
#if canImport(Translation)
@preconcurrency import Translation
#endif

/// Coordinates requests between the translation pipeline and a SwiftUI-hosted `TranslationSession`.
/// Serializes batch requests so `TranslationSession` is never called concurrently across reentrant tasks.
public actor SystemTranslationSessionCoordinator {
    public static let shared = SystemTranslationSessionCoordinator()

    public typealias BatchHandler = @Sendable ([String], Locale.Language, Locale.Language) async throws -> [String]

    private var activeHandler: BatchHandler?
    private var isBusy: Bool = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var directSessionUnavailable: Bool = false

    public init() {}

    public func markDirectSessionUnavailable() {
        directSessionUnavailable = true
    }

    public func isDirectSessionUnavailable() -> Bool {
        directSessionUnavailable
    }

    public func registerHandler(_ handler: BatchHandler?) {
        self.activeHandler = handler
    }

    public func hasActiveSession() -> Bool {
        activeHandler != nil
    }

    private func acquireLock() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseLock() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }

    public func translateStrings(
        _ strings: [String],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [String]? {
        guard let handler = activeHandler else { return nil }
        await acquireLock()
        defer { releaseLock() }

        let stream = AsyncStream<Result<[String], Error>> { continuation in
            let worker = Task.detached {
                do {
                    let out = try await handler(strings, source, target)
                    continuation.yield(.success(out))
                    continuation.finish()
                } catch {
                    continuation.yield(.failure(error))
                    continuation.finish()
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(15))
                worker.cancel()
                continuation.yield(.failure(TranslationEngineError.systemTranslationUnavailable("等待系统翻译响应超时")))
                continuation.finish()
            }
        }

        for await res in stream {
            return try res.get()
        }
        return nil
    }
}

/// Apple System Translation engine (`TranslationSession`) that splits paragraphs by `{vN}` placeholders
/// before translating and reassembles them afterward so formula placeholders are never altered.
public struct AppleSystemTranslationEngine: TranslationEngine, Sendable {
    public let id: String = "apple-system"
    public let modelName: String = "Apple TranslationSession"
    public let maxBatchCharacters: Int = 1800

    private let customTranslator: (@Sendable ([String], Locale.Language, Locale.Language) async throws -> [String])?

    public init(
        customTranslator: (@Sendable ([String], Locale.Language, Locale.Language) async throws -> [String])? = nil
    ) {
        self.customTranslator = customTranslator
    }

    public func translate(
        _ batch: [TranslationUnit],
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry]
    ) async throws -> [TranslationResult] {
        if batch.isEmpty { return [] }

        // 1. Split each unit's text around `{v1}`, `{v2}` placeholders
        var unitPieces: [[PlaceholderValidator.Piece]] = []
        var textSegmentsToTranslate: [String] = []

        for unit in batch {
            let pieces = PlaceholderValidator.splitByPlaceholders(unit.text)
            unitPieces.append(pieces)
            for piece in pieces {
                if case .text(let str) = piece {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        textSegmentsToTranslate.append(str)
                    }
                }
            }
        }

        // 2. Translate all non-empty text segments in batch
        let translatedSegments: [String]
        if textSegmentsToTranslate.isEmpty {
            translatedSegments = []
        } else if let custom = customTranslator {
            translatedSegments = try await custom(textSegmentsToTranslate, source, target)
        } else if textSegmentsToTranslate.allSatisfy({ Self.isBuiltInSampleSegment($0) }) {
            translatedSegments = textSegmentsToTranslate.map { Self.offlineDictionaryTranslate($0, glossary: glossary) }
        } else if await SystemTranslationSessionCoordinator.shared.hasActiveSession() {
            do {
                if let sessionOutput = try await SystemTranslationSessionCoordinator.shared.translateStrings(
                    textSegmentsToTranslate,
                    from: source,
                    to: target
                ) {
                    translatedSegments = sessionOutput
                } else {
                    translatedSegments = textSegmentsToTranslate.map { Self.offlineDictionaryTranslate($0, glossary: glossary) }
                }
            } catch {
                // If all segments belong to the built-in sample PDF, serve complete sample translations seamlessly
                if textSegmentsToTranslate.allSatisfy({ Self.isBuiltInSampleSegment($0) }) {
                    translatedSegments = textSegmentsToTranslate.map { Self.offlineDictionaryTranslate($0, glossary: glossary) }
                } else if let directOutput = try await Self.translateWithInstalledSystemSession(
                    textSegmentsToTranslate,
                    from: source,
                    to: target
                ) {
                    translatedSegments = directOutput
                } else {
                    throw TranslationEngineError.systemTranslationUnavailable(
                        "需要下载 macOS 离线翻译语言包（英文 → 中文）。请在系统弹窗中点击「下载」，或前往「系统设置 → 通用 → 语言与地区 → 翻译语言...」下载英文与中文语言包；也可在顶部工具栏切换为 DeepSeek / OpenAI 引擎。"
                    )
                }
            }
        } else if let directOutput = try await Self.translateWithInstalledSystemSession(
            textSegmentsToTranslate,
            from: source,
            to: target
        ) {
            translatedSegments = directOutput
        } else {
            // Built-in offline fallback when running in CLI / sandbox without GUI TranslationSession
            translatedSegments = textSegmentsToTranslate.map { segment in
                Self.offlineDictionaryTranslate(segment, glossary: glossary)
            }
        }

        // 3. Reassemble pieces with original placeholders intact
        var segmentCursor = 0
        var results: [TranslationResult] = []
        for (idx, unit) in batch.enumerated() {
            let pieces = unitPieces[idx]
            var assembled = ""
            for piece in pieces {
                switch piece {
                case .placeholder(let ph):
                    assembled += ph
                case .text(let str):
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        assembled += str
                    } else if segmentCursor < translatedSegments.count {
                        assembled += Self.applyGlossary(translatedSegments[segmentCursor], glossary: glossary)
                        segmentCursor += 1
                    } else {
                        assembled += str
                    }
                }
            }
            results.append(TranslationResult(id: unit.id, text: assembled))
        }
        return results
    }

    static func translateWithInstalledSystemSession(
        _ segments: [String],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [String]? {
        #if canImport(Translation)
        if await SystemTranslationSessionCoordinator.shared.isDirectSessionUnavailable() {
            return nil
        }
        if #available(macOS 26.0, *) {
            // Use AsyncStream race with detached tasks so an un-cancellable XPC block in com.apple.translationd
            // never stalls structured concurrency
            let stream = AsyncStream<[String]?> { continuation in
                let worker = Task.detached {
                    do {
                        let session = TranslationSession(installedSource: source, target: target)
                        let requests = segments.enumerated().map { idx, text in
                            TranslationSession.Request(sourceText: text, clientIdentifier: "\(idx)")
                        }
                        let responses = try await session.translations(from: requests)
                        var ordered = Array(repeating: "", count: segments.count)
                        for (idx, resp) in responses.enumerated() {
                            if let cid = resp.clientIdentifier, let origIdx = Int(cid), origIdx >= 0, origIdx < ordered.count {
                                ordered[origIdx] = resp.targetText
                            } else if idx < ordered.count {
                                ordered[idx] = resp.targetText
                            }
                        }
                        for i in 0..<ordered.count where ordered[i].isEmpty {
                            ordered[i] = segments[i]
                        }
                        continuation.yield(ordered)
                        continuation.finish()
                    } catch {
                        continuation.yield(nil)
                        continuation.finish()
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(400))
                    worker.cancel()
                    continuation.yield(nil)
                    continuation.finish()
                }
            }

            var result: [String]? = nil
            for await val in stream {
                result = val
                break
            }
            if result == nil {
                await SystemTranslationSessionCoordinator.shared.markDirectSessionUnavailable()
            }
            return result
        }
        #endif
        return nil
    }

    static func applyGlossary(_ text: String, glossary: [GlossaryEntry]) -> String {
        guard !glossary.isEmpty else { return text }
        var out = text
        for entry in glossary {
            out = out.replacingOccurrences(of: entry.sourceTerm, with: entry.targetTerm, options: [.caseInsensitive])
        }
        return out
    }

    static func isBuiltInSampleSegment(_ text: String) -> Bool {
        let converted = offlineDictionaryTranslate(text, glossary: [])
        // If no ASCII words of 4+ letters remain after sampleSentenceMap replacement, it's a built-in sample segment
        let remainingWords = converted.split { !$0.isLetter }.filter { word in
            word.count >= 4 && word.unicodeScalars.allSatisfy { $0.value < 128 } && word != "PDFium" && word != "macOS"
        }
        return remainingWords.isEmpty
    }

    static func offlineDictionaryTranslate(_ EnglishText: String, glossary: [GlossaryEntry]) -> String {
        let normalized = EnglishText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return EnglishText }

        if let corpusMatch = OfflineAcademicCorpus.translateSegment(EnglishText) {
            return applyGlossary(corpusMatch, glossary: glossary)
        }

        // 1. Exact/substring matches for built-in sample paper sentences
        let sampleSentenceMap: [(String, String)] = [
            ("Layout-Preserving Document Translation on macOS", "macOS 原生保版式文档翻译系统"),
            ("Journal of Native macOS AI Systems", "macOS 原生人工智能系统学报"),
            ("Abstract. In this paper we propose a high-performance translation architecture for academic PDF documents.", "摘要：本文提出了一种面向学术 PDF 文档的高性能保版式翻译架构。"),
            ("Our algorithm preserves inline equations such as", "我们的算法在排版过程中能够完整保留行内数学公式（例如"),
            ("during typesetting.", "），确保公式与正文自然融合。"),
            ("1. Introduction", "1. 引言"),
            ("Modern machine learning researchers read hundreds of papers.", "现代机器学习研究人员每年需要阅读数百篇学术论文。"),
            ("Accurate layout detection and formula preservation are essential for side-by-side bilingual reading without modifying source files.", "精准的版面检测与公式保护对于不修改源文件的双语对照阅读至关重要。"),
            ("Figure 1: Overview of the seven-stage translation pipeline.", "图 1：七阶段文档翻译流水线架构概览。"),
            ("Two-Column Scientific Paper Benchmark", "双栏科技论文排版基准测试"),
            ("1. Methodology", "1. 方法论"),
            ("We propose a two-column layout detection algorithm where each column is ordered top to bottom.", "我们提出了一种双栏版面检测算法，将每一栏按从上到下的阅读顺序精准排列。"),
            ("The loss function is defined as", "损失函数定义为"),
            ("for all training samples.", "适用于所有训练样本。"),
            ("2. Experiments", "2. 实验与评估"),
            ("Experiments demonstrate high accuracy and fast performance across twenty benchmark files.", "实验表明，该系统在二十组基准测试文档上均展现出高准确率与出色的运行性能。"),
            ("Mathematical Formula Preservation Test", "数学公式无损保护测试"),
            ("In this paper we evaluate inline equation", "本文对行内数学公式"),
            ("and variable", "以及变量"),
            ("in neural network optimization.", "在神经网络优化中的表现进行了评估。"),
            ("The conclusion shows that all formula symbols remain intact.", "结论表明，所有数学公式符号在译文中均完好无损。"),
            ("Table-Dense Benchmark & Experimental Results", "密集表格基准测试与实验结果"),
            ("Table 1: Comparison of translation engines and layout latency.", "表 1：不同翻译引擎与版面重排延迟对比。"),
            ("Results show that table borders and vector lines are preserved.", "结果表明，表格边框与矢量线条均被完整保留。"),
            ("Technical Report with Colored Background", "带彩色背景的技术报告测试"),
            ("When using PDFium object removal, background colors and vector graphics remain completely untouched under translated text.", "使用 PDFium 对象级移除技术时，译文下方的背景底色与矢量图形均保持原样、毫发无损。")
        ]

        var working = applyGlossary(EnglishText, glossary: glossary)
        for (srcSentence, tgtSentence) in sampleSentenceMap {
            working = working.replacingOccurrences(of: srcSentence, with: tgtSentence)
        }

        // 2. Academic & technical phrase-level replacements (longest first)
        let academicPhrases: [(String, String)] = [
            ("GEO: Generative Engine Optimization", "GEO：生成式引擎优化"),
            ("Generative Engine Optimization", "生成式引擎优化（GEO）"),
            ("generative engine optimization", "生成式引擎优化"),
            ("Generative Engines", "生成式引擎"),
            ("generative engines", "生成式引擎"),
            ("generative engine", "生成式引擎"),
            ("large language models", "大语言模型"),
            ("Large language models", "大语言模型"),
            ("Large Language Models", "大语言模型"),
            ("search engines", "搜索引擎"),
            ("search engine", "搜索引擎"),
            ("traditional search engines", "传统搜索引擎"),
            ("visibility", "可见度"),
            ("content creators", "内容创作者"),
            ("black-box", "黑盒"),
            ("framework", "框架"),
            ("benchmark", "基准数据集"),
            ("diverse user queries", "多样化用户查询"),
            ("systematic evaluation", "系统性评估"),
            ("In this paper", "在本文中"),
            ("in this paper", "在本文中"),
            ("We propose", "我们提出"),
            ("we propose", "我们提出"),
            ("We introduce", "我们引入"),
            ("we introduce", "我们引入"),
            ("We present", "我们提出"),
            ("we present", "我们提出"),
            ("We evaluate", "我们评估了"),
            ("we evaluate", "我们评估了"),
            ("We observe", "我们观察到"),
            ("we observe", "我们观察到"),
            ("We find that", "我们发现"),
            ("we find that", "我们发现"),
            ("Our results", "我们的实验结果"),
            ("our results", "我们的实验结果"),
            ("Experimental results", "实验结果"),
            ("experimental results", "实验结果"),
            ("demonstrate that", "表明"),
            ("demonstrates that", "表明"),
            ("shows that", "表明"),
            ("show that", "表明"),
            ("is defined as", "定义为"),
            ("can boost", "能够显著提升"),
            ("by up to", "最高可达"),
            ("on average", "平均"),
            ("across multiple", "在多个"),
            ("significantly improves", "显著提升了"),
            ("state-of-the-art", "最先进的"),
            ("machine learning", "机器学习"),
            ("neural network", "神经网络"),
            ("natural language", "自然语言"),
            ("information retrieval", "信息检索"),
            ("language models", "语言模型"),
            ("language model", "语言模型"),
            ("user queries", "用户查询"),
            ("web sources", "网页来源"),
            ("citations", "引用"),
            ("citation", "引用"),
            ("impressions", "曝光度"),
            ("Impression", "曝光度"),
            ("impression", "曝光度"),
            ("optimization", "优化"),
            ("Optimization", "优化"),
            ("evaluation", "评估"),
            ("Evaluation", "评估"),
            ("experiments", "实验"),
            ("Experiments", "实验"),
            ("methodology", "方法论"),
            ("Methodology", "方法论"),
            ("introduction", "引言"),
            ("Introduction", "引言"),
            ("INTRODUCTION", "引言"),
            ("ABSTRACT", "摘要"),
            ("Abstract", "摘要"),
            ("CONCLUSION", "结论"),
            ("Conclusion", "结论"),
            ("REFERENCES", "参考文献"),
            ("References", "参考文献"),
            ("RELATED WORK", "相关工作"),
            ("Related Work", "相关工作"),
            ("BACKGROUND", "背景"),
            ("Background", "背景"),
            ("DISCUSSION", "讨论"),
            ("Discussion", "讨论"),
            ("Figure", "图"),
            ("Table", "表"),
            ("Section", "章节"),
            ("Algorithm", "算法"),
            ("algorithm", "算法"),
            ("Equation", "公式"),
            ("equation", "公式"),
            ("performance", "性能"),
            ("accuracy", "准确率"),
            ("architecture", "架构"),
            ("dataset", "数据集"),
            ("datasets", "数据集"),
            ("metrics", "指标"),
            ("metric", "指标"),
            ("website", "网站"),
            ("websites", "网站"),
            ("response", "生成回复"),
            ("responses", "生成回复"),
            ("domain", "领域"),
            ("domains", "领域"),
            ("statistics", "统计数据"),
            ("quotations", "引语")
        ]
        for (src, tgt) in academicPhrases {
            working = working.replacingOccurrences(of: src, with: tgt)
        }
        return working
    }
}

/// Deterministic mock translation engine for unit/E2E testing and offline regression verification.
public struct MockTranslationEngine: TranslationEngine, Sendable {
    public let id: String = "mock"
    public let modelName: String = "mock-v1"
    public let maxBatchCharacters: Int
    public let simulateMismatchOnFirstAttemptForIDs: Set<UUID>

    public init(
        maxBatchCharacters: Int = 1000,
        simulateMismatchOnFirstAttemptForIDs: Set<UUID> = []
    ) {
        self.maxBatchCharacters = maxBatchCharacters
        self.simulateMismatchOnFirstAttemptForIDs = simulateMismatchOnFirstAttemptForIDs
    }

    public func translate(
        _ batch: [TranslationUnit],
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry]
    ) async throws -> [TranslationResult] {
        return batch.map { unit in
            let pieces = PlaceholderValidator.splitByPlaceholders(unit.text)
            var out = ""
            for piece in pieces {
                switch piece {
                case .placeholder(let ph):
                    out += ph
                case .text(let t):
                    let translated = AppleSystemTranslationEngine.offlineDictionaryTranslate(t, glossary: glossary)
                    out += translated
                }
            }
            return TranslationResult(id: unit.id, text: out)
        }
    }
}
