import Foundation
import CoreText

public enum PDFTranslateError: Error, LocalizedError, Sendable, Equatable {
    case fileNotFound(String)
    case notAPDFFile(String)
    case encryptedDocumentRequiresPassword
    case invalidPassword
    case emptyDocument
    case scannedDocumentOnly(pageIndices: [Int])
    case parserFailed(String)
    case layoutDetectionFailed(String)
    case writerFailed(String)
    case downloadFailed(String)
    case outputDirectoryNotWritable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "找不到 PDF 文件“\(name)”，请确认文件未被移动或删除。"
        case .notAPDFFile:
            return "该链接或文件不是有效的 PDF 文件，请检查后重试。"
        case .encryptedDocumentRequiresPassword:
            return "该 PDF 文档已加密，请输入密码后继续翻译。"
        case .invalidPassword:
            return "PDF 密码不正确，请重新输入。"
        case .emptyDocument:
            return "PDF 文档没有任何页面。"
        case .scannedDocumentOnly:
            return "该文档全部为无文字层的扫描页，当前版本仅支持文字型 PDF。"
        case .parserFailed(let reason):
            return "PDF 解析失败：\(reason)"
        case .layoutDetectionFailed(let reason):
            return "版面分析失败：\(reason)"
        case .writerFailed(let reason):
            return "生成译文 PDF 失败：\(reason)"
        case .downloadFailed(let reason):
            return "下载 PDF 失败：\(reason)"
        case .outputDirectoryNotWritable(let dir):
            return "无法写入目录“\(dir)”，请授权目录访问或改用“下载”文件夹。"
        case .cancelled:
            return "翻译任务已取消。"
        }
    }
}

