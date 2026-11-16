import Foundation
import CoreGraphics

public struct ParagraphBuilder: Sendable {
    public init() {}

    public func buildParagraphs(document: inout DocumentIR) {
        for i in 0..<document.pages.count {
            if document.pages[i].isScannedPage { continue }
            document.pages[i].paragraphs = buildPageParagraphs(page: document.pages[i])
        }
    }

    public func buildPageParagraphs(page: PageIR) -> [ParagraphIR] {
        let translatableRegions = page.regions.filter { $0.kind.isTranslatable }
        guard !translatableRegions.isEmpty else { return [] }

        // Sort translatable regions in column reading order:
        // Spanning top regions first, then left column top-to-bottom, then right column top-to-bottom.
        let orderedRegions = Self.sortRegionsInReadingOrder(translatableRegions, pageMediaBox: page.mediaBox)

        var allParagraphs: [ParagraphIR] = []
        var usedCharIndices = Set<Int>()

        for region in orderedRegions {
            let expandedRegionBox = region.box.insetBy(dx: -1.5, dy: -1.5)
            var regionChars: [CharIR] = []
            for (idx, ch) in page.chars.enumerated() where !usedCharIndices.contains(idx) {
                let center = CGPoint(x: ch.box.midX, y: ch.box.midY)
                if expandedRegionBox.contains(center) {
                    usedCharIndices.insert(idx)
                    regionChars.append(ch)
                }
            }

            guard !regionChars.isEmpty else { continue }
            let paragraphsInRegion = assembleParagraphsInRegion(
                chars: regionChars,
                region: region,
                pageMediaBox: page.mediaBox,
                allRegions: page.regions
            )
            allParagraphs.append(contentsOf: paragraphsInRegion)
        }

        return allParagraphs
    }

    /// Sorts regions by column reading order: first by column bucket (spanning header/title, left column, right column),
    /// then top-to-bottom within each column.
    public static func sortRegionsInReadingOrder(
        _ regions: [LayoutRegion],
        pageMediaBox: CGRect
    ) -> [LayoutRegion] {
        let midX = pageMediaBox.midX
        let colThreshold = pageMediaBox.width * 0.08

        func columnBucket(_ r: LayoutRegion) -> Int {
            // Full-width spanning title/abstract at top of page comes first
            if r.box.minX < midX - colThreshold && r.box.maxX > midX + colThreshold {
                return r.box.midY > pageMediaBox.midY ? 0 : 3
            }
            if r.box.midX <= midX {
                return 1 // Left column
            } else {
                return 2 // Right column
            }
        }

        return regions.sorted { a, b in
            let colA = columnBucket(a)
            let colB = columnBucket(b)
            if colA != colB {
                return colA < colB
            }
            // Within same column, sort top-to-bottom (higher maxY first in PDF coordinates)
            if abs(a.box.maxY - b.box.maxY) > 4.0 {
                return a.box.maxY > b.box.maxY
            }
            return a.box.minX < b.box.minX
        }
    }

