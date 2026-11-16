import Foundation

public struct TranslationDispatcher: Sendable {
    public let engine: any TranslationEngine
    public let cache: TranslationCache
    public let maxConcurrency: Int
    public let maxRetries: Int
    public let baseRetryDelaySeconds: Double

    public init(
        engine: any TranslationEngine,
        cache: TranslationCache = .shared,
        maxConcurrency: Int = 4,
        maxRetries: Int = 3,
        baseRetryDelaySeconds: Double = 0.5
    ) {
        self.engine = engine
        self.cache = cache
        self.maxConcurrency = max(1, maxConcurrency)
        self.maxRetries = max(0, maxRetries)
        self.baseRetryDelaySeconds = max(0.05, baseRetryDelaySeconds)
    }

    /// Groups adjacent translation units into batches without exceeding `maxBatchCharacters`.
    public static func makeBatches(
        units: [TranslationUnit],
        maxBatchCharacters: Int
    ) -> [[TranslationUnit]] {
        guard !units.isEmpty else { return [] }
        let limit = max(1, maxBatchCharacters)
        var batches: [[TranslationUnit]] = []
        var currentBatch: [TranslationUnit] = []
        var currentChars = 0

        for unit in units {
            let unitLen = unit.text.count
            if !currentBatch.isEmpty && (currentChars + unitLen > limit) {
                batches.append(currentBatch)
                currentBatch = [unit]
                currentChars = unitLen
            } else {
                currentBatch.append(unit)
                currentChars += unitLen
            }
        }
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        return batches
    }

    public func translateAll(
        _ units: [TranslationUnit],
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry] = [],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [TranslationResult] {
        if units.isEmpty { return [] }

        var resultsByID: [UUID: TranslationResult] = [:]
        var uncachedUnits: [TranslationUnit] = []

        // 1. Check SQLite cache first
        for unit in units {
            try Task.checkCancellation()
            let key = TranslationCache.makeKey(
                engineID: engine.id,
                model: engine.modelName,
                sourceLanguage: source,
                targetLanguage: target,
                sourceText: unit.text
            )
            if let cachedText = await cache.get(forKey: key),
               PlaceholderValidator.validate(source: unit.text, translated: cachedText) {
                resultsByID[unit.id] = TranslationResult(
                    id: unit.id,
                    text: cachedText,
                    fellBackToSource: false,
                    fromCache: true
                )
            } else {
                uncachedUnits.append(unit)
            }
        }

        let totalUnits = units.count
        var completedUnits = resultsByID.count
        onProgress?(completedUnits, totalUnits)

        if uncachedUnits.isEmpty {
            return units.compactMap { resultsByID[$0.id] }
        }

        // 2. Group uncached units into context-preserving batches
        let batches = Self.makeBatches(units: uncachedUnits, maxBatchCharacters: engine.maxBatchCharacters)

        // 3. Execute batches with bounded concurrency via ThrowingTaskGroup
        try await withThrowingTaskGroup(of: [TranslationResult].self) { group in
            var nextBatchIndex = 0
            let initialCount = min(maxConcurrency, batches.count)

            for _ in 0..<initialCount {
                let batch = batches[nextBatchIndex]
                nextBatchIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    return try await self.translateBatchWithRetryAndValidation(
                        batch,
                        from: source,
                        to: target,
                        glossary: glossary
                    )
                }
            }

            while let batchResults = try await group.next() {
                for res in batchResults {
                    resultsByID[res.id] = res
                }
                completedUnits += batchResults.count
                onProgress?(completedUnits, totalUnits)

                if nextBatchIndex < batches.count {
                    let batch = batches[nextBatchIndex]
                    nextBatchIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return try await self.translateBatchWithRetryAndValidation(
                            batch,
                            from: source,
                            to: target,
                            glossary: glossary
                        )
                    }
                }
            }
        }

        return units.map { unit in
            resultsByID[unit.id] ?? TranslationResult(id: unit.id, text: unit.text, fellBackToSource: true)
        }
    }

    private func translateBatchWithRetryAndValidation(
        _ batch: [TranslationUnit],
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry]
    ) async throws -> [TranslationResult] {
        let rawResults = try await executeWithExponentialBackoff {
            try await engine.translate(batch, from: source, to: target, glossary: glossary)
        }

        var validatedResults: [TranslationResult] = []
        let unitMap = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })

        for raw in rawResults {
            try Task.checkCancellation()
            guard let sourceUnit = unitMap[raw.id] else {
                validatedResults.append(raw)
                continue
            }

            if PlaceholderValidator.validate(source: sourceUnit.text, translated: raw.text) {
                let key = TranslationCache.makeKey(
                    engineID: engine.id,
                    model: engine.modelName,
                    sourceLanguage: source,
                    targetLanguage: target,
                    sourceText: sourceUnit.text
                )
                await cache.set(raw.text, forKey: key)
                validatedResults.append(raw)
            } else {
                // Single-paragraph retry once when placeholders mismatch
                let retrySingle = try? await executeWithExponentialBackoff {
                    try await engine.translate([sourceUnit], from: source, to: target, glossary: glossary)
                }.first

                if let retrySingle,
                   PlaceholderValidator.validate(source: sourceUnit.text, translated: retrySingle.text) {
                    let key = TranslationCache.makeKey(
                        engineID: engine.id,
                        model: engine.modelName,
                        sourceLanguage: source,
                        targetLanguage: target,
                        sourceText: sourceUnit.text
                    )
                    await cache.set(retrySingle.text, forKey: key)
                    validatedResults.append(retrySingle)
                } else {
                    // Preserve original source text and mark fallback
                    validatedResults.append(
                        TranslationResult(
                            id: sourceUnit.id,
                            text: sourceUnit.text,
                            fellBackToSource: true,
                            fromCache: false
                        )
                    )
                }
            }
        }
        return validatedResults
    }

    private func executeWithExponentialBackoff<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as TranslationEngineError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                let multiplier = pow(2.0, Double(attempt - 1))
                let delaySeconds: Double
                if case .rateLimited(let retryAfter) = error, let retryAfter, retryAfter > 0 {
                    delaySeconds = min(retryAfter, 10.0)
                } else {
                    delaySeconds = baseRetryDelaySeconds * multiplier
                }
                let nanos = UInt64(delaySeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
            }
        }
    }
}
