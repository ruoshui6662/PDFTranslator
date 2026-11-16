import Foundation

public struct OpenAICompatibleConfiguration: Sendable, Codable, Equatable {
    public var providerID: String
    public var displayName: String
    public var baseURLString: String
    public var modelName: String
    public var requiresAPIKey: Bool
    public var timeoutSeconds: TimeInterval
    public var maxBatchCharacters: Int

    public init(
        providerID: String = "openai",
        displayName: String = "OpenAI 兼容接口",
        baseURLString: String = "https://api.openai.com/v1",
        modelName: String = "gpt-4o-mini",
        requiresAPIKey: Bool = true,
        timeoutSeconds: TimeInterval = 60,
        maxBatchCharacters: Int = 2400
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.baseURLString = baseURLString
        self.modelName = modelName
        self.requiresAPIKey = requiresAPIKey
        self.timeoutSeconds = timeoutSeconds
        self.maxBatchCharacters = maxBatchCharacters
    }

    public static let presets: [OpenAICompatibleConfiguration] = [
        OpenAICompatibleConfiguration(
            providerID: "deepseek",
            displayName: "DeepSeek",
            baseURLString: "https://api.deepseek.com/v1",
            modelName: "deepseek-v4.1-flash",
            requiresAPIKey: true
        ),
        OpenAICompatibleConfiguration(
            providerID: "siliconflow",
            displayName: "硅基流动 (SiliconFlow)",
            baseURLString: "https://api.siliconflow.cn/v1",
            modelName: "deepseek-ai/DeepSeek-V4.1-Flash",
            requiresAPIKey: true
        ),
        OpenAICompatibleConfiguration(
            providerID: "openai",
            displayName: "OpenAI",
            baseURLString: "https://api.openai.com/v1",
            modelName: "gpt-4.1-mini",
            requiresAPIKey: true
        ),
        OpenAICompatibleConfiguration(
            providerID: "ollama",
            displayName: "Ollama 本地模型",
            baseURLString: "http://localhost:11434/v1",
            modelName: "qwen2.5:7b",
            requiresAPIKey: false
        )
    ]
}

public struct OpenAICompatibleEngine: TranslationEngine, Sendable {
    public let configuration: OpenAICompatibleConfiguration
    private let apiKeyProvider: @Sendable () -> String?

    public var id: String { "openai:\(configuration.providerID)" }
    public var modelName: String { configuration.modelName }
    public var maxBatchCharacters: Int { configuration.maxBatchCharacters }

    public init(
        configuration: OpenAICompatibleConfiguration,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
    }

    public init(configuration: OpenAICompatibleConfiguration, apiKey: String?) {
        self.configuration = configuration
        self.apiKeyProvider = { apiKey }
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct WireUnit: Codable {
        let id: String
        let text: String
    }

    public func translate(
        _ batch: [TranslationUnit],
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry]
    ) async throws -> [TranslationResult] {
        if batch.isEmpty { return [] }

        let endpoint = try buildEndpointURL()
        let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuration.requiresAPIKey && key.isEmpty {
            throw TranslationEngineError.unauthorized
        }

        let wireInput = batch.map { WireUnit(id: $0.id.uuidString, text: $0.text) }
        let inputData = try JSONEncoder().encode(wireInput)
        let inputJSONString = String(data: inputData, encoding: .utf8) ?? "[]"

        let sysPrompt = TranslationPromptBuilder.systemPrompt(from: source, to: target, glossary: glossary)
        let payload = ChatRequest(
            model: configuration.modelName,
            messages: [
                .init(role: "system", content: sysPrompt),
                .init(role: "user", content: inputJSONString)
            ],
            temperature: 0.1
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            throw TranslationEngineError.networkTimeout
        } catch {
            throw TranslationEngineError.networkFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslationEngineError.networkFailure("非 HTTP 响应")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw TranslationEngineError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw TranslationEngineError.rateLimited(retryAfterSeconds: retryAfter)
        case 500...599:
            let msg = String(data: data, encoding: .utf8) ?? "Server Error"
            throw TranslationEngineError.serverError(statusCode: http.statusCode, message: msg)
        default:
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TranslationEngineError.invalidConfiguration("HTTP \(http.statusCode): \(msg.prefix(120))")
        }

        let chatResp: ChatResponse
        do {
            chatResp = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw TranslationEngineError.invalidResponseFormat("无法解析 chat/completions 响应结构")
        }

        guard let content = chatResp.choices.first?.message.content else {
            throw TranslationEngineError.invalidResponseFormat("choices 为空")
        }

        let cleanedJSON = Self.extractJSONArray(from: content)
        guard let jsonData = cleanedJSON.data(using: .utf8),
              let wireOutputs = try? JSONDecoder().decode([WireUnit].self, from: jsonData) else {
            // Fallback for single-unit batch if the model returned plain text instead of JSON
            if batch.count == 1 {
                return [TranslationResult(id: batch[0].id, text: content.trimmingCharacters(in: .whitespacesAndNewlines))]
            }
            throw TranslationEngineError.invalidResponseFormat("模型输出不是合法的 JSON 数组")
        }

        var map: [String: String] = [:]
        for item in wireOutputs {
            map[item.id.lowercased()] = item.text
        }

        return batch.enumerated().map { idx, unit in
            if let matched = map[unit.id.uuidString.lowercased()] {
                return TranslationResult(id: unit.id, text: matched)
            } else if idx < wireOutputs.count {
                return TranslationResult(id: unit.id, text: wireOutputs[idx].text)
            } else {
                return TranslationResult(id: unit.id, text: unit.text, fellBackToSource: true)
            }
        }
    }

    public func testConnection() async throws -> String {
        let probe = TranslationUnit(text: "Hello {v1} world.")
        let results = try await translate(
            [probe],
            from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: "zh-Hans"),
            glossary: []
        )
        return results.first?.text ?? ""
    }

    private func buildEndpointURL() throws -> URL {
        let trimmed = configuration.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var url = URL(string: trimmed) else {
            throw TranslationEngineError.invalidConfiguration("Base URL 格式不正确")
        }
        if !url.path.hasSuffix("/chat/completions") {
            if !url.path.hasSuffix("/v1") && !url.path.contains("/v1/") {
                url.appendPathComponent("v1")
            }
            url.appendPathComponent("chat/completions")
        }
        return url
    }

    static func extractJSONArray(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "["),
           let end = trimmed.lastIndex(of: "]"),
           start <= end {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}
