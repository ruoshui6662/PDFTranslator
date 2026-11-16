import Foundation
import CoreGraphics

public struct RGBAColor: Sendable, Codable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBAColor(r: 0, g: 0, b: 0, a: 255)
}

public struct DocumentIR: Sendable, Codable, Equatable {
    public var sourceFileName: String
    public var pages: [PageIR]

    public init(sourceFileName: String = "", pages: [PageIR] = []) {
        self.sourceFileName = sourceFileName
        self.pages = pages
    }

    public var skippedScannedPages: [Int] {
        pages.filter(\.isScannedPage).map(\.index)
    }

    public var totalTranslatableCharacters: Int {
        pages.reduce(0) { acc, page in
            acc + page.paragraphs.reduce(0) { $0 + $1.sourceText.count }
        }
    }
}

public struct PageIR: Sendable, Codable, Equatable {
    public let index: Int
    public let mediaBox: CGRect              // PDF coordinate system, origin at bottom-left
    public var isScannedPage: Bool
    public var chars: [CharIR]               // Populated in Parser stage
    public var regions: [LayoutRegion]       // Populated in LayoutDetector stage
    public var paragraphs: [ParagraphIR]     // Populated in ParagraphBuilder stage

    public init(
        index: Int,
        mediaBox: CGRect,
        isScannedPage: Bool = false,
        chars: [CharIR] = [],
        regions: [LayoutRegion] = [],
        paragraphs: [ParagraphIR] = []
    ) {
        self.index = index
        self.mediaBox = mediaBox
        self.isScannedPage = isScannedPage
        self.chars = chars
        self.regions = regions
        self.paragraphs = paragraphs
    }
}

public struct CharIR: Sendable, Codable, Equatable {
    public let unicode: String
    public let box: CGRect
    public let fontName: String
    public let fontSize: CGFloat
    public let color: RGBAColor
    public let objectID: Int                 // Owning PDF text object index; used in PDFWriter
    public var isFormula: Bool
    public var isBold: Bool
    public var isItalic: Bool

    public init(
        unicode: String,
        box: CGRect,
        fontName: String,
        fontSize: CGFloat,
        color: RGBAColor = .black,
        objectID: Int = -1,
        isFormula: Bool = false,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.unicode = unicode
        self.box = box
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.objectID = objectID
        self.isFormula = isFormula
        self.isBold = isBold
        self.isItalic = isItalic
    }
}

public struct LayoutRegion: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case title
        case text
        case list
        case caption
        case footnote
        case figure
        case table
        case formula
        case header
        case footer
        case other

        public var isTranslatable: Bool {
            switch self {
            case .title, .text, .list, .caption, .footnote:
                return true
            case .figure, .table, .formula, .header, .footer, .other:
                return false
            }
        }
    }

    public let kind: Kind
    public var box: CGRect
    public let confidence: Float

    public init(kind: Kind, box: CGRect, confidence: Float = 1.0) {
        self.kind = kind
        self.box = box
        self.confidence = confidence
    }
}

public enum TextAlignmentMode: String, Sendable, Codable, Equatable {
    case left
    case center
    case justified
}

public struct TextStyleRun: Sendable, Codable, Equatable {
    public var isBold: Bool
    public var isItalic: Bool
    public var fontSize: CGFloat
    public var color: RGBAColor

    public init(
        isBold: Bool = false,
        isItalic: Bool = false,
        fontSize: CGFloat = 10.5,
        color: RGBAColor = .black
    ) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.fontSize = fontSize
        self.color = color
    }
}

public enum Segment: Sendable, Codable, Equatable {
    case text(String, style: TextStyleRun)
    case formula(placeholder: String, chars: [CharIR], box: CGRect)
}

public struct ParagraphIR: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var box: CGRect
    public let kind: LayoutRegion.Kind
    public var alignment: TextAlignmentMode
    public var firstLineIndent: CGFloat
    public var dominantFontSize: CGFloat
    public var dominantColor: RGBAColor
    public var rawChars: [CharIR]
    public var segments: [Segment]           // Alternating text and formula segments
    public var sourceText: String            // Contains {v1} placeholders, sent to translation engine
    public var translatedText: String?
    public var fellBackToSource: Bool
    public var overlapsNonTranslatableRegion: Bool // True when paragraph bbox intersects figure/table/image region — skip translation
    public var layout: TypesetResult?        // Populated in Typesetter stage
    public var objectIDs: [Int]              // Unique PDF text object IDs covered by this paragraph

    public init(
        id: UUID = UUID(),
        box: CGRect,
        kind: LayoutRegion.Kind,
        alignment: TextAlignmentMode = .justified,
        firstLineIndent: CGFloat = 0,
        dominantFontSize: CGFloat = 10.5,
        dominantColor: RGBAColor = .black,
        rawChars: [CharIR] = [],
        segments: [Segment] = [],
        sourceText: String = "",
        translatedText: String? = nil,
        fellBackToSource: Bool = false,
        overlapsNonTranslatableRegion: Bool = false,
        layout: TypesetResult? = nil,
        objectIDs: [Int] = []
    ) {
        self.id = id
        self.box = box
        self.kind = kind
        self.alignment = alignment
        self.firstLineIndent = firstLineIndent
        self.dominantFontSize = dominantFontSize
        self.dominantColor = dominantColor
        self.rawChars = rawChars
        self.segments = segments
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.fellBackToSource = fellBackToSource
        self.overlapsNonTranslatableRegion = overlapsNonTranslatableRegion
        self.layout = layout
        self.objectIDs = objectIDs
    }
}

public enum PlacedRun: Sendable, Codable, Equatable {
    case text(text: String, frame: CGRect, fontSize: CGFloat, color: RGBAColor, isBold: Bool)
    case formula(placeholder: String, chars: [CharIR], frame: CGRect)

    public var frame: CGRect {
        switch self {
        case .text(_, let frame, _, _, _): return frame
        case .formula(_, _, let frame): return frame
        }
    }
}

public struct TypesetLine: Sendable, Codable, Equatable {
    public var baselineY: CGFloat
    public var runs: [PlacedRun]

    public init(baselineY: CGFloat, runs: [PlacedRun]) {
        self.baselineY = baselineY
        self.runs = runs
    }
}

public struct TypesetResult: Sendable, Codable, Equatable {
    public var fontSize: CGFloat
    public var scaleFactor: CGFloat
    public var lineHeightMultiple: CGFloat
    public var expandedBox: CGRect
    public var lines: [TypesetLine]

    public init(
        fontSize: CGFloat,
        scaleFactor: CGFloat,
        lineHeightMultiple: CGFloat,
        expandedBox: CGRect,
        lines: [TypesetLine]
    ) {
        self.fontSize = fontSize
        self.scaleFactor = scaleFactor
        self.lineHeightMultiple = lineHeightMultiple
        self.expandedBox = expandedBox
        self.lines = lines
    }
}
