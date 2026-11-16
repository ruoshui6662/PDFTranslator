import Foundation
import CoreGraphics
import CoreText
import TranslationEngines

public struct TypesetterConfiguration: Sendable, Codable, Equatable {
    public var fontStyle: CJKFontStyle
    public var customFontPostScriptName: String?
    public var minFontScaleRatio: CGFloat
    public var initialLineHeightMultiple: CGFloat
    public var minLineHeightMultiple: CGFloat
    public var cjkLatinQuarterEmSpacing: Bool

    public init(
        fontStyle: CJKFontStyle = .autoMatch,
        customFontPostScriptName: String? = nil,
        minFontScaleRatio: CGFloat = 0.60,
        initialLineHeightMultiple: CGFloat = 1.50,
        minLineHeightMultiple: CGFloat = 1.40,
        cjkLatinQuarterEmSpacing: Bool = true
    ) {
        self.fontStyle = fontStyle
        self.customFontPostScriptName = customFontPostScriptName
        self.minFontScaleRatio = min(max(0.40, minFontScaleRatio), 1.0)
        self.initialLineHeightMultiple = initialLineHeightMultiple
        self.minLineHeightMultiple = minLineHeightMultiple
        self.cjkLatinQuarterEmSpacing = cjkLatinQuarterEmSpacing
    }
}

public struct Typesetter: Sendable {
    public var configuration: TypesetterConfiguration

    /// Punctuation forbidden at the start of a new line (中文行首禁则标点)
    public static let lineStartForbiddenPunctuation: Set<Character> = [
        "，", "。", "、", "；", "：", "？", "！", "）", "》", "」", "』", "】", "〉", "”", "’",
        ",", ".", ";", ":", "?", "!", ")", "]", "}"
    ]

    /// Punctuation forbidden at the end of a line (中文行尾禁则标点)
    public static let lineEndForbiddenPunctuation: Set<Character> = [
        "（", "《", "「", "『", "【", "〈", "“", "‘", "(", "[", "{"
    ]

    public init(configuration: TypesetterConfiguration = TypesetterConfiguration()) {
        self.configuration = configuration
    }

    public func typesetDocument(_ document: inout DocumentIR) {
        for pageIdx in 0..<document.pages.count {
            if document.pages[pageIdx].isScannedPage { continue }
            typesetPage(&document.pages[pageIdx])
        }
    }

    public func typesetPage(_ page: inout PageIR) {
        guard !page.paragraphs.isEmpty else { return }

        // First pass: find the required scale factor for each paragraph
        var computedLayouts: [TypesetResult] = []
        var bodyScaleFactors: [CGFloat] = []

        for idx in 0..<page.paragraphs.count {
            let para = page.paragraphs[idx]
            if para.overlapsNonTranslatableRegion {
                // Paragraph sits on top of a figure/table/image region — the source text objects were left
                // untouched by PDFium and no translated text exists, so skip typesetting entirely.
                computedLayouts.append(TypesetResult(
                    fontSize: para.dominantFontSize,
                    scaleFactor: 1.0,
                    lineHeightMultiple: 1.0,
                    expandedBox: para.box,
                    lines: []
                ))
                continue
            }
            let availableBottomY = findAvailableBottomY(forParagraphAt: idx, in: page)
            let result = typesetParagraph(para, availableBottomY: availableBottomY, forcedMaxScale: nil)
            computedLayouts.append(result)
            if para.kind == .text {
                bodyScaleFactors.append(result.scaleFactor)
            }
        }

        // Step 5: Unify body paragraph font scale on the same page toward the median multi-line body scale
        // so adjacent paragraphs have consistent sizing without a single tight block dragging the whole page down.
        if bodyScaleFactors.count >= 2 {
            let sortedScales = bodyScaleFactors.sorted()
            let medianBodyScale = sortedScales[sortedScales.count / 2]
            let unifiedTargetScale = min(1.0, max(0.82, medianBodyScale))
            for idx in 0..<page.paragraphs.count {
                if page.paragraphs[idx].kind == .text && computedLayouts[idx].scaleFactor > unifiedTargetScale + 0.08 {
                    let availableBottomY = findAvailableBottomY(forParagraphAt: idx, in: page)
                    computedLayouts[idx] = typesetParagraph(
                        page.paragraphs[idx],
                        availableBottomY: availableBottomY,
                        forcedMaxScale: unifiedTargetScale
                    )
                }
            }
        }

        for idx in 0..<page.paragraphs.count {
            page.paragraphs[idx].layout = computedLayouts[idx]
        }
    }

