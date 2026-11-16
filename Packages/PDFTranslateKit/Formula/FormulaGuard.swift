import Foundation
import CoreGraphics

public struct FormulaGuard: Sendable {
    public static let defaultMathFontPatterns: [String] = [
        "CMMI",
        "CMSY",
        "CMEX",
        "MSBM",
        "MSAM",
        "Symbol",
        "Math",
        "MTMI",
        "MTSYN",
        "MTEX",
        "Euclid",
        "CambriaMath",
        "STIX",
        "txmia",
        "txsys",
        "txex",
        "LibertineMath"
    ]

    public var mathFontRegexPatterns: [String]
    private let compiledRegexes: [NSRegularExpression]

    public init(customFontPatterns: [String] = []) {
        let combined = Self.defaultMathFontPatterns + customFontPatterns.filter { !$0.isEmpty }
        self.mathFontRegexPatterns = combined
        self.compiledRegexes = combined.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    public func protectFormulas(document: inout DocumentIR) {
        for pageIdx in 0..<document.pages.count {
            if document.pages[pageIdx].isScannedPage { continue }
            protectPageFormulas(page: &document.pages[pageIdx])
        }
    }

    public func protectPageFormulas(page: inout PageIR) {
        let formulaRegions = page.regions.filter { $0.kind == .formula }

        // Mark page-level chars first
        let pageMedianFontSize: CGFloat = {
            let sizes = page.chars.map(\.fontSize).sorted()
            return sizes.isEmpty ? 10.5 : sizes[sizes.count / 2]
        }()

        for i in 0..<page.chars.count {
            let ch = page.chars[i]
            let inFormulaRegion = formulaRegions.contains { $0.box.insetBy(dx: -1.5, dy: -1.5).contains(CGPoint(x: ch.box.midX, y: ch.box.midY)) }
            if inFormulaRegion || isFormulaChar(ch, lineMedianFontSize: pageMedianFontSize, lineBaselineY: nil) {
                page.chars[i].isFormula = true
            }
        }

        // Process each paragraph to build segments and `{v1}`, `{v2}` placeholders
        for pIdx in 0..<page.paragraphs.count {
            protectParagraph(&page.paragraphs[pIdx], formulaRegions: formulaRegions)
        }
    }

    public func protectParagraph(
        _ paragraph: inout ParagraphIR,
        formulaRegions: [LayoutRegion] = []
    ) {
        guard !paragraph.rawChars.isEmpty else { return }

        let domSize = paragraph.dominantFontSize
        var chars = paragraph.rawChars

        // Estimate baseline Y per line for subscript/superscript detection
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            // Find local neighbor median baseline Y on the same horizontal line
            let neighborMinYs = chars[max(0, i - 6)..<min(chars.count, i + 7)].filter {
                !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                abs($0.box.midY - ch.box.midY) < domSize * 0.70 &&
                abs($0.fontSize - domSize) <= 1.2
            }.map(\.box.minY).sorted()
            let localBaselineY = neighborMinYs.isEmpty ? nil : neighborMinYs[neighborMinYs.count / 2]

            let inFormulaBox = formulaRegions.contains {
                $0.box.insetBy(dx: -1.5, dy: -1.5).contains(CGPoint(x: ch.box.midX, y: ch.box.midY))
            }

            // Only treat small offset characters in a paragraph as subscript/superscript if attached to a 1-letter variable or math symbol
            let prevIsSingleVarOrMath: Bool = {
                guard i > 0 else { return false }
                let prev = chars[i - 1]
                if prev.isFormula { return true }
                let prevIsLetter = prev.unicode.count == 1 && prev.unicode.unicodeScalars.first.map({ CharacterSet.letters.contains($0) }) == true
                let beforePrevIsSpace = (i == 1) || chars[i - 2].unicode == " "
                return prevIsLetter && beforePrevIsSpace
            }()

            if inFormulaBox || isFormulaChar(
                ch,
                lineMedianFontSize: domSize,
                lineBaselineY: prevIsSingleVarOrMath ? localBaselineY : nil
            ) {
                chars[i].isFormula = true
            }
        }

        // Propagate formula flag across single spaces or base variables attached to subscripts/operators on the SAME line
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                // Base variable immediately followed by a subscript/superscript on the same line (e.g. x_i)
                if !chars[i].isFormula && chars[i + 1].isFormula,
                   abs(chars[i].box.midY - chars[i + 1].box.midY) <= domSize * 0.8 {
                    let isSingleVar = chars[i].unicode.count == 1 &&
                        chars[i].unicode.unicodeScalars.first.map({ CharacterSet.letters.contains($0) }) == true &&
                        (i == 0 || chars[i - 1].unicode == " ")
                    if isSingleVar {
                        chars[i].isFormula = true
                    }
                }
            }
            // Bridge binary operators, subscripts/digits, and math delimiters (=, +, -, <, >, ,, ., {, }, (, ), |)
            // when bounded on both sides by formula characters on the same line
            let bridgeableChars = CharacterSet(charactersIn: " =+-<>.,{}()[]|/*:0123456789")
            var idx = 0
            while idx < chars.count {
                if !chars[idx].isFormula {
                    var runEnd = idx
                    while runEnd < chars.count && !chars[runEnd].isFormula {
                        runEnd += 1
                    }
                    if idx > 0 && runEnd < chars.count && (runEnd - idx) <= 6 &&
                       chars[idx - 1].isFormula && chars[runEnd].isFormula,
                       abs(chars[idx - 1].box.midY - chars[runEnd].box.midY) <= domSize * 0.90 {
                        let betweenStr = chars[idx..<runEnd].map(\.unicode).joined()
                        if betweenStr.unicodeScalars.allSatisfy({ bridgeableChars.contains($0) }) {
                            for k in idx..<runEnd {
                                chars[k].isFormula = true
                            }
                        }
                    }
                    idx = runEnd
                } else {
                    idx += 1
                }
            }
        }

        paragraph.rawChars = chars

        // Group contiguous formula / text runs into `Segment`s and build `sourceText` with `{v1}`, `{v2}`
        var segments: [Segment] = []
        var sourceBuilder = ""
        var formulaCounter = 0

        var idx = 0
        while idx < chars.count {
            if chars[idx].isFormula {
                var formulaRun: [CharIR] = []
                while idx < chars.count && chars[idx].isFormula {
                    formulaRun.append(chars[idx])
                    idx += 1
                }
                // Trim leading/trailing synthetic spaces from the formula run and return them to text
                var leadingSpaces = ""
                while let first = formulaRun.first, first.unicode == " " {
                    leadingSpaces.append(" ")
                    formulaRun.removeFirst()
                }
                var trailingSpaces = ""
                while let last = formulaRun.last, last.unicode == " " {
                    trailingSpaces.append(" ")
                    formulaRun.removeLast()
                }

                if !leadingSpaces.isEmpty {
                    appendTextSegment(&segments, text: leadingSpaces, paragraph: paragraph)
                    sourceBuilder += leadingSpaces
                }

                if !formulaRun.isEmpty {
                    formulaCounter += 1
                    let placeholder = "{v\(formulaCounter)}"
                    var unionBox = formulaRun[0].box
                    for fc in formulaRun.dropFirst() {
                        unionBox = unionBox.union(fc.box)
                    }
                    segments.append(.formula(placeholder: placeholder, chars: formulaRun, box: unionBox))
                    sourceBuilder += placeholder
                }

                if !trailingSpaces.isEmpty {
                    appendTextSegment(&segments, text: trailingSpaces, paragraph: paragraph)
                    sourceBuilder += trailingSpaces
                }
            } else {
                var textRun = ""
                while idx < chars.count && !chars[idx].isFormula {
                    textRun += chars[idx].unicode
                    idx += 1
                }
                if !textRun.isEmpty {
                    appendTextSegment(&segments, text: textRun, paragraph: paragraph)
                    sourceBuilder += textRun
                }
            }
        }

        paragraph.segments = segments
        paragraph.sourceText = sourceBuilder
    }

    private func appendTextSegment(_ segments: inout [Segment], text: String, paragraph: ParagraphIR) {
        let style = TextStyleRun(
            isBold: paragraph.kind == .title,
            isItalic: false,
            fontSize: paragraph.dominantFontSize,
            color: paragraph.dominantColor
        )
        if case .text(let prevText, let prevStyle) = segments.last, prevStyle == style {
            segments[segments.count - 1] = .text(prevText + text, style: prevStyle)
        } else {
            segments.append(.text(text, style: style))
        }
    }

    public func isFormulaChar(
        _ ch: CharIR,
        lineMedianFontSize: CGFloat,
        lineBaselineY: CGFloat?
    ) -> Bool {
        let trimmed = ch.unicode.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // 1. Font name matches math font regex table (excluding plain prose punctuation)
        let isProsePunct = ".,:;!?()[]\"'".contains(trimmed)
        if !isProsePunct {
            let nsFont = ch.fontName as NSString
            let range = NSRange(location: 0, length: nsFont.length)
            for regex in compiledRegexes {
                if regex.firstMatch(in: ch.fontName, range: range) != nil {
                    return true
                }
            }
        }

        // 2. Subscript / Superscript check: smaller font size AND baseline offset
        if lineMedianFontSize > 4.0,
           ch.fontSize <= lineMedianFontSize * 0.82,
           let base = lineBaselineY,
           abs(ch.box.minY - base) >= lineMedianFontSize * 0.12 {
            return true
        }

        // 3. Unicode math operator or Greek letter check
        if Self.isMathUnicode(ch.unicode) {
            return true
        }

        return false
    }

    public static func isMathCharacter(_ ch: CharIR, lineMedianFontSize: CGFloat) -> Bool {
        let guardInstance = FormulaGuard()
        return guardInstance.isFormulaChar(ch, lineMedianFontSize: lineMedianFontSize, lineBaselineY: nil)
    }

    public static func isMathUnicode(_ str: String) -> Bool {
        for scalar in str.unicodeScalars {
            let v = scalar.value
            // Greek and Coptic (U+0370..U+03FF)
            if (0x0370...0x03FF).contains(v) { return true }
            // Superscripts and Subscripts (U+2070..U+209F)
            if (0x2070...0x209F).contains(v) { return true }
            // Letterlike Symbols (U+2100..U+214F) e.g. ℝ, ℕ, ℓ, ℏ
            if (0x2100...0x214F).contains(v) { return true }
            // Arrows (U+2190..U+21FF)
            if (0x2190...0x21FF).contains(v) { return true }
            // Mathematical Operators (U+2200..U+22FF) e.g. ∀, ∂, ∃, ∈, ∑, ∫, ≈, ≠, ≤, ≥
            if (0x2200...0x22FF).contains(v) { return true }
            // Miscellaneous Technical / Ceilings / Floors (U+2308..U+230B)
            if (0x2308...0x230B).contains(v) { return true }
            // Miscellaneous Mathematical Symbols-A & B (U+27C0..U+27EF, U+2980..U+29FF)
            if (0x27C0...0x27EF).contains(v) || (0x2980...0x29FF).contains(v) { return true }
            // Supplemental Mathematical Operators (U+2A00..U+2AFF)
            if (0x2A00...0x2AFF).contains(v) { return true }
            // Mathematical Alphanumeric Symbols (U+1D400..U+1D7FF)
            if (0x1D400...0x1D7FF).contains(v) { return true }
        }
        return false
    }
}