public enum CJKFontStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case autoMatch = "autoMatch"              // 智能跟随原文样式（衬线用思源宋体，无衬线用思源黑体）
    case sourceHanSerif = "sourceHanSerif"    // 思源宋体 (Source Han Serif CN)
    case sourceHanSans = "sourceHanSans"      // 思源黑体 (Source Han Sans SC)
    case pingFang = "pingFang"                // 苹方-简 (PingFang SC)
    case hiraginoSans = "hiraginoSans"        // 冬青黑体 (Hiragino Sans GB)
    case serif = "songti"                     // 华文宋体 (Songti SC)
    case sansSerif = "heiti"                  // 华文黑体 (Heiti SC)
    case kaiti = "kaiti"                      // 华文楷体 (Kaiti SC)
    case fangsong = "fangsong"                // 华文仿宋 (FangSong)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoMatch: return "智能匹配原文（思源宋+黑）"
        case .sourceHanSerif: return "思源宋体 (Source Han Serif)"
        case .sourceHanSans: return "思源黑体 (Source Han Sans)"
        case .pingFang: return "苹方-简 (PingFang SC)"
        case .hiraginoSans: return "冬青黑体 (Hiragino Sans)"
        case .serif: return "华文宋体 (Songti SC)"
        case .sansSerif: return "华文黑体 (Heiti SC)"
        case .kaiti: return "华文楷体 (Kaiti SC)"
        case .fangsong: return "华文仿宋 (FangSong)"
        }
    }

    public var shortName: String {
        switch self {
        case .autoMatch: return "智能匹配"
        case .sourceHanSerif: return "思源宋体"
        case .sourceHanSans: return "思源黑体"
        case .pingFang: return "苹方-简"
        case .hiraginoSans: return "冬青黑体"
        case .serif: return "华文宋体"
        case .sansSerif: return "华文黑体"
        case .kaiti: return "华文楷体"
        case .fangsong: return "华文仿宋"
        }
    }

    /// Preferred CoreText PostScript font candidates (Regular and Bold/SemiBold) on macOS.
    public func postScriptCandidates(isBold: Bool, sourceIsSerif: Bool = true) -> [String] {
        switch self {
        case .autoMatch:
            if sourceIsSerif {
                return isBold
                    ? ["SourceHanSerifCN-Bold", "SourceHanSerifCN-SemiBold", "SourceHanSerifSC-Bold", "STSongti-SC-Bold", "Songti SC"]
                    : ["SourceHanSerifCN-Regular", "SourceHanSerifSC-Regular", "STSongti-SC-Regular", "Songti SC"]
            } else {
                return isBold
                    ? ["SourceHanSansSC-Bold", "SourceHanSansSC-Medium", "SourceHanSansCN-Bold", "PingFangSC-Semibold", "STHeitiTC-Medium"]
                    : ["SourceHanSansSC-Regular", "SourceHanSansCN-Regular", "PingFangSC-Regular", "STHeitiSC-Light"]
            }
        case .sourceHanSerif:
            return isBold
                ? ["SourceHanSerifCN-Bold", "SourceHanSerifCN-SemiBold", "SourceHanSerifSC-Bold", "STSongti-SC-Bold", "Songti SC"]
                : ["SourceHanSerifCN-Regular", "SourceHanSerifSC-Regular", "STSongti-SC-Regular", "Songti SC"]
        case .sourceHanSans:
            return isBold
                ? ["SourceHanSansSC-Bold", "SourceHanSansSC-Medium", "SourceHanSansCN-Bold", "PingFangSC-Semibold", "STHeitiTC-Medium"]
                : ["SourceHanSansSC-Regular", "SourceHanSansCN-Regular", "PingFangSC-Regular", "STHeitiSC-Light"]
        case .pingFang:
            return isBold
                ? ["PingFangSC-Semibold", "PingFangSC-Medium", "SourceHanSansSC-Bold"]
                : ["PingFangSC-Regular", "SourceHanSansSC-Regular"]
        case .hiraginoSans:
            return isBold
                ? ["HiraginoSansGB-W6", "PingFangSC-Semibold"]
                : ["HiraginoSansGB-W3", "PingFangSC-Regular"]
        case .serif:
            return isBold
                ? ["STSongti-SC-Bold", "SourceHanSerifCN-Bold", "Songti SC"]
                : ["STSongti-SC-Regular", "Songti SC", "SourceHanSerifCN-Regular"]
        case .sansSerif:
            return isBold
                ? ["STHeitiTC-Medium", "PingFangSC-Semibold", "SourceHanSansSC-Bold"]
                : ["STHeitiSC-Light", "PingFangSC-Regular", "SourceHanSansSC-Regular"]
        case .kaiti:
            return isBold
                ? ["STKaitiSC-Bold", "STKaitiSC-Regular", "KaiTi_GB2312", "Kaiti SC"]
                : ["STKaitiSC-Regular", "KaiTi_GB2312", "Kaiti SC", "STSongti-SC-Regular"]
        case .fangsong:
            return isBold
                ? ["FangSong_GB2312", "STFangsong", "STSongti-SC-Bold"]
                : ["FangSong_GB2312", "STFangsong", "STSongti-SC-Regular"]
        }
    }

    public var coreTextFontName: String {
        resolveInstalledPostScriptName(isBold: false, sourceIsSerif: true)
    }

    public func resolveInstalledPostScriptName(
        isBold: Bool = false,
        sourceIsSerif: Bool = true,
        customPostScriptName: String? = nil
    ) -> String {
        if let custom = customPostScriptName, !custom.isEmpty,
           SystemFontCatalog.availablePostScriptNames.contains(custom) {
            return custom
        }
        for candidate in postScriptCandidates(isBold: isBold, sourceIsSerif: sourceIsSerif) {
            if SystemFontCatalog.availablePostScriptNames.contains(candidate) {
                return candidate
            }
        }
        return isBold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
    }
}

public struct InstalledFontOption: Sendable, Codable, Equatable, Identifiable {
    public var id: String { postScriptName }
    public let postScriptName: String
    public let displayName: String

    public init(postScriptName: String, displayName: String) {
        self.postScriptName = postScriptName
        self.displayName = displayName
    }
}

public enum SystemFontCatalog {
    public static let availablePostScriptNames: Set<String> = {
        guard let cfArray = CTFontManagerCopyAvailablePostScriptNames() as? [String] else {
            return []
        }
        return Set(cfArray)
    }()