    /// Typesets a single paragraph, adjusting line height from 1.5 -> 1.4, then shrinking font size in 5% steps
    /// down to `minFontScaleRatio` (60%), and finally expanding the box downward into whitespace if needed.
    public func typesetParagraph(
        _ paragraph: ParagraphIR,
        availableBottomY: CGFloat? = nil,
        forcedMaxScale: CGFloat? = nil
    ) -> TypesetResult {
        let contentText = paragraph.translatedText ?? paragraph.sourceText
        let baseFontSize = max(6.0, paragraph.dominantFontSize)
        let tokens = tokenizeParagraph(text: contentText, segments: paragraph.segments, baseFontSize: baseFontSize)
        let isBold = SystemFontCatalog.isSourceParagraphBold(paragraph)
        let isSerif = SystemFontCatalog.isSourceParagraphSerif(paragraph)
        let resolvedFontName = configuration.fontStyle.resolveInstalledPostScriptName(
            isBold: isBold,
            sourceIsSerif: isSerif,
            customPostScriptName: configuration.customFontPostScriptName
        )
        let rawFirstLineIndent = (paragraph.kind == .text && paragraph.firstLineIndent >= baseFontSize * 0.65)
            ? min(paragraph.firstLineIndent, baseFontSize * 2.2)
            : 0.0

        let startScale = min(1.0, forcedMaxScale ?? 1.0)
        // Short paragraphs (≤ ~3 source lines) get a higher floor — the previous global 60% floor
        // was shrinking isolated captions/labels to unreadable sizes.
        let estimatedLines = max(1, paragraph.rawChars.count / 40)
        let effectiveMinRatio: CGFloat = estimatedLines <= 3
            ? max(configuration.minFontScaleRatio, 0.75)
            : configuration.minFontScaleRatio
        let minScale = min(startScale, effectiveMinRatio)

        // Line-height ladder: start at comfortable 1.50x, step down to 1.20x minimum.
        // CJK paragraphs rendered at anything below ~1.20x feel cramped against CJK full-width advance metrics.
        let lineHeightSteps: [CGFloat] = [1.50, 1.40, 1.30, 1.25, 1.20]
        var scale = startScale

        while scale >= minScale - 0.001 {
            let candidateFontSize = baseFontSize * scale
            let scaledIndent = rawFirstLineIndent * scale
            for lh in lineHeightSteps {
                let candidate = layoutTokens(
                    tokens: tokens,
                    in: paragraph.box,
                    fontSize: candidateFontSize,
                    scaleFactor: scale,
                    lineHeightMultiple: lh,
                    alignment: paragraph.alignment,
                    firstLineIndent: scaledIndent,
                    fontPostScriptName: resolvedFontName,
                    isBold: isBold,
                    color: paragraph.dominantColor,
                    clampToBoxFloor: false
                )
                if candidate.fitsInBox {
                    return candidate.result
                }
            }
            scale -= 0.05
        }

        // At minimum font scale (e.g. 60%), check if we can expand the paragraph box downward into available whitespace
        let minFontSize = baseFontSize * minScale
        let floorY = availableBottomY ?? max(paragraph.box.minY - baseFontSize * 1.5, 24.0)
        var expandedBox = paragraph.box
        if floorY < paragraph.box.minY {
            let extraHeight = paragraph.box.minY - floorY
            expandedBox = CGRect(
                x: paragraph.box.minX,
                y: floorY,
                width: paragraph.box.width,
                height: paragraph.box.height + extraHeight
            )
        }

        let finalAttempt = layoutTokens(
            tokens: tokens,
            in: expandedBox,
            fontSize: minFontSize,
            scaleFactor: minScale,
            lineHeightMultiple: 1.20,
            alignment: paragraph.alignment,
            firstLineIndent: rawFirstLineIndent * minScale,
            fontPostScriptName: resolvedFontName,
            isBold: isBold,
            color: paragraph.dominantColor,
            clampToBoxFloor: true
        )
        return finalAttempt.result
    }

    // MARK: - Tokenization & Kinsoku Line Breaking

    enum LayoutToken {
        case glyph(char: Character, isCJK: Bool, isLatinOrDigit: Bool)
        case formula(placeholder: String, chars: [CharIR], originalBox: CGRect)
    }