    private func assembleParagraphsInRegion(
        chars: [CharIR],
        region: LayoutRegion,
        pageMediaBox: CGRect,
        allRegions: [LayoutRegion]
    ) -> [ParagraphIR] {
        let visibleChars = chars.filter { $0.unicode != "\n" && $0.unicode != "\r" && $0.unicode != "\t" }
        guard visibleChars.contains(where: { !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return [] }

        // 1. Cluster characters into lines by baseline Y
        let lines = clusterIntoLines(chars: visibleChars)
        guard !lines.isEmpty else { return [] }

        // 2. Group lines into paragraphs based on vertical spacing and first-line indentation
        var lineGroups: [[LineItem]] = []
        var currentGroup: [LineItem] = [lines[0]]
        let regionLeftMargin = lines.map(\.box.minX).min() ?? region.box.minX

        for line in lines.dropFirst() {
            let prev = currentGroup.last!
            let verticalGap = prev.box.minY - line.box.maxY
            let avgFont = (prev.avgFontSize + line.avgFontSize) * 0.5
            let isLargeVerticalGap = verticalGap > avgFont * 0.85

            // First-line indent detection: current line is indented relative to region left margin
            // AND previous line ended significantly before the right margin or with sentence-ending punctuation
            let lineIndent = line.box.minX - regionLeftMargin
            let prevLineShort = (region.box.maxX - prev.box.maxX) > avgFont * 2.5
            let prevTrimmed = prev.rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            let prevEndsSentence = prevTrimmed.hasSuffix(".") || prevTrimmed.hasSuffix("。") || prevTrimmed.hasSuffix(":") || prevTrimmed.hasSuffix("?")
            let isIndentedNewParagraph = (lineIndent > avgFont * 1.1) && (prevEndsSentence || prevLineShort) && currentGroup.count >= 1

            if isLargeVerticalGap || (isIndentedNewParagraph && region.kind == .text) {
                lineGroups.append(currentGroup)
                currentGroup = [line]
            } else {
                currentGroup.append(line)
            }
        }
        if !currentGroup.isEmpty {
            lineGroups.append(currentGroup)
        }

        // 3. Convert each line group into a `ParagraphIR`, de-hyphenating line breaks
        return lineGroups.compactMap { group in
            buildParagraphIR(
                from: group,
                regionKind: region.kind,
                regionLeftMargin: regionLeftMargin,
                allRegions: allRegions
            )
        }
    }

    struct LineItem {
        var chars: [CharIR]
        var box: CGRect
        var baselineY: CGFloat
        var avgFontSize: CGFloat

        var rawString: String {
            chars.map(\.unicode).joined()
        }
    }

    private func clusterIntoLines(chars: [CharIR]) -> [LineItem] {
        // Group by vertical midpoint first so subscripts, superscripts, and descenders stay on the same line
        let sortedByMidY = chars.sorted { $0.box.midY > $1.box.midY }
        var lines: [LineItem] = []

        for ch in sortedByMidY {
            let tol = max(3.5, ch.fontSize * 0.52)
            if let idx = lines.lastIndex(where: { abs($0.box.midY - ch.box.midY) <= max(tol, $0.avgFontSize * 0.52) }) {
                lines[idx].chars.append(ch)
                lines[idx].box = lines[idx].box.union(ch.box)
                if ch.fontSize > lines[idx].avgFontSize {
                    lines[idx].avgFontSize = ch.fontSize
                }
            } else {
                lines.append(
                    LineItem(
                        chars: [ch],
                        box: ch.box,
                        baselineY: ch.box.minY,
                        avgFontSize: ch.fontSize
                    )
                )
            }
        }

        for i in 0..<lines.count {
            lines[i].chars.sort { $0.box.minX < $1.box.minX }
            let sizes = lines[i].chars.map(\.fontSize).sorted()
            lines[i].avgFontSize = sizes[sizes.count / 2]
            lines[i].baselineY = lines[i].chars.map(\.box.minY).sorted()[sizes.count / 2]
        }
        return lines.sorted { $0.box.maxY > $1.box.maxY }
    }

    private func buildParagraphIR(
        from lines: [LineItem],
        regionKind: LayoutRegion.Kind,
        regionLeftMargin: CGFloat,
        allRegions: [LayoutRegion] = []
    ) -> ParagraphIR? {
        guard !lines.isEmpty else { return nil }

        var paragraphBox = lines[0].box
        for line in lines.dropFirst() {
            paragraphBox = paragraphBox.union(line.box)
        }

        // Reconstruct character stream with word spaces and de-hyphenation (`trans-` + `lation` -> `translation`)
        var mergedChars: [CharIR] = []
        for (lineIdx, line) in lines.enumerated() {
            var lineChars = insertIntraLineSpaces(line.chars)
            let isLastLine = (lineIdx == lines.count - 1)

            // Check end-of-line hyphenation: last char is `-` or `‐` or soft hyphen, preceded by an ASCII letter,
            // and next line's first non-space char is a lowercase ASCII letter.
            let nextFirstNonSpace = isLastLine ? nil : lines[lineIdx + 1].chars.first(where: { $0.unicode != " " })
            if !isLastLine,
               lineChars.count >= 2,
               let lastChar = lineChars.last,
               (lastChar.unicode == "-" || lastChar.unicode == "\u{2010}" || lastChar.unicode == "\u{00AD}"),
               let prevNonSpace = lineChars.dropLast().last(where: { $0.unicode != " " }),
               prevNonSpace.unicode.unicodeScalars.first.map({ CharacterSet.letters.contains($0) }) == true,
               let nextFirst = nextFirstNonSpace,
               nextFirst.unicode.unicodeScalars.first.map({ CharacterSet.lowercaseLetters.contains($0) }) == true {
                // Drop the trailing hyphen (and any synthetic space right before it) and merge directly with next line
                lineChars.removeLast()
                while lineChars.last?.unicode == " " {
                    lineChars.removeLast()
                }
                mergedChars.append(contentsOf: lineChars)
            } else {
                mergedChars.append(contentsOf: lineChars)
                if !isLastLine {
                    let lastCh = lineChars.last!
                    let spaceChar = CharIR(
                        unicode: " ",
                        box: CGRect(x: lastCh.box.maxX, y: lastCh.box.minY, width: lastCh.fontSize * 0.25, height: lastCh.box.height),
                        fontName: lastCh.fontName,
                        fontSize: lastCh.fontSize,
                        color: lastCh.color,
                        objectID: lastCh.objectID
                    )
                    mergedChars.append(spaceChar)
                }
            }
        }

        let fontSizes = mergedChars.map(\.fontSize).sorted()
        let dominantFontSize = fontSizes.isEmpty ? 10.5 : fontSizes[fontSizes.count / 2]
        let dominantColor = mergedChars.first?.color ?? .black
        let firstLineIndent = max(0, lines[0].box.minX - regionLeftMargin)

        let alignment: TextAlignmentMode
        if regionKind == .title {
            let leftDiff = abs(lines[0].box.minX - paragraphBox.minX)
            let rightDiff = abs(paragraphBox.maxX - lines[0].box.maxX)
            alignment = (abs(leftDiff - rightDiff) < dominantFontSize * 1.5 && leftDiff > 4) ? .center : .left
        } else if lines.count == 1 && (regionKind == .caption || paragraphBox.width < dominantFontSize * 26.0) {
            let leftDiff = abs(lines[0].box.minX - regionLeftMargin)
            alignment = (leftDiff > dominantFontSize * 2.0) ? .center : .left
        } else {
            alignment = .justified
        }

        let objectIDs = Array(Set(mergedChars.map(\.objectID).filter { $0 >= 0 })).sorted()
        let plainSource = mergedChars.map(\.unicode).joined()

        // Detect whether this paragraph physically overlaps a non-translatable region (figure / table / formula / image).
        // Text placed inside those regions (axis labels, in-figure callouts) must be preserved verbatim — translating
        // and re-typesetting them produces garbled overlap against the untouched vector/bitmap art underneath.
        let overlapsNonTranslatable: Bool = allRegions.contains { r in
            guard !r.kind.isTranslatable else { return false }
            let inter = paragraphBox.intersection(r.box)
            if inter.isNull || inter.isEmpty { return false }
            // Any meaningful overlap (>4pt wide, >2pt tall) marks the paragraph as risky
            return inter.width > 4.0 && inter.height > 2.0
        }

        return ParagraphIR(
            box: paragraphBox,
            kind: regionKind,
            alignment: alignment,
            firstLineIndent: firstLineIndent,
            dominantFontSize: dominantFontSize,
            dominantColor: dominantColor,
            rawChars: mergedChars,
            segments: [.text(plainSource, style: TextStyleRun(fontSize: dominantFontSize, color: dominantColor))],
            sourceText: plainSource,
            overlapsNonTranslatableRegion: overlapsNonTranslatable,
            objectIDs: objectIDs
        )
    }

    private func insertIntraLineSpaces(_ chars: [CharIR]) -> [CharIR] {
        let trimmedEdge = chars.drop(while: { $0.unicode == " " })
        guard let firstChar = trimmedEdge.first else { return [] }
        var result: [CharIR] = [firstChar]
        for ch in trimmedEdge.dropFirst() {
            let prev = result.last!
            if ch.unicode == " " && prev.unicode == " " {
                continue
            }
            let gap = ch.box.minX - prev.box.maxX
            let spaceThreshold = max(0.95, min(prev.fontSize, ch.fontSize) * 0.13)
            let isHyphenAttachment = (ch.unicode == "-" || ch.unicode == "\u{2010}" || prev.unicode == "-" || prev.unicode == "\u{2010}") && gap < min(prev.fontSize, ch.fontSize) * 0.45
            if gap > spaceThreshold && !isHyphenAttachment && prev.unicode != " " && ch.unicode != " " {
                let syntheticSpace = CharIR(
                    unicode: " ",
                    box: CGRect(x: prev.box.maxX, y: prev.box.minY, width: gap, height: prev.box.height),
                    fontName: prev.fontName,
                    fontSize: prev.fontSize,
                    color: prev.color,
                    objectID: prev.objectID,
                    isFormula: prev.isFormula && ch.isFormula
                )
                result.append(syntheticSpace)
            }
            result.append(ch)
        }
        while result.last?.unicode == " " {
            result.removeLast()
        }
        return result
    }

    /// Utility for testing hyphenated word merging directly on strings.
    public static func mergeHyphenatedLineBreak(_ firstLine: String, _ secondLine: String) -> String {
        let trimmedFirst = firstLine.trimmingCharacters(in: .whitespaces)
        let trimmedSecond = secondLine.trimmingCharacters(in: .whitespaces)
        if (trimmedFirst.hasSuffix("-") || trimmedFirst.hasSuffix("\u{2010}")),
           trimmedFirst.count >= 2,
           let firstCharOfSecond = trimmedSecond.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(firstCharOfSecond) {
            return String(trimmedFirst.dropLast()) + trimmedSecond
        }
        return trimmedFirst + " " + trimmedSecond
    }
}
