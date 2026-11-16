import Foundation
import CoreGraphics
import CoreText
import PDFKit

/// Generates synthetic academic and technical PDF fixtures for M0-M4 verification and regression testing.
public enum SamplePDFGenerator {
    public enum SampleKind: String, Sendable, CaseIterable {
        case singleColumnPaper
        case twoColumnPaper
        case formulaDensePaper
        case tableDensePaper
        case coloredBackgroundReport
        case bookmarkedManual
        case encryptedDocument
        case scannedDocument
    }

    public static func generateSamplePDF(
        kind: SampleKind = .singleColumnPaper,
        at url: URL,
        password: String = "secret123"
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFTranslateError.writerFailed("无法创建样本文件 \(url.lastPathComponent)")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFTranslateError.writerFailed("无法创建样本 CGContext")
        }

        switch kind {
        case .singleColumnPaper:
            drawSingleColumnPage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 1)
        case .twoColumnPaper:
            drawTwoColumnPage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 1)
        case .formulaDensePaper:
            drawFormulaDensePage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 1)
        case .tableDensePaper:
            drawTableDensePage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 1)
        case .coloredBackgroundReport:
            drawColoredBackgroundPage(ctx: ctx, mediaBox: &mediaBox)
        case .bookmarkedManual:
            drawSingleColumnPage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 1)
            drawFormulaDensePage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 2)
        case .encryptedDocument:
            drawSingleColumnPage(ctx: ctx, mediaBox: &mediaBox, pageNumber: 1)
        case .scannedDocument:
            drawScannedImageOnlyPage(ctx: ctx, mediaBox: &mediaBox)
        }

        ctx.closePDF()

        if kind == .bookmarkedManual, let doc = PDFDocument(url: url) {
            let root = PDFOutline()
            let ch1 = PDFOutline()
            ch1.label = "Chapter 1: Introduction"
            if let p0 = doc.page(at: 0) {
                ch1.destination = PDFDestination(page: p0, at: CGPoint(x: 72, y: 760))
            }
            let ch2 = PDFOutline()
            ch2.label = "Chapter 2: Mathematical Formulation"
            if let p1 = doc.page(at: 1) {
                ch2.destination = PDFDestination(page: p1, at: CGPoint(x: 72, y: 760))
            }
            root.insertChild(ch1, at: 0)
            root.insertChild(ch2, at: 1)
            doc.outlineRoot = root
            doc.write(to: url)
        } else if kind == .encryptedDocument, let doc = PDFDocument(url: url) {
            let options: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: password,
                .ownerPasswordOption: password
            ]
            doc.write(to: url, withOptions: options)
        }
    }

    /// Generates a multi-page academic paper (e.g., 20 pages) mixing single-column, two-column, formula, and table pages
    /// for performance and memory benchmarking.
    public static func generateMultiPagePaper(
        pageCount: Int = 20,
        at url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFTranslateError.writerFailed("无法创建多页样本 \(url.lastPathComponent)")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFTranslateError.writerFailed("无法创建多页 CGContext")
        }

        for pageNum in 1...max(1, pageCount) {
            switch pageNum % 4 {
            case 1:
                drawSingleColumnPage(ctx: ctx, mediaBox: &mediaBox, pageNumber: pageNum)
            case 2:
                drawTwoColumnPage(ctx: ctx, mediaBox: &mediaBox, pageNumber: pageNum)
            case 3:
                drawFormulaDensePage(ctx: ctx, mediaBox: &mediaBox, pageNumber: pageNum)
            default:
                drawTableDensePage(ctx: ctx, mediaBox: &mediaBox, pageNumber: pageNum)
            }
        }
        ctx.closePDF()
    }

    private static func drawSingleColumnPage(ctx: CGContext, mediaBox: inout CGRect, pageNumber: Int) {
        ctx.beginPage(mediaBox: &mediaBox)

        // Header
        drawText("Journal of Native macOS AI Systems · 2026", x: 72, y: 805, size: 9, fontName: "Helvetica", in: ctx)

        // Title
        drawText("Layout-Preserving Document Translation on macOS", x: 72, y: 750, size: 17, fontName: "Helvetica-Bold", in: ctx)

        // Body Paragraph 1 (with hyphenation across lines)
        drawText("Abstract. In this paper we propose a high-performance trans-", x: 72, y: 700, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("lation architecture for academic PDF documents. Our algorithm", x: 72, y: 684, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("preserves inline equations such as α + β = γ during typesetting.", x: 72, y: 668, size: 11, fontName: "Times-Roman", in: ctx)

        // Body Paragraph 2
        drawText("1. Introduction", x: 72, y: 626, size: 13.5, fontName: "Helvetica-Bold", in: ctx)
        drawText("Modern machine learning researchers read hundreds of papers.", x: 72, y: 598, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("Accurate layout detection and formula preservation are essential", x: 72, y: 582, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("for side-by-side bilingual reading without modifying source files.", x: 72, y: 566, size: 11, fontName: "Times-Roman", in: ctx)

        // Figure graphic (non-text region at y: 445..530) + Caption
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        ctx.saveGState()
        if let fill = CGColor(colorSpace: deviceRGB, components: [0.90, 0.94, 0.98, 1.0]),
           let stroke = CGColor(colorSpace: deviceRGB, components: [0.20, 0.40, 0.80, 1.0]) {
            ctx.setFillColor(fill)
            ctx.fill(CGRect(x: 140, y: 445, width: 310, height: 85))
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1.5)
            ctx.stroke(CGRect(x: 140, y: 445, width: 310, height: 85))
        }
        ctx.restoreGState()
        drawText("Figure 1: Overview of the seven-stage translation pipeline.", x: 140, y: 418, size: 9.5, fontName: "Times-Italic", in: ctx)

        // Footer page number
        drawText("\(pageNumber)", x: 294, y: 36, size: 10, fontName: "Helvetica", in: ctx)

        ctx.endPage()
    }

    private static func drawTwoColumnPage(ctx: CGContext, mediaBox: inout CGRect, pageNumber: Int) {
        ctx.beginPage(mediaBox: &mediaBox)

        drawText("Two-Column Scientific Paper Benchmark", x: 140, y: 765, size: 16, fontName: "Helvetica-Bold", in: ctx)

        // Left column (x: 54..280)
        drawText("1. Methodology", x: 54, y: 715, size: 12.5, fontName: "Helvetica-Bold", in: ctx)
        drawText("We propose a two-column layout", x: 54, y: 690, size: 10.5, fontName: "Times-Roman", in: ctx)
        drawText("detection algorithm where each", x: 54, y: 675, size: 10.5, fontName: "Times-Roman", in: ctx)
        drawText("column is ordered top to bottom.", x: 54, y: 660, size: 10.5, fontName: "Times-Roman", in: ctx)

        drawText("The loss function is defined as", x: 54, y: 625, size: 10.5, fontName: "Times-Roman", in: ctx)
        drawText("∑ λ ≤ θ for all training samples.", x: 54, y: 610, size: 10.5, fontName: "Times-Roman", in: ctx)

        // Right column (x: 315..540)
        drawText("2. Experiments", x: 315, y: 715, size: 12.5, fontName: "Helvetica-Bold", in: ctx)
        drawText("Experiments demonstrate high", x: 315, y: 690, size: 10.5, fontName: "Times-Roman", in: ctx)
        drawText("accuracy and fast performance", x: 315, y: 675, size: 10.5, fontName: "Times-Roman", in: ctx)
        drawText("across twenty benchmark files.", x: 315, y: 660, size: 10.5, fontName: "Times-Roman", in: ctx)

        drawText("\(pageNumber)", x: 294, y: 36, size: 10, fontName: "Helvetica", in: ctx)
        ctx.endPage()
    }

    private static func drawFormulaDensePage(ctx: CGContext, mediaBox: inout CGRect, pageNumber: Int) {
        ctx.beginPage(mediaBox: &mediaBox)

        drawText("Mathematical Formula Preservation Test", x: 72, y: 760, size: 15, fontName: "Helvetica-Bold", in: ctx)
        drawText("In this paper we evaluate inline equation ∑ α ≥ β and variable x", x: 72, y: 715, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("i", x: 392, y: 712, size: 7.5, fontName: "Symbol", in: ctx)
        drawText(" in neural network optimization.", x: 398, y: 715, size: 11, fontName: "Times-Roman", in: ctx)

        // Standalone display formula block
        drawText("∫ ∂ f(x) ≈ ∑ λ + Δ Ω ≠ 0", x: 195, y: 660, size: 13, fontName: "Symbol", in: ctx)

        drawText("The conclusion shows that all formula symbols remain intact.", x: 72, y: 610, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("\(pageNumber)", x: 294, y: 36, size: 10, fontName: "Helvetica", in: ctx)
        ctx.endPage()
    }

    private static func drawTableDensePage(ctx: CGContext, mediaBox: inout CGRect, pageNumber: Int) {
        ctx.beginPage(mediaBox: &mediaBox)

        drawText("Table-Dense Benchmark & Experimental Results", x: 72, y: 760, size: 15, fontName: "Helvetica-Bold", in: ctx)
        drawText("Table 1: Comparison of translation engines and layout latency.", x: 72, y: 722, size: 10, fontName: "Times-Italic", in: ctx)

        // Draw table grid lines (non-text vector graphics at y: 580..705)
        ctx.saveGState()
        ctx.setStrokeColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        ctx.setLineWidth(1.0)
        for rowY in stride(from: 585.0, through: 705.0, by: 30.0) {
            ctx.move(to: CGPoint(x: 72, y: rowY))
            ctx.addLine(to: CGPoint(x: 520, y: rowY))
        }
        for colX in [72.0, 220.0, 370.0, 520.0] {
            ctx.move(to: CGPoint(x: colX, y: 585))
            ctx.addLine(to: CGPoint(x: colX, y: 705))
        }
        ctx.strokePath()
        ctx.restoreGState()

        drawText("Results show that table borders and vector lines are preserved.", x: 72, y: 540, size: 11, fontName: "Times-Roman", in: ctx)
        drawText("\(pageNumber)", x: 294, y: 36, size: 10, fontName: "Helvetica", in: ctx)
        ctx.endPage()
    }

    private static func drawColoredBackgroundPage(ctx: CGContext, mediaBox: inout CGRect) {
        ctx.beginPage(mediaBox: &mediaBox)
        ctx.saveGState()
        ctx.setFillColor(red: 0.93, green: 0.96, blue: 0.99, alpha: 1.0)
        ctx.fill(mediaBox)
        ctx.restoreGState()

        drawText("Technical Report with Colored Background", x: 72, y: 750, size: 16, fontName: "Helvetica-Bold", in: ctx)
        drawText("When using PDFium object removal, background colors and vector", x: 72, y: 705, size: 11, fontName: "Helvetica", in: ctx)
        drawText("graphics remain completely untouched under translated text.", x: 72, y: 688, size: 11, fontName: "Helvetica", in: ctx)
        ctx.endPage()
    }

    private static func drawScannedImageOnlyPage(ctx: CGContext, mediaBox: inout CGRect) {
        ctx.beginPage(mediaBox: &mediaBox)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let bmp = CGContext(
            data: nil,
            width: 120,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 120 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            bmp.setFillColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
            bmp.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            if let img = bmp.makeImage() {
                ctx.draw(img, in: CGRect(x: 100, y: 300, width: 400, height: 300))
            }
        }
        ctx.endPage()
    }

    private static func drawText(
        _ str: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        fontName: String,
        in ctx: CGContext
    ) {
        let ctFont = CTFontCreateWithName(fontName as CFString, size, nil)
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        let blackColor = CGColor(colorSpace: deviceRGB, components: [0.0, 0.0, 0.0, 1.0]) ?? CGColor(gray: 0.0, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): blackColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs) as CFAttributedString)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
