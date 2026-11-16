import Foundation

public enum PlaceholderValidator {
    /// Extracts all `{vN}` placeholders from the given text.
    public static func extractPlaceholders(from text: String) -> [String] {
        let pattern = #"\{v\d+\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    /// Validates that the translated text contains the exact same set and count of `{vN}` placeholders.
    public static func validate(source: String, translated: String) -> Bool {
        let sourceList = extractPlaceholders(from: source).sorted()
        let translatedList = extractPlaceholders(from: translated).sorted()
        return sourceList == translatedList
    }

    public enum Piece: Sendable, Equatable {
        case text(String)
        case placeholder(String)
    }

    /// Splits a string containing `{vN}` placeholders into alternating text and placeholder pieces.
    public static func splitByPlaceholders(_ input: String) -> [Piece] {
        let pattern = #"\{v\d+\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input.isEmpty ? [] : [.text(input)]
        }
        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = regex.matches(in: input, range: nsRange)
        if matches.isEmpty {
            return input.isEmpty ? [] : [.text(input)]
        }

        var pieces: [Piece] = []
        var currentIndex = input.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: input) else { continue }
            if currentIndex < matchRange.lowerBound {
                let prefix = String(input[currentIndex..<matchRange.lowerBound])
                if !prefix.isEmpty {
                    pieces.append(.text(prefix))
                }
            }
            pieces.append(.placeholder(String(input[matchRange])))
            currentIndex = matchRange.upperBound
        }
        if currentIndex < input.endIndex {
            let suffix = String(input[currentIndex..<input.endIndex])
            if !suffix.isEmpty {
                pieces.append(.text(suffix))
            }
        }
        return pieces
    }
}