    private func tokenizeParagraph(
        text: String,
        segments: [Segment],
        baseFontSize: CGFloat
    ) -> [LayoutToken] {
        var formulaLookup: [String: (chars: [CharIR], box: CGRect)] = [:]
        for seg in segments {
            if case .formula(let placeholder, let chars, let box) = seg {
                formulaLookup[placeholder] = (chars, box)
            }
        }

        let pieces = PlaceholderValidator.splitByPlaceholders(text)
        var tokens: [LayoutToken] = []

        for piece in pieces {
            switch piece {
            case .placeholder(let ph):
                if let info = formulaLookup[ph] {
                    tokens.append(.formula(placeholder: ph, chars: info.chars, originalBox: info.box))
                } else {
                    // Fallback synthetic box if placeholder wasn't in segments
                    let syntheticBox = CGRect(x: 0, y: 0, width: baseFontSize * 1.5, height: baseFontSize)
                    tokens.append(.formula(placeholder: ph, chars: [], originalBox: syntheticBox))
                }
            case .text(let str):
                for ch in str {
                    if ch == "\n" || ch == "\r" { continue }
                    tokens.append(
                        .glyph(
                            char: ch,
                            isCJK: Self.isCJKCharacter(ch),
                            isLatinOrDigit: Self.isLatinOrDigitCharacter(ch)
                        )
                    )
                }
            }
        }
        return tokens
    }

    private struct LayoutAttempt {
        let result: TypesetResult
        let fitsInBox: Bool
    }

    private struct PositionedToken {
        let token: LayoutToken
        var width: CGFloat
        var height: CGFloat
        var leadingQuarterEm: CGFloat
    }

