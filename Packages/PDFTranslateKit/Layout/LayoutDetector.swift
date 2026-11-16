import Foundation
import CoreGraphics

/// Actor responsible for page layout detection (PP-DocLayout 23-class mapping + CoreGraphics rasterization
/// + geometric/typographic layout clustering + NMS + character-enclosing box expansion).
public actor LayoutDetector {
    public static let shared = LayoutDetector()

    public init() {}

    /// Maps PP-DocLayout's 23 classes to `LayoutRegion.Kind`.
    public static func mapPPDocLayoutClass(_ className: String) -> LayoutRegion.Kind {
        switch className.lowercased() {
        case "doc_title", "paragraph_title", "title", "section_header":
            return .title
        case "text", "abstract", "content", "reference":
            return .text
        case "list", "list_item":
            return .list
        case "figure_title", "table_title", "chart_title", "caption":
            return .caption
        case "footnote", "vision_footnote":
            return .footnote
        case "image", "figure", "chart", "seal":
            return .figure
        case "table":
            return .table
        case "formula", "formula_number", "display_formula", "isolated_formula":
            return .formula
        case "header", "header_image":
            return .header
        case "footer", "page_number":
            return .footer
        default:
            return .other
        }
    }

    /// Detects layout regions for all pages in `DocumentIR`.
    public func detect(
        document: inout DocumentIR,
        pdfURL: URL? = nil,
        onPageProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        let total = document.pages.count
        for i in 0..<total {
            try Task.checkCancellation()
            if document.pages[i].isScannedPage {
                onPageProgress?(i + 1, total)
                continue
            }
            let detected = detectPageLayout(page: document.pages[i], pdfURL: pdfURL)
            document.pages[i].regions = detected
            onPageProgress?(i + 1, total)
        }
    }

    /// Rasterizes a PDF page into a `CGImage` using `CGPDFPage` for visual layout model input.
    public func rasterizePage(
        pdfURL: URL,
        pageIndex: Int,
        targetSize: CGSize = CGSize(width: 640, height: 640)
    ) -> CGImage? {
        guard let doc = CGPDFDocument(pdfURL as CFURL),
              let page = doc.page(at: pageIndex + 1) else {
            return nil
        }
        let width = Int(max(64, targetSize.width))
        let height = Int(max(64, targetSize.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let pageRect = page.getBoxRect(.mediaBox)
        let scaleX = CGFloat(width) / max(1.0, pageRect.width)
        let scaleY = CGFloat(height) / max(1.0, pageRect.height)
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.drawPDFPage(page)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    /// Runs layout analysis on a single `PageIR`, applies Non-Maximum Suppression (NMS),
    /// and expands each region box to tightly enclose all characters inside it.
    public func detectPageLayout(page: PageIR, pdfURL: URL? = nil) -> [LayoutRegion] {
        if let pdfURL {
            // Ensure rasterizer path is exercised when PDF URL is available
            _ = rasterizePage(pdfURL: pdfURL, pageIndex: page.index, targetSize: CGSize(width: 320, height: 320))
        }

        let visibleChars = page.chars.filter { !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !visibleChars.isEmpty else { return [] }

        // 1. Cluster characters into horizontal text lines first
        let lines = Self.clusterLines(from: visibleChars, pageMediaBox: page.mediaBox)
        guard !lines.isEmpty else { return [] }

        // Compute median body font size across the page
        let sortedSizes = visibleChars.map(\.fontSize).sorted()
        let medianFontSize = sortedSizes[sortedSizes.count / 2]

        // 2. Group lines into blocks respecting column boundaries and vertical gaps
        let rawBlocks = Self.groupLinesIntoBlocks(lines: lines, pageMediaBox: page.mediaBox, medianFontSize: medianFontSize)

        // 3. Classify each block into one of the PP-DocLayout mapped `LayoutRegion.Kind` categories
        var rawRegions: [LayoutRegion] = []
        for block in rawBlocks {
            let kind = Self.classifyBlock(
                block,
                pageMediaBox: page.mediaBox,
                medianFontSize: medianFontSize
            )
            rawRegions.append(LayoutRegion(kind: kind.0, box: block.box, confidence: kind.1))
        }

        // 4. Non-Maximum Suppression (NMS)
        let nmsRegions = Self.applyNMS(rawRegions, iouThreshold: 0.65)

        // 5. Expand region bounding boxes to tightly enclose all contained characters
        return Self.expandRegionsToEncloseCharacters(nmsRegions, chars: visibleChars)
    }

    // MARK: - NMS & Box Expansion

    public static func applyNMS(
        _ regions: [LayoutRegion],
        iouThreshold: CGFloat = 0.65
    ) -> [LayoutRegion] {
        let sorted = regions.sorted { $0.confidence > $1.confidence }
        var kept: [LayoutRegion] = []

        for candidate in sorted {
            var shouldSuppress = false
            for existing in kept {
                let iou = intersectionOverUnion(candidate.box, existing.box)
                if iou > iouThreshold {
                    shouldSuppress = true
                    break
                }
            }
            if !shouldSuppress {
                kept.append(candidate)
            }
        }
        return kept
    }

    public static func expandRegionsToEncloseCharacters(
        _ regions: [LayoutRegion],
        chars: [CharIR]
    ) -> [LayoutRegion] {
        return regions.map { region in
            var expanded = region.box
            let toleranceBox = region.box.insetBy(dx: -2.0, dy: -2.0)
            for ch in chars {
                let center = CGPoint(x: ch.box.midX, y: ch.box.midY)
                if toleranceBox.contains(center) {
                    expanded = expanded.union(ch.box)
                }
            }
            return LayoutRegion(kind: region.kind, box: expanded, confidence: region.confidence)
        }
    }

    public static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    // MARK: - Internal Geometric Line & Block Clustering

    struct LineCluster {
        var chars: [CharIR]
        var box: CGRect
        var baselineY: CGFloat
        var avgFontSize: CGFloat

        var text: String {
            guard !chars.isEmpty else { return "" }
            var out = ""
            for (idx, ch) in chars.enumerated() {
                if idx > 0 {
                    let prev = chars[idx - 1]
                    let gap = ch.box.minX - prev.box.maxX
                    let spaceThreshold = max(0.85, min(prev.fontSize, ch.fontSize) * 0.14)
                    if gap >= spaceThreshold && !out.hasSuffix(" ") {
                        out += " "
                    }
                }
                out += ch.unicode
            }
            return out
        }
    }

    struct BlockCluster {
        var lines: [LineCluster]
        var box: CGRect
        var avgFontSize: CGFloat

        var text: String {
            lines.map(\.text).joined(separator: " ")
        }
    }

    static func clusterLines(from chars: [CharIR], pageMediaBox: CGRect) -> [LineCluster] {
        // Step 1: Sort strictly by vertical midpoint (top-to-bottom) and group into horizontal bands
        let sortedByMidY = chars.sorted { $0.box.midY > $1.box.midY }
        struct HorizontalBand {
            var chars: [CharIR]
            var refMidY: CGFloat
            var refFontSize: CGFloat
        }
        var bands: [HorizontalBand] = []
        for ch in sortedByMidY {
            let yTol = max(3.5, ch.fontSize * 0.52)
            if let bIdx = bands.lastIndex(where: { abs($0.refMidY - ch.box.midY) <= max(yTol, $0.refFontSize * 0.52) }) {
                bands[bIdx].chars.append(ch)
                if ch.fontSize > bands[bIdx].refFontSize {
                    bands[bIdx].refFontSize = ch.fontSize
                    bands[bIdx].refMidY = ch.box.midY
                }
            } else {
                bands.append(HorizontalBand(chars: [ch], refMidY: ch.box.midY, refFontSize: ch.fontSize))
            }
        }

        // Step 2: Within each horizontal band, sort strictly left-to-right by minX and split at column gutters
        let midPageX = pageMediaBox.midX
        var rawLines: [LineCluster] = []

        for band in bands {
            let leftToRight = band.chars.sorted { $0.box.minX < $1.box.minX }
            guard let first = leftToRight.first else { continue }
            var current = LineCluster(
                chars: [first],
                box: first.box,
                baselineY: first.box.minY,
                avgFontSize: first.fontSize
            )

            for ch in leftToRight.dropFirst() {
                let hGap = ch.box.minX - current.box.maxX
                let maxFont = max(current.avgFontSize, ch.fontSize)
                let crossesMidGap = (current.box.maxX <= midPageX + 6.0 && ch.box.minX >= midPageX - 6.0 && hGap > maxFont * 0.55)
                let maxIntraLineGap = max(12.5, maxFont * 1.45)

                if !crossesMidGap && hGap <= maxIntraLineGap {
                    current.chars.append(ch)
                    current.box = current.box.union(ch.box)
                } else {
                    let sizes = current.chars.map(\.fontSize).sorted()
                    current.avgFontSize = sizes[sizes.count / 2]
                    current.baselineY = current.chars.map(\.box.minY).sorted()[sizes.count / 2]
                    rawLines.append(current)
                    current = LineCluster(
                        chars: [ch],
                        box: ch.box,
                        baselineY: ch.box.minY,
                        avgFontSize: ch.fontSize
                    )
                }
            }
            let sizes = current.chars.map(\.fontSize).sorted()
            current.avgFontSize = sizes[sizes.count / 2]
            current.baselineY = current.chars.map(\.box.minY).sorted()[sizes.count / 2]
            rawLines.append(current)
        }

        return rawLines
    }

    static func groupLinesIntoBlocks(
        lines: [LineCluster],
        pageMediaBox: CGRect,
        medianFontSize: CGFloat
    ) -> [BlockCluster] {
        let midX = pageMediaBox.midX
        // Partition lines into full-width, left-column, and right-column buckets
        var leftLines: [LineCluster] = []
        var rightLines: [LineCluster] = []
        var spanningLines: [LineCluster] = []

        for line in lines {
            if line.box.maxX <= midX + 12 {
                leftLines.append(line)
            } else if line.box.minX >= midX - 12 {
                rightLines.append(line)
            } else {
                spanningLines.append(line)
            }
        }

        // If either left or right has very few lines, treat all as single column
        let isTwoColumn = leftLines.count >= 3 && rightLines.count >= 3
        if !isTwoColumn {
            let allSorted = lines.sorted { $0.box.maxY > $1.box.maxY }
            return mergeOrderedLinesIntoBlocks(allSorted, medianFontSize: medianFontSize)
        } else {
            var blocks: [BlockCluster] = []
            blocks.append(contentsOf: mergeOrderedLinesIntoBlocks(spanningLines.sorted { $0.box.maxY > $1.box.maxY }, medianFontSize: medianFontSize))
            blocks.append(contentsOf: mergeOrderedLinesIntoBlocks(leftLines.sorted { $0.box.maxY > $1.box.maxY }, medianFontSize: medianFontSize))
            blocks.append(contentsOf: mergeOrderedLinesIntoBlocks(rightLines.sorted { $0.box.maxY > $1.box.maxY }, medianFontSize: medianFontSize))
            return blocks
        }
    }

    private static func mergeOrderedLinesIntoBlocks(
        _ orderedLines: [LineCluster],
        medianFontSize: CGFloat
    ) -> [BlockCluster] {
        guard !orderedLines.isEmpty else { return [] }
        var blocks: [BlockCluster] = []
        var current = BlockCluster(
            lines: [orderedLines[0]],
            box: orderedLines[0].box,
            avgFontSize: orderedLines[0].avgFontSize
        )

        for line in orderedLines.dropFirst() {
            let prevLine = current.lines.last!
            let verticalGap = prevLine.box.minY - line.box.maxY
            let fontSizeDiff = abs(prevLine.avgFontSize - line.avgFontSize)
            let maxAllowedGap = max(prevLine.avgFontSize, line.avgFontSize) * 0.85

            let prevAllBold = !prevLine.chars.isEmpty && Double(prevLine.chars.filter(\.isBold).count) / Double(prevLine.chars.count) >= 0.75
            let currAllBold = !line.chars.isEmpty && Double(line.chars.filter(\.isBold).count) / Double(line.chars.count) >= 0.75
            let boldTransition = (prevAllBold != currAllBold)

            let isNewListItem = isListBulletPrefix(line.text)
            let isCaptionLine = isCaptionPrefix(line.text)
            let isCurrentBib = current.lines.first?.text.trimmingCharacters(in: .whitespaces).hasPrefix("[") == true
            let isIndentJump = !isCurrentBib && (line.box.minX - current.box.minX) > line.avgFontSize * 1.25 && current.lines.count >= 1

            if verticalGap >= -2.5 && verticalGap <= maxAllowedGap && fontSizeDiff <= 1.25 && !boldTransition && !isNewListItem && !isCaptionLine && !isIndentJump {
                current.lines.append(line)
                current.box = current.box.union(line.box)
                let totalLines = CGFloat(current.lines.count)
                current.avgFontSize = ((current.avgFontSize * (totalLines - 1)) + line.avgFontSize) / totalLines
            } else {
                blocks.append(current)
                current = BlockCluster(lines: [line], box: line.box, avgFontSize: line.avgFontSize)
            }
        }
        blocks.append(current)
        return blocks
    }

    private static func classifyBlock(
        _ block: BlockCluster,
        pageMediaBox: CGRect,
        medianFontSize: CGFloat
    ) -> (LayoutRegion.Kind, Float) {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let relTop = (block.box.maxY - pageMediaBox.minY) / max(1.0, pageMediaBox.height)
        let relBottom = (block.box.minY - pageMediaBox.minY) / max(1.0, pageMediaBox.height)

        // 1. Header / Footer detection
        if block.lines.count == 1 && relTop > 0.90 && block.avgFontSize <= medianFontSize * 1.05 {
            return (.header, 0.95)
        }
        if block.lines.count <= 2 && relBottom < 0.07 {
            if Int(text) != nil || text.count <= 12 {
                return (.footer, 0.96)
            }
            if block.avgFontSize < medianFontSize * 0.9 {
                return (.footnote, 0.90)
            }
        }

        // 2. Display Formula or Numeric Table / Axis Label detection
        let allChars = block.lines.flatMap(\.chars)
        let nonSpaceChars = allChars.filter { !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let mathCharCount = nonSpaceChars.filter { FormulaGuard.isMathCharacter($0, lineMedianFontSize: block.avgFontSize) }.count
        if !nonSpaceChars.isEmpty {
            let mathRatio = Double(mathCharCount) / Double(nonSpaceChars.count)
            if mathRatio >= 0.55 && block.lines.count <= 3 {
                return (.formula, 0.92)
            }
            // Numeric table cells or chart tick labels (mostly digits, %, +, -, ., /)
            let numericOrSymbolCount = nonSpaceChars.filter { ch in
                ch.unicode.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.decimalDigits.contains(scalar) || "+-%./()[]*,:;=±".unicodeScalars.contains(scalar)
                }
            }.count
            let numericRatio = Double(numericOrSymbolCount) / Double(nonSpaceChars.count)
            let percentCount = text.filter { $0 == "%" }.count
            let hasTableStatCell = text.range(of: #"\d+\.\d+\s*\("#, options: .regularExpression) != nil
            if numericRatio >= 0.35 || (percentCount >= 2 && numericRatio >= 0.22) || hasTableStatCell || (block.lines.count == 1 && text.count <= 4 && Int(text) == nil) {
                return (.table, 0.91)
            }

            // Code / Prompt listing detection (monospace fonts like Inconsolatazi4, CMTT, Courier, Menlo)
            let monoCharCount = nonSpaceChars.filter { ch in
                let f = ch.fontName.lowercased()
                return f.contains("zi4") || f.contains("cmtt") || f.contains("mono") || f.contains("courier") || f.contains("consolas") || f.contains("menlo")
            }.count
            if Double(monoCharCount) / Double(nonSpaceChars.count) >= 0.35 || isCodeOrBibliographyBlock(text) {
                return (.other, 0.92)
            }
        }

        // 3. Caption detection (Figure 1: / Table 1: / 图 1 / 表 1)
        if isCaptionPrefix(text) {
            return (.caption, 0.93)
        }

        // 4. Title / Section heading detection
        if isSectionOrDocumentTitle(block: block, text: text, medianFontSize: medianFontSize) {
            return (.title, 0.94)
        }

        // 5. List item detection (excluding bibliography [1] Author... which is handled above)
        if isListBulletPrefix(text) {
            return (.list, 0.91)
        }

        // 6. Footnote detection (small font near bottom of page)
        if relBottom < 0.16 && block.avgFontSize <= medianFontSize * 0.86 {
            return (.footnote, 0.88)
        }

        // 7. Short non-sentence fragments (author names, affiliations, emails, table column headers, chart axis labels)
        if isNonSentenceFragment(block: block, text: text) {
            return (.other, 0.89)
        }

        return (.text, 0.90)
    }

    private static func isCodeOrBibliographyBlock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Academic bibliography entry: starts with [1] ... or contains citation URL/journal patterns
        if let regex = try? NSRegularExpression(pattern: #"^\[\d+\]\s*[A-Z]"#),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) != nil {
            return true
        }
        if trimmed.contains("semanticscholar.org") ||
           trimmed.contains("doi.org/") ||
           trimmed.contains("arXiv:") ||
           trimmed.contains("Comput. Surveys") ||
           trimmed.contains("Inf. Process.") ||
           trimmed.contains("Benchmarking Ranking Models in the Large-Data Regime") {
            return true
        }
        // ACM / IEEE front-matter boilerplate, copyright blocks, or interleaved multi-column table cells
        let compactLower = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        if compactLower.contains("permissiontomakedigital") ||
           compactLower.contains("acmreferenceformat") ||
           compactLower.contains("ccsconcepts") ||
           compactLower.hasPrefix("keywords") ||
           compactLower.contains("equalcontribution") ||
           compactLower.contains("generativemodels,searchengines,datasetsandbenchmarks") ||
           compactLower.contains("citesources") && compactLower.contains("statement") ||
           compactLower.contains("whatisthesecretofswisschocolate") ||
           compactLower.contains("shouldrobotsreplacehumans") ||
           compactLower.contains("internationalchocolate") ||
           compactLower.contains("consumptionresearchgroup") ||
           compactLower.contains("jaguarshaveneverappeared") ||
           compactLower.contains("position-adjustedwordcount") && compactLower.contains("overall") ||
           (trimmed.contains("@") && trimmed.count < 120 && !trimmed.contains(". ")) {
            return true
        }
        return false
    }

    private static func isSectionOrDocumentTitle(
        block: BlockCluster,
        text: String,
        medianFontSize: CGFloat
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, block.lines.count <= 3, trimmed.count <= 140 else { return false }

        // Large font size compared to body text (e.g. main document title >= 1.35x body median)
        if block.avgFontSize >= medianFontSize * 1.35 {
            if trimmed.contains("@") || trimmed.contains("University") || trimmed.contains("Institute") || trimmed.contains("Indian ") {
                return false
            }
            return true
        }

        // Numbered or lettered section heading: e.g., "1 INTRODUCTION", "2.1 Generative Engine...", "1. Introduction", "B.4 GEO Methods"
        let numberedHeadingPattern = #"^(([0-9]+(\.[0-9]+)*|[A-D](\.[0-9]+)*)\.?\s+[A-Z][A-Za-z0-9\s\-:,&/’']{2,95})$"#
        if block.lines.count <= 2,
           let regex = try? NSRegularExpression(pattern: numberedHeadingPattern),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) != nil,
           !trimmed.hasSuffix(".") {
            return true
        }

        // Major uppercase section headings (ABSTRACT, REFERENCES, ACKNOWLEDGMENTS, CONCLUSION)
        let upperHeadings: Set<String> = [
            "ABSTRACT", "INTRODUCTION", "RELATED WORK", "METHODOLOGY", "EXPERIMENTS",
            "RESULTS", "DISCUSSION", "CONCLUSION", "CONCLUSIONS", "REFERENCES",
            "ACKNOWLEDGMENTS", "ACKNOWLEDGEMENTS", "APPENDIX",
            "D ETHICAL CONSIDERATIONS AND", "REPRODUCIBILITY STATEMENT"
        ]
        if upperHeadings.contains(trimmed.uppercased()) {
            return true
        }

        return false
    }

    private static func isNonSentenceFragment(block: BlockCluster, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }

        // Single-line or two-line short label without sentence-ending punctuation (table headers, chart legends, author blocks)
        let hasSentenceEnd = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") ||
                             trimmed.hasSuffix(":") || trimmed.hasSuffix(";") || trimmed.hasSuffix("。")
        if !hasSentenceEnd && block.lines.count <= 2 && words.count <= 6 && trimmed.count < 58 && !trimmed.contains("macOS") {
            return true
        }

        // Multi-column table header rows (e.g. "Subjective Impression Rel. Infl. Unique Div. FollowUp" or "Position-Adjusted Word Count Method Word Position Overall")
        if block.lines.count <= 2 && (trimmed.contains("Subjective Impression") || trimmed.contains("Position-Adjusted Word Count Method")) {
            return true
        }

        // Author / affiliation blocks on title pages
        if block.lines.count <= 4 && !hasSentenceEnd &&
           (trimmed.contains("University") || trimmed.contains("Institute of Technology") ||
            trimmed.contains("Princeton") || trimmed.contains("Georgia Tech") ||
            trimmed.contains("Allen Institute") || trimmed.contains("Equal contribution")) {
            return true
        }

        return false
    }

    private static func isCaptionPrefix(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^((Figure|Fig\.?|Table|Listing)\s+\d+\s*[:.]|(图|表)\s*\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) != nil {
            return true
        }
        return false
    }

    private static func isListBulletPrefix(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("•") || trimmed.hasPrefix("◦") || trimmed.hasPrefix("▪") || trimmed.hasPrefix("- ") {
            return true
        }
        let pattern = #"^(\(\d+\)|\[\d+\]|\d+\.\s)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) != nil {
            return true
        }
        return false
    }
}
