import Foundation

public struct TranslationUnit: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

public struct TranslationResult: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public var fellBackToSource: Bool
    public var fromCache: Bool

    public init(id: UUID, text: String, fellBackToSource: Bool = false, fromCache: Bool = false) {
        self.id = id
        self.text = text
        self.fellBackToSource = fellBackToSource
        self.fromCache = fromCache
    }
}

public struct GlossaryEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var sourceTerm: String
    public var targetTerm: String

    public init(id: UUID = UUID(), sourceTerm: String, targetTerm: String) {
        self.id = id
        self.sourceTerm = sourceTerm
        self.targetTerm = targetTerm
    }

    public static func parseCSV(_ csvContent: String) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        for rawLine in csvContent.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                if parts[0].lowercased() == "source" && parts[1].lowercased() == "target" {
                    continue
                }
                entries.append(GlossaryEntry(sourceTerm: parts[0], targetTerm: parts[1]))
            }
        }
        return entries
    }
}

public protocol TranslationEngine: Sendable {
    var id: String { get }
    var modelName: String { get }
    var maxBatchCharacters: Int { get }
    func translate(
        _ batch: [TranslationUnit],
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry]
    ) async throws -> [TranslationResult]
}

public enum TranslationEngineError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case unauthorized
    case rateLimited(retryAfterSeconds: Double?)
    case serverError(statusCode: Int, message: String)
    case networkTimeout
    case networkFailure(String)
    case invalidResponseFormat(String)
    case placeholderMismatch(expected: Set<String>, actual: Set<String>)
    case systemTranslationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "翻译服务配置无效：\(detail)，请在设置中检查 Base URL 与模型名称。"
        case .unauthorized:
            return "API Key 无效或未填写，请在设置（⌘,）中检查并重新输入。"
        case .rateLimited:
            return "翻译服务请求过于频繁（429），请稍后重试或在设置中调低并发数。"
        case .serverError(let code, _):
            return "翻译服务端暂时异常（HTTP \(code)），请稍后重试。"
        case .networkTimeout:
            return "连接翻译服务超时，请检查网络连接或服务地址是否可达。"
        case .networkFailure(let reason):
            return "网络连接失败：\(reason)，请检查网络设置。"
        case .invalidResponseFormat:
            return "翻译服务返回的数据格式无法解析，请确认所选模型支持 JSON 输出。"
        case .placeholderMismatch:
            return "译文中的公式占位符不一致，已尝试重译或保留原文。"
        case .systemTranslationUnavailable(let detail):
            return "Apple 系统翻译暂不可用：\(detail)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .networkTimeout:
            return true
        default:
            return false
        }
    }
}

public enum TranslationPromptBuilder {
    public static let promptVersion = "v3.6"

    public static func systemPrompt(
        from source: Locale.Language,
        to target: Locale.Language,
        glossary: [GlossaryEntry]
    ) -> String {
        let srcCode = source.minimalIdentifier
        let tgtCode = target.minimalIdentifier
        var rules = """
        你是一个专业的学术与技术文档翻译引擎（\(srcCode) -> \(tgtCode)）。必须严格遵守以下四条规则：
        1. 只输出译文，不加任何解释、前言或 Markdown 代码块包裹之外的说明；
        2. {v1}、{v2} 这类公式/样式占位符必须原样保留，数量和编号严格不变，仅可按目标语言自然语序移动位置；
        3. 按术语表翻译专有名词，人名、模型名、代码标识符、数学符号保持原文不译；
        4. 输入是 JSON 数组 [{"id": "...", "text": "..."}]，输出必须是完全相同结构的合法 JSON 数组 [{"id": "...", "text": "..."}]。
        """
        if !glossary.isEmpty {
            let terms = glossary.map { "- \($0.sourceTerm) => \($0.targetTerm)" }.joined(separator: "\n")
            rules += "\n\n术语表：\n\(terms)"
        }
        return rules
    }
}