    private func layoutTokens(
        tokens: [LayoutToken],
        in box: CGRect,
        fontSize: CGFloat,
        scaleFactor: CGFloat,
        lineHeightMultiple: CGFloat,
        alignment: TextAlignmentMode,
        firstLineIndent: CGFloat = 0,
        fontPostScriptName: String,
        isBold: Bool,
        color: RGBAColor,
        clampToBoxFloor: Bool = false
    ) -> LayoutAttempt {
        let ctFont = CTFontCreateWithName(fontPostScriptName as CFString, fontSize, nil)
        let maxLineWidth = max(fontSize * 2.0, box.width)
        let lineHeight = fontSize * lineHeightMultiple

        // Measure each token with Core Text and compute CJK-Latin 1/4-em spacing
        var measured: [PositionedToken] = []
        measured.reserveCapacity(tokens.count)

        for (idx, tok) in tokens.enumerated() {
            var leadingSpace: CGFloat = 0
            if configuration.cjkLatinQuarterEmSpacing, idx > 0 {
                let prev = tokens[idx - 1]
                if shouldInsertQuarterEmSpace(between: prev, and: tok) {
                    leadingSpace = fontSize * 0.25
                }
            }

            switch tok {
            case .glyph(let ch, _, _):
                let w = measureCharacterWidth(ch, font: ctFont, fallbackFontSize: fontSize)
                measured.append(PositionedToken(token: tok, width: w, height: fontSize, leadingQuarterEm: leadingSpace))
            case .formula(_, _, let origBox):
                let w = max(fontSize * 0.6, origBox.width)
                let h = max(fontSize * 0.8, origBox.height)
                measured.append(PositionedToken(token: tok, width: w, height: h, leadingQuarterEm: leadingSpace))
            }
        }

        // Break into lines respecting kinsoku rules (中文标点禁则) and English word boundaries
        var lineBuckets: [[PositionedToken]] = []
        var currentLine: [PositionedToken] = []
        var currentWidth: CGFloat = 0

        var idx = 0
        while idx < measured.count {
            var item = measured[idx]
            let isFirstLine = lineBuckets.isEmpty
            let lineAvailWidth = isFirstLine ? max(fontSize * 2.0, maxLineWidth - firstLineIndent) : maxLineWidth
            if currentLine.isEmpty {
                item.leadingQuarterEm = 0
                // Skip leading space at start of line
                if case .glyph(let ch, _, _) = item.token, ch == " " {
                    idx += 1
                    continue
                }
            }

            let addedWidth = item.leadingQuarterEm + item.width
            if !currentLine.isEmpty && (currentWidth + addedWidth > lineAvailWidth) {
                // Kinsoku check 1: If the overflowing token is line-start forbidden punctuation (e.g. ，。！？）》),
                // keep it on the current line if close, or pull the last character from currentLine to the next line.
                if case .glyph(let ch, _, _) = item.token,
                   Self.lineStartForbiddenPunctuation.contains(ch) {
                    currentLine.append(item)
                    lineBuckets.append(currentLine)
                    currentLine = []
                    currentWidth = 0
                    idx += 1
                    continue
                }

                // Kinsoku check 2: If the last token on currentLine is line-end forbidden punctuation (e.g. （《「),
                // move it to the start of the next line.
                if currentLine.count >= 2,
                   let lastItem = currentLine.last,
                   case .glyph(let lastCh, _, _) = lastItem.token,
                   Self.lineEndForbiddenPunctuation.contains(lastCh) {
                    let popped = currentLine.removeLast()
                    lineBuckets.append(currentLine)
                    var carried = popped
                    carried.leadingQuarterEm = 0
                    currentLine = [carried]
                    currentWidth = carried.width
                    continue
                }

                // Word-wrap check for English words: avoid splitting mid-word if the line has an earlier break point
                if case .glyph(_, _, let isLatin) = item.token, isLatin,
                   let lastSpaceIdx = currentLine.lastIndex(where: {
                       if case .glyph(let c, _, _) = $0.token { return c == " " || Self.isCJKCharacter(c) }
                       return true
                   }),
                   lastSpaceIdx > 0 && lastSpaceIdx < currentLine.count - 1 {
                    let tail = Array(currentLine[(lastSpaceIdx + 1)...])
                    currentLine.removeSubrange((lastSpaceIdx + 1)...)
                    lineBuckets.append(currentLine)
                    currentLine = tail
                    if !currentLine.isEmpty {
                        currentLine[0].leadingQuarterEm = 0
                    }
                    currentWidth = currentLine.reduce(0) { $0 + $1.leadingQuarterEm + $1.width }
                    continue
                }

                lineBuckets.append(currentLine)
                currentLine = []
                currentWidth = 0
                continue
            } else {
                currentLine.append(item)
                currentWidth += addedWidth
                idx += 1
            }
        }
        if !currentLine.isEmpty {
            lineBuckets.append(currentLine)
        }

        // Position lines top-to-bottom starting from `box.maxY`
        var typesetLines: [TypesetLine] = []
        var cursorTopY = box.maxY
        var lowestBaselineY = box.maxY

        for (lineIdx, bucket) in lineBuckets.enumerated() {
            let maxItemHeight = bucket.map(\.height).max() ?? fontSize
            // First line keeps tight leading so ascenders stay inside the box; subsequent lines enforce
            // at least `lineHeightMultiple * fontSize` plus a 18% glyph-height floor so tall formula tokens
            // never visually collide with the line above.
            let effectiveStep = (lineIdx == 0)
                ? max(fontSize * 0.92, maxItemHeight * 0.88)
                : max(lineHeight, maxItemHeight * 1.18)
            let baselineY = cursorTopY - effectiveStep
            if clampToBoxFloor && lineIdx > 0 && baselineY < box.minY - fontSize * 0.25 {
                break
            }
            lowestBaselineY = baselineY

            let naturalWidth = bucket.reduce(CGFloat(0)) { $0 + $1.leadingQuarterEm + $1.width }
            let isLastLine = (lineIdx == lineBuckets.count - 1)
            let lineIndent = (lineIdx == 0 && alignment != .center) ? firstLineIndent : 0
            let lineMaxW = max(1, box.width - lineIndent)

            var startX = box.minX + lineIndent
            var extraPerGap: CGFloat = 0
            if alignment == .center && naturalWidth < box.width {
                startX = box.minX + (box.width - naturalWidth) * 0.5
            } else if alignment == .justified && !isLastLine && bucket.count > 1 && naturalWidth < lineMaxW && naturalWidth > lineMaxW * 0.65 {
                extraPerGap = (lineMaxW - naturalWidth) / CGFloat(bucket.count - 1)
            }

            var cursorX = startX
            var runs: [PlacedRun] = []

            for (tokIdx, posTok) in bucket.enumerated() {
                cursorX += posTok.leadingQuarterEm + (tokIdx > 0 ? extraPerGap : 0)
                let tokenFrame = CGRect(x: cursorX, y: baselineY, width: posTok.width, height: posTok.height)

                switch posTok.token {
                case .glyph(let ch, _, _):
                    let str = String(ch)
                    // Merge adjacent glyph runs on the same line if there is no extra gap
                    if extraPerGap == 0 && posTok.leadingQuarterEm == 0,
                       case .text(let prevStr, let prevFrame, let prevSize, let prevColor, let prevBold) = runs.last {
                        let combinedFrame = prevFrame.union(tokenFrame)
                        runs[runs.count - 1] = .text(
                            text: prevStr + str,
                            frame: combinedFrame,
                            fontSize: prevSize,
                            color: prevColor,
                            isBold: prevBold
                        )
                    } else {
                        runs.append(
                            .text(
                                text: str,
                                frame: tokenFrame,
                                fontSize: fontSize,
                                color: color,
                                isBold: isBold
                            )
                        )
                    }
                case .formula(let ph, let chars, _):
                    runs.append(.formula(placeholder: ph, chars: chars, frame: tokenFrame))
                }
                cursorX += posTok.width
            }

            typesetLines.append(TypesetLine(baselineY: baselineY, runs: runs))
            cursorTopY = baselineY
        }

        let fits = (lowestBaselineY >= box.minY - fontSize * 0.28)
        let usedBox = CGRect(
            x: box.minX,
            y: min(box.minY, lowestBaselineY),
            width: box.width,
            height: max(box.height, box.maxY - lowestBaselineY)
        )

        return LayoutAttempt(
            result: TypesetResult(
                fontSize: fontSize,
                scaleFactor: scaleFactor,
                lineHeightMultiple: lineHeightMultiple,
                expandedBox: usedBox,
                lines: typesetLines
            ),
            fitsInBox: fits
        )
    }