    /// Discovers installed Chinese/CJK fonts on the user's Mac so the user can pick any installed system font without bundling bloat.
    public static let installedCJKFonts: [InstalledFontOption] = {
        let preferredPrefixes = [
            "SourceHanSerif", "SourceHanSans", "NotoSerifCJK", "NotoSansCJK",
            "PingFangSC", "HiraginoSansGB", "STSongti-SC", "STHeiti", "STKaiti",
            "STFangsong", "FangSong", "KaiTi", "Songti", "Kaiti", "Yuanti",
            "LXGWWenKai", "FZ", "HY", "AlibabaPuHuiTi", "MiSans", "HarmonyOS"
        ]
        var options: [InstalledFontOption] = []
        var seenFamilies = Set<String>()
        let sortedNames = availablePostScriptNames.sorted()

        for psName in sortedNames {
            guard preferredPrefixes.contains(where: { psName.hasPrefix($0) }) else { continue }
            // Prefer Regular / Light / W3 / Medium base variants in the custom list
            let lower = psName.lowercased()
            if lower.contains("bold") || lower.contains("heavy") || lower.contains("black") || lower.contains("extralight") || lower.contains("thin") {
                continue
            }
            let ctFont = CTFontCreateWithName(psName as CFString, 12.0, nil)
            let displayName = (CTFontCopyDisplayName(ctFont) as String?) ?? psName
            if seenFamilies.insert(displayName).inserted {
                options.append(InstalledFontOption(postScriptName: psName, displayName: displayName))
            }
        }
        return options
    }()

    /// Determines whether a source paragraph's English font is Serif (e.g. Linux Libertine, Times, Computer Modern Roman)
    /// vs Sans-Serif (e.g. Linux Biolinum, Helvetica, Arial, Calibri).
    public static func isSourceParagraphSerif(_ paragraph: ParagraphIR) -> Bool {
        if paragraph.kind == .title {
            // Check if the title explicitly uses a serif or sans-serif font
            let sampleFont = paragraph.rawChars.first(where: { !$0.isFormula })?.fontName.lowercased() ?? ""
            if sampleFont.contains("biolinum") || sampleFont.contains("helvetica") || sampleFont.contains("arial") || sampleFont.contains("sans") || sampleFont.contains("futura") || sampleFont.contains("calibri") {
                return false
            }
            if sampleFont.contains("libertine") || sampleFont.contains("times") || sampleFont.contains("cmbx") || sampleFont.contains("cmr") || sampleFont.contains("nimbusrom") || sampleFont.contains("garamond") || sampleFont.contains("georgia") {
                return false // Academic section headings look cleanest and most distinct in Source Han Sans Bold
            }
            return false
        }
        var serifVotes = 0
        var sansVotes = 0
        for ch in paragraph.rawChars where !ch.isFormula {
            let lower = ch.fontName.lowercased()
            if lower.contains("biolinum") || lower.contains("helvetica") || lower.contains("arial") || lower.contains("sans") || lower.contains("calibri") || lower.contains("gillsans") || lower.contains("optima") || lower.contains("cmss") {
                sansVotes += 1
            } else if lower.contains("libertine") || lower.contains("times") || lower.contains("cmr") || lower.contains("cmti") || lower.contains("cmbx") || lower.contains("nimbusrom") || lower.contains("serif") || lower.contains("garamond") || lower.contains("palatino") || lower.contains("georgia") || lower.contains("baskerville") || lower.contains("caslon") || lower.contains("stix") {
                serifVotes += 1
            }
        }
        return serifVotes >= sansVotes
    }

    /// Determines whether the source paragraph is predominantly bold (e.g. section titles, bold lead-in headings).
    public static func isSourceParagraphBold(_ paragraph: ParagraphIR) -> Bool {
        if paragraph.kind == .title { return true }
        let nonSpace = paragraph.rawChars.filter { !$0.unicode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonSpace.isEmpty else { return false }
        let boldCount = nonSpace.filter(\.isBold).count
        return Double(boldCount) / Double(nonSpace.count) >= 0.60
    }
}

public enum DualLayoutMode: String, Sendable, Codable, CaseIterable {
    case sideBySide = "sideBySide"       // 左右并排拼成宽页（默认）
    case alternating = "alternating"     // 原1、译1、原2、译2 上下交替

    public var displayName: String {
        switch self {
        case .sideBySide: return "左右并排（左原文右译文）"
        case .alternating: return "上下交替（原页与译页交替）"
        }
    }
}
