import Foundation
import PDFTranslateKit
import TranslationEngines

@main
struct PDFTranslateCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        if let genIdx = args.firstIndex(of: "--generate-sample"), genIdx + 1 < args.count {
            let outPath = args[genIdx + 1]
            let kindStr = (args.firstIndex(of: "--kind").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }) ?? "singleColumnPaper"
            let kind = SamplePDFGenerator.SampleKind(rawValue: kindStr) ?? .singleColumnPaper
            do {
                let url = URL(fileURLWithPath: outPath)
                try SamplePDFGenerator.generateSamplePDF(kind: kind, at: url)
                print("已生成样本 PDF: \(url.path) (类型: \(kind.rawValue))")
            } catch {
                fputs("生成样本失败: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            return
        }

        let inputArg = args[0]
        let engineType = value(for: "--engine", in: args) ?? "apple"
        let baseURL = value(for: "--base-url", in: args) ?? "https://api.deepseek.com/v1"
        let modelName = value(for: "--model", in: args) ?? "deepseek-chat"
        let apiKey = value(for: "--api-key", in: args) ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let outputDir = value(for: "--output-dir", in: args).map { URL(fileURLWithPath: $0) }
        let dumpIRPath = value(for: "--dump-ir", in: args)
        let fontArg = value(for: "--font", in: args) ?? "autoMatch"
        let dualArg = value(for: "--dual-mode", in: args) ?? "sideBySide"
        let forceOverlay = args.contains("--overlay")

        let inputURL: URL
        if inputArg.hasPrefix("http://") || inputArg.hasPrefix("https://") {
            guard let u = URL(string: inputArg) else {
                fputs("无效的链接: \(inputArg)\n", stderr)
                Foundation.exit(1)
            }
            inputURL = u
        } else {
            inputURL = URL(fileURLWithPath: inputArg)
        }

        let engine: any TranslationEngine
        switch engineType.lowercased() {
        case "openai":
            let cfg = OpenAICompatibleConfiguration(
                providerID: "cli",
                displayName: "OpenAI CLI",
                baseURLString: baseURL,
                modelName: modelName,
                requiresAPIKey: !baseURL.contains("localhost") && !baseURL.contains("127.0.0.1")
            )
            engine = OpenAICompatibleEngine(configuration: cfg, apiKey: apiKey)
        case "mock":
            engine = MockTranslationEngine()
        default:
            engine = AppleSystemTranslationEngine()
        }

        let fontStyle = CJKFontStyle(rawValue: fontArg) ?? .autoMatch
        let dualMode: DualLayoutMode = (dualArg == "alternating") ? .alternating : .sideBySide

        let jobConfig = TranslationJobConfiguration(
            fontStyle: fontStyle,
            dualLayoutMode: dualMode,
            outputDirectory: outputDir,
            forceOverlayFallback: forceOverlay
        )

        let pdfiumReady = await PDFiumActor.shared.isAvailable()
        let pdfiumPath = await PDFiumActor.shared.loadedLibraryPath()
        print("PDFium 状态: \(pdfiumReady ? "已加载 (\(pdfiumPath))" : "未加载，使用 CoreGraphics 降级")")
        print("开始处理: \(inputURL.lastPathComponent) [引擎: \(engine.id)]")

        let job = TranslationJob(inputURL: inputURL, engine: engine, configuration: jobConfig)

        do {
            let report = try await job.run { event in
                switch event {
                case .stageChanged(let stage, let cur, let tot, let frac):
                    let pct = Int(frac * 100)
                    print("[\(pct)%] \(stage.rawValue) (第 \(cur)/\(tot) 页)")
                case .estimatedCharacters(let chars):
                    print("预估待翻译字符数: \(chars)")
                default:
                    break
                }
            }

            if let dumpIRPath {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report.documentIR)
                try data.write(to: URL(fileURLWithPath: dumpIRPath))
                print("DocumentIR 快照已保存至: \(dumpIRPath)")
            }

            print("\n=== 翻译完成 (\(String(format: "%.2f", report.elapsedSeconds)) 秒) ===")
            print("- 译文版 (mono): \(report.monoURL.path)")
            print("- 对照版 (dual): \(report.dualURL.path)")
            if !report.skippedScannedPages.isEmpty {
                print("- 跳过的无文字扫描页: \(report.skippedScannedPages.map { $0 + 1 })")
            }
            if !report.overlayFallbackPages.isEmpty {
                print("- 降级为覆盖法的页面: \(report.overlayFallbackPages.map { $0 + 1 })")
            }
        } catch {
            fputs("错误: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func printUsage() {
        print("""
        用法:
          pdftranslate-cli <input.pdf | https://arxiv.org/abs/...> [选项]
          pdftranslate-cli --generate-sample <output.pdf> [--kind singleColumnPaper|twoColumnPaper|formulaDensePaper|coloredBackgroundReport|bookmarkedManual|scannedDocument]

        选项:
          --engine <apple|openai|mock>       选择翻译引擎 (默认: apple)
          --base-url <url>                   OpenAI 兼容接口地址
          --model <name>                     模型名称
          --api-key <key>                    API Key (或通过环境变量 OPENAI_API_KEY)
          --output-dir <dir>                 指定输出目录 (默认: 原文件旁)
          --font <heiti|songti>              译文字体 (默认: heiti)
          --dual-mode <sideBySide|alternating> 对照版样式 (默认: sideBySide)
          --dump-ir <path.json>              导出中间表示 DocumentIR JSON
          --overlay                          强制使用 CoreGraphics 覆盖法 (Route A)
        """)
    }
}