    private func measureCharacterWidth(_ ch: Character, font: CTFont, fallbackFontSize: CGFloat) -> CGFloat {
        let str = String(ch)
        let attr = NSAttributedString(
            string: str,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > 0.1 {
            return width
        }
        return Self.isCJKCharacter(ch) ? fallbackFontSize : fallbackFontSize * 0.55
    }

    private func shouldInsertQuarterEmSpace(between left: LayoutToken, and right: LayoutToken) -> Bool {
        switch (left, right) {
        case (.glyph(_, let lCJK, let lLat), .glyph(_, let rCJK, let rLat)):
            return (lCJK && rLat) || (lLat && rCJK)
        case (.glyph(_, let lCJK, _), .formula):
            return lCJK
        case (.formula, .glyph(_, let rCJK, _)):
            return rCJK
        default:
            return false
        }
    }

    private func findAvailableBottomY(forParagraphAt index: Int, in page: PageIR) -> CGFloat {
        let currentBox = page.paragraphs[index].box
        let pageFloor = max(page.mediaBox.minY + 24.0, currentBox.minY - max(18.0, currentBox.height * 0.25))
        var highestObstacleBelow = pageFloor

        // Check other paragraphs and regions in the same horizontal column range
        for (otherIdx, otherPara) in page.paragraphs.enumerated() where otherIdx != index {
            let horizontalOverlap = min(currentBox.maxX, otherPara.box.maxX) - max(currentBox.minX, otherPara.box.minX)
            if horizontalOverlap > 6.0 && otherPara.box.midY < currentBox.midY && otherPara.box.maxY <= currentBox.minY + 8.0 {
                highestObstacleBelow = max(highestObstacleBelow, otherPara.box.maxY + 2.5)
            }
        }
        for region in page.regions where !region.kind.isTranslatable {
            let horizontalOverlap = min(currentBox.maxX, region.box.maxX) - max(currentBox.minX, region.box.minX)
            if horizontalOverlap > 6.0 && region.box.midY < currentBox.midY && region.box.maxY <= currentBox.minY + 8.0 {
                highestObstacleBelow = max(highestObstacleBelow, region.box.maxY + 2.5)
            }
        }
        return min(currentBox.minY, highestObstacleBelow)
    }

    public static func isCJKCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) ||
               (0x3400...0x4DBF).contains(v) ||
               (0xF900...0xFAFF).contains(v)
    }

    public static func isLatinOrDigitCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x0030...0x0039).contains(v) ||
               (0x0041...0x005A).contains(v) ||
               (0x0061...0x007A).contains(v)
    }
}
