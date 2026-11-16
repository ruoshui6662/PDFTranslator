import AppKit
import Foundation
import Observation
import PDFTranslateKit
import TranslationEngines
import UniformTypeIdentifiers

public enum ReaderViewMode: String, CaseIterable, Identifiable, Sendable {
    case sideBySide = "对照"
    case translatedOnly = "仅译文"
    case originalOnly = "仅原文"

    public var id: String { rawValue }
}

public enum SelectedEngineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleSystem = "apple"
    case deepseek = "deepseek"
    case siliconflow = "siliconflow"
    case openai = "openai"
    case ollama = "ollama"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSystem: return "Apple 系统翻译（免 Key·离线）"
        case .deepseek: return "DeepSeek"
        case .siliconflow: return "硅基流动 (SiliconFlow)"
        case .openai: return "OpenAI 兼容接口"
        case .ollama: return "Ollama 本地模型"
        }
    }

    public var shortDisplayName: String {
        switch self {
        case .appleSystem: return "Apple 翻译"
        case .deepseek: return "DeepSeek"
        case .siliconflow: return "硅基流动"
        case .openai: return "OpenAI 接口"
        case .ollama: return "Ollama 本地"
        }
    }

    public var subtitle: String {
        switch self {
        case .appleSystem: return "macOS 原生神经翻译 · 免配置 · 本地离线处理"
        case .deepseek: return "DeepSeek V4.1 Flash · 极速高性价比学术翻译推荐"
        case .siliconflow: return "DeepSeek V4.1 Flash / Qwen · 国内直连高速接口"
        case .openai: return "兼容任意 OpenAI /v1/chat/completions 规范服务"
        case .ollama: return "连接本机 http://localhost:11434 · 隐私不出本机"
        }
    }

    public var recommendedModels: [(id: String, label: String)] {
        switch self {
        case .appleSystem:
            return []
        case .deepseek:
            return [
                ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash（推荐·极速高性价比）"),
                ("deepseek-v4.1", "DeepSeek V4.1（旗舰版）"),
                ("deepseek-chat", "deepseek-chat（官方标准）")
            ]
        case .siliconflow:
            return [
                ("deepseek-ai/DeepSeek-V4.1-Flash", "DeepSeek V4.1 Flash（推荐·极速高性价比）"),
                ("Qwen/Qwen3-8B", "Qwen3-8B（高速免费档）"),
                ("deepseek-ai/DeepSeek-V3", "DeepSeek-V3")
            ]
        case .openai:
            return [
                ("gpt-4.1-mini", "GPT-4.1 mini（推荐·高性价比）"),
                ("gpt-4.1-nano", "GPT-4.1 nano（极速轻量）"),
                ("gpt-4o-mini", "GPT-4o mini")
            ]
        case .ollama:
            return [
                ("qwen2.5:7b", "qwen2.5:7b（推荐本地中英模型）"),
                ("deepseek-r1:8b", "deepseek-r1:8b"),
                ("gemma3:12b", "gemma3:12b")
            ]
        }
    }

    public var symbolName: String {
        switch self {
        case .appleSystem: return "apple.logo"
        case .deepseek: return "sparkles"
        case .siliconflow: return "bolt.horizontal.circle"
        case .openai: return "globe"
        case .ollama: return "desktopcomputer"
        }
    }

    public var isCloudService: Bool {
        switch self {
        case .appleSystem, .ollama:
            return false
        case .deepseek, .siliconflow, .openai:
            return true
        }
    }
}

public struct RecentDocumentRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var fileName: String
    public var sourcePath: String
    public var monoPath: String
    public var dualPath: String
    public var translatedAt: Date
    public var pageCount: Int

    public init(
        id: UUID = UUID(),
        fileName: String,
        sourcePath: String,
        monoPath: String,
        dualPath: String,
        translatedAt: Date = Date(),
        pageCount: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.monoPath = monoPath
        self.dualPath = dualPath
        self.translatedAt = translatedAt
        self.pageCount = pageCount
    }
}

@Observable
@MainActor
public final class AppState {
    public enum Phase: Equatable {
        case empty
        case translating
        case completed
        case failed
    }

    // Window state
    public var phase: Phase = .empty
    public var readerViewMode: ReaderViewMode = .sideBySide
    public var currentPageIndex: Int = 0

    // Active job state
    public var sourcePDFURL: URL?
    public var monoPDFURL: URL?
    public var dualPDFURL: URL?
    public var lastCompletionReport: JobCompletionReport?

    public var currentStage: PipelineStage = .importing
    public var progressPage: Int = 0
    public var progressTotalPages: Int = 1
    public var progressFraction: Double = 0.0
    public var estimatedCharacters: Int = 0

    // Error & Dialog states
    public var errorBannerMessage: String?
    public var isShowingFileImporter: Bool = false
    public var isShowingPasswordPrompt: Bool = false
    public var pendingPasswordInput: String = ""
    public var isShowingCloudPrivacyNotice: Bool = false
    public var pendingTranslationURLAfterPrivacy: URL?
    public var isShowingAcknowledgments: Bool = false

    /// 首次启动标记（首次安装后显示小引导窗口）
    public var isFirstLaunch: Bool {
        get { !UserDefaults.standard.bool(forKey: "pref.hasLaunchedBefore") }
        set { UserDefaults.standard.set(!newValue, forKey: "pref.hasLaunchedBefore") }
    }

    // URL input bar in empty state
    public var urlInputString: String = ""

    // User preferences (persisted in UserDefaults, API Keys in Keychain)
    public var targetLanguageIdentifier: String {
        didSet { UserDefaults.standard.set(targetLanguageIdentifier, forKey: "pref.targetLang") }
    }
    public var selectedEngineKind: SelectedEngineKind {
        didSet {
            UserDefaults.standard.set(selectedEngineKind.rawValue, forKey: "pref.engineKind")
            loadPresetIfNeeded(for: selectedEngineKind)
        }
    }
    public var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: "pref.baseURL.\(selectedEngineKind.rawValue)") }
    }
    public var customModelName: String {
        didSet { UserDefaults.standard.set(customModelName, forKey: "pref.model.\(selectedEngineKind.rawValue)") }
    }
    public var maxConcurrency: Int {
        didSet { UserDefaults.standard.set(maxConcurrency, forKey: "pref.maxConcurrency") }
    }
    public var saveNextToSourceFile: Bool {
        didSet { UserDefaults.standard.set(saveNextToSourceFile, forKey: "pref.saveNextToSource") }
    }
    public var customOutputDirectoryPath: String {
        didSet { UserDefaults.standard.set(customOutputDirectoryPath, forKey: "pref.customOutputDir") }
    }
    public var fontStyle: CJKFontStyle {
        didSet {
            UserDefaults.standard.set(fontStyle.rawValue, forKey: "pref.fontStyle")
            if !customFontPostScriptName.isEmpty {
                customFontPostScriptName = ""
            }
            retypesetIfDocumentLoaded()
        }
    }
    public var customFontPostScriptName: String {
        didSet {
            UserDefaults.standard.set(customFontPostScriptName, forKey: "pref.customFontPS")
            if !customFontPostScriptName.isEmpty {
                retypesetIfDocumentLoaded()
            }
        }
    }
    public var dualLayoutMode: DualLayoutMode {
        didSet {
            UserDefaults.standard.set(dualLayoutMode.rawValue, forKey: "pref.dualLayoutMode")
            retypesetIfDocumentLoaded()
        }
    }
    public var minFontScaleRatio: Double {
        didSet { UserDefaults.standard.set(minFontScaleRatio, forKey: "pref.minFontScale") }
    }
    public var customMathFontRegexesText: String {
        didSet { UserDefaults.standard.set(customMathFontRegexesText, forKey: "pref.mathRegexes") }
    }
    public var glossaryCSVText: String {
        didSet { UserDefaults.standard.set(glossaryCSVText, forKey: "pref.glossaryCSV") }
    }

    public var recentDocuments: [RecentDocumentRecord] = []
    public var cachedEntryCount: Int = 0
    public var connectionTestStatus: String?
    public var isTestingConnection: Bool = false

    private var activeTask: Task<Void, Never>?

    public init() {
        let defaults = UserDefaults.standard
        self.targetLanguageIdentifier = defaults.string(forKey: "pref.targetLang") ?? "zh-Hans"
        let engineRaw = defaults.string(forKey: "pref.engineKind") ?? SelectedEngineKind.appleSystem.rawValue
        let engineKind = SelectedEngineKind(rawValue: engineRaw) ?? .appleSystem
        self.selectedEngineKind = engineKind

        let defaultPreset = OpenAICompatibleConfiguration.presets.first { $0.providerID == engineKind.rawValue }
            ?? OpenAICompatibleConfiguration.presets[0]
        self.customBaseURL = defaults.string(forKey: "pref.baseURL.\(engineKind.rawValue)") ?? defaultPreset.baseURLString
        let savedModel = defaults.string(forKey: "pref.model.\(engineKind.rawValue)")
        if engineKind == .deepseek && (savedModel == nil || savedModel == "deepseek-chat" || savedModel == "deepseek-v3") {
            self.customModelName = "deepseek-v4.1-flash"
        } else {
            self.customModelName = savedModel ?? defaultPreset.modelName
        }
        let savedConcurrency = defaults.integer(forKey: "pref.maxConcurrency")
        self.maxConcurrency = savedConcurrency > 0 ? savedConcurrency : 4
        if defaults.object(forKey: "pref.saveNextToSource") != nil {
            self.saveNextToSourceFile = defaults.bool(forKey: "pref.saveNextToSource")
        } else {
            self.saveNextToSourceFile = true
        }
        self.customOutputDirectoryPath = defaults.string(forKey: "pref.customOutputDir") ?? ""
        self.fontStyle = CJKFontStyle(rawValue: defaults.string(forKey: "pref.fontStyle") ?? "") ?? .autoMatch
        self.customFontPostScriptName = defaults.string(forKey: "pref.customFontPS") ?? ""
        self.dualLayoutMode = DualLayoutMode(rawValue: defaults.string(forKey: "pref.dualLayoutMode") ?? "") ?? .sideBySide
        let savedScale = defaults.double(forKey: "pref.minFontScale")
        self.minFontScaleRatio = (savedScale >= 0.4 && savedScale <= 1.0) ? savedScale : 0.60
        self.customMathFontRegexesText = defaults.string(forKey: "pref.mathRegexes") ?? "CMMI, CMSY, CMEX, MSBM, Symbol, Math"
        self.glossaryCSVText = defaults.string(forKey: "pref.glossaryCSV") ?? "transformer,Transformer 模型\nlayout detection,版面检测"

        loadRecentDocuments()
        Task {
            await refreshCacheCount()
        }
    }

    public func currentAPIKey() -> String {
        KeychainService.loadAPIKey(for: selectedEngineKind.rawValue) ?? ""
    }

    public func saveCurrentAPIKey(_ key: String) {
        _ = KeychainService.saveAPIKey(key, for: selectedEngineKind.rawValue)
    }

    private func loadPresetIfNeeded(for kind: SelectedEngineKind) {
        guard let preset = OpenAICompatibleConfiguration.presets.first(where: { $0.providerID == kind.rawValue }) else {
            return
        }
        let defaults = UserDefaults.standard
        customBaseURL = defaults.string(forKey: "pref.baseURL.\(kind.rawValue)") ?? preset.baseURLString
        let savedModel = defaults.string(forKey: "pref.model.\(kind.rawValue)")
        if kind == .deepseek && (savedModel == nil || savedModel == "deepseek-chat" || savedModel == "deepseek-v3") {
            customModelName = "deepseek-v4.1-flash"
        } else {
            customModelName = savedModel ?? preset.modelName
        }
    }

    // MARK: - Starting & Controlling Translation Jobs

    public func handleIncomingURL(_ url: URL, password: String? = nil) {
        errorBannerMessage = nil

        // Cloud privacy check on first cloud translation
        if selectedEngineKind.isCloudService,
           !UserDefaults.standard.bool(forKey: "privacy.cloudAcknowledged") {
            pendingTranslationURLAfterPrivacy = url
            isShowingCloudPrivacyNotice = true
            return
        }

        startTranslation(for: url, password: password)
    }

    public func confirmCloudPrivacyAndContinue() {
        UserDefaults.standard.set(true, forKey: "privacy.cloudAcknowledged")
        isShowingCloudPrivacyNotice = false
        if let pending = pendingTranslationURLAfterPrivacy {
            pendingTranslationURLAfterPrivacy = nil
            startTranslation(for: pending)
        }
    }

    public func submitURLInput() {
        let trimmed = urlInputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let normalized = try PDFImporter.normalizeURL(trimmed)
            handleIncomingURL(normalized)
        } catch {
            errorBannerMessage = error.localizedDescription
        }
    }

    public func startTranslation(for inputURL: URL, password: String? = nil) {
        activeTask?.cancel()
        errorBannerMessage = nil
        if inputURL.isFileURL {
            sourcePDFURL = inputURL
        }
        monoPDFURL = nil
        dualPDFURL = nil
        phase = .translating
        currentStage = .importing
        progressPage = 0
        progressTotalPages = 1
        progressFraction = 0.02

        let engine = buildCurrentEngine()
        let outDir: URL? = inputURL.isFileURL
            ? BookmarkService.shared.resolveWritableOutputDirectory(
                preferredNextTo: inputURL,
                useSameFolderAsSource: saveNextToSourceFile,
                customFolderPath: customOutputDirectoryPath
            )
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let customRegexes = customMathFontRegexesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let glossary = GlossaryEntry.parseCSV(glossaryCSVText)

        let jobConfig = TranslationJobConfiguration(
            sourceLanguage: Locale.Language(identifier: "en"),
            targetLanguage: Locale.Language(identifier: targetLanguageIdentifier),
            glossary: glossary,
            customMathFontPatterns: customRegexes,
            fontStyle: fontStyle,
            customFontPostScriptName: customFontPostScriptName.isEmpty ? nil : customFontPostScriptName,
            dualLayoutMode: dualLayoutMode,
            minFontScaleRatio: CGFloat(minFontScaleRatio),
            maxConcurrency: maxConcurrency,
            outputDirectory: outDir,
            password: password
        )

        let job = TranslationJob(inputURL: inputURL, engine: engine, configuration: jobConfig)

        activeTask = Task {
            for await event in job.events() {
                switch event {
                case .stageChanged(let stage, let curPage, let totPages, let fraction):
                    self.currentStage = stage
                    self.progressPage = curPage
                    self.progressTotalPages = max(1, totPages)
                    self.progressFraction = fraction
                    NotificationService.shared.updateDockProgress(fraction)

                case .estimatedCharacters(let count):
                    self.estimatedCharacters = count

                case .completed(let report):
                    self.sourcePDFURL = report.sourceURL
                    self.monoPDFURL = report.monoURL
                    self.dualPDFURL = report.dualURL
                    self.lastCompletionReport = report
                    self.phase = .completed
                    NotificationService.shared.sendCompletionNotification(
                        fileName: report.sourceURL.lastPathComponent,
                        elapsedSeconds: report.elapsedSeconds
                    )
                    self.recordRecentDocument(report)
                    await self.refreshCacheCount()

                case .failed(let message):
                    NotificationService.shared.updateDockProgress(nil)
                    if message.contains("已加密") || message.contains("密码") {
                        self.isShowingPasswordPrompt = true
                    } else {
                        self.errorBannerMessage = message
                    }
                    self.phase = .empty

                case .cancelled:
                    NotificationService.shared.updateDockProgress(nil)
                    self.phase = .empty
                }
            }
        }
    }

    public func cancelCurrentJob() {
        activeTask?.cancel()
        activeTask = nil
        NotificationService.shared.updateDockProgress(nil)
        phase = .empty
    }

    public func closeCurrentDocument() {
        activeTask?.cancel()
        sourcePDFURL = nil
        monoPDFURL = nil
        dualPDFURL = nil
        lastCompletionReport = nil
        phase = .empty
    }

    /// Re-translates the currently viewed page (invalidating cache for its paragraphs) and refreshes output PDFs.
    public func retranslateCurrentPage() {
        guard let sourcePDFURL else { return }
        if let report = lastCompletionReport {
            let pageIdx = min(max(0, currentPageIndex), max(0, report.totalPages - 1))
            let engine = buildCurrentEngine()
            let customRegexes = customMathFontRegexesText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let glossary = GlossaryEntry.parseCSV(glossaryCSVText)
            let jobConfig = TranslationJobConfiguration(
                sourceLanguage: Locale.Language(identifier: "en"),
                targetLanguage: Locale.Language(identifier: targetLanguageIdentifier),
                glossary: glossary,
                customMathFontPatterns: customRegexes,
                fontStyle: fontStyle,
                customFontPostScriptName: customFontPostScriptName.isEmpty ? nil : customFontPostScriptName,
                dualLayoutMode: dualLayoutMode,
                minFontScaleRatio: CGFloat(minFontScaleRatio),
                maxConcurrency: maxConcurrency
            )

            phase = .translating
            currentStage = .translating
            progressPage = pageIdx + 1
            progressTotalPages = report.totalPages
            progressFraction = 0.5

            activeTask?.cancel()
            activeTask = Task {
                do {
                    let updatedReport = try await TranslationJob.retranslateSinglePage(
                        pageIndex: pageIdx,
                        existingReport: report,
                        engine: engine,
                        configuration: jobConfig
                    )
                    self.lastCompletionReport = updatedReport
                    self.monoPDFURL = updatedReport.monoURL
                    self.dualPDFURL = updatedReport.dualURL
                    self.phase = .completed
                    await self.refreshCacheCount()
                } catch {
                    self.errorBannerMessage = error.localizedDescription
                    self.phase = .failed
                }
            }
        } else {
            startTranslation(for: sourcePDFURL)
        }
    }

    /// Re-typesets and re-renders the currently open document immediately when the user switches the translation font or layout style,
    /// without re-running the AI translation step.
    public func retypesetIfDocumentLoaded() {
        guard phase == .completed else { return }
        if lastCompletionReport == nil,
           let srcURL = sourcePDFURL,
           let monoURL = monoPDFURL,
           let checkpointIR = TranslationJob.loadIRCheckpoint(for: srcURL) {
            let dualURL = self.dualPDFURL ?? PDFWriter.defaultOutputURLs(for: srcURL).dualURL
            lastCompletionReport = JobCompletionReport(
                sourceURL: srcURL,
                monoURL: monoURL,
                dualURL: dualURL,
                totalPages: checkpointIR.pages.count,
                skippedScannedPages: checkpointIR.skippedScannedPages,
                overlayFallbackPages: [],
                fallbackToSourceParagraphCount: 0,
                elapsedSeconds: 0,
                documentIR: checkpointIR
            )
        }
        guard let report = lastCompletionReport else { return }

        let jobConfig = TranslationJobConfiguration(
            sourceLanguage: Locale.Language(identifier: "en"),
            targetLanguage: Locale.Language(identifier: targetLanguageIdentifier),
            fontStyle: fontStyle,
            customFontPostScriptName: customFontPostScriptName.isEmpty ? nil : customFontPostScriptName,
            dualLayoutMode: dualLayoutMode,
            minFontScaleRatio: CGFloat(minFontScaleRatio),
            maxConcurrency: maxConcurrency
        )

        phase = .translating
        currentStage = .typesetting
        progressPage = report.totalPages
        progressTotalPages = report.totalPages
        progressFraction = 0.85

        activeTask?.cancel()
        activeTask = Task {
            do {
                let updatedReport = try await TranslationJob.retypesetDocument(
                    existingReport: report,
                    configuration: jobConfig
                )
                self.lastCompletionReport = updatedReport
                self.monoPDFURL = updatedReport.monoURL
                self.dualPDFURL = updatedReport.dualURL
                self.phase = .completed
            } catch {
                self.errorBannerMessage = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    // MARK: - Export & Finder Integration

    public func exportOutputPDF(preferDual: Bool = false) {
        guard let targetFile = preferDual ? (dualPDFURL ?? monoPDFURL) : (monoPDFURL ?? dualPDFURL) else {
            return
        }
        let savePanel = NSSavePanel()
        savePanel.title = preferDual ? "导出双语对照版 PDF" : "导出译文版 PDF"
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = targetFile.lastPathComponent
        if savePanel.runModal() == .OK, let dstURL = savePanel.url {
            do {
                if FileManager.default.fileExists(atPath: dstURL.path) {
                    try FileManager.default.removeItem(at: dstURL)
                }
                try FileManager.default.copyItem(at: targetFile, to: dstURL)
            } catch {
                errorBannerMessage = "导出文件失败：\(error.localizedDescription)"
            }
        }
    }

    public func revealInFinder() {
        if let monoPDFURL, let dualPDFURL {
            NSWorkspace.shared.activateFileViewerSelecting([monoPDFURL, dualPDFURL])
        } else if let monoPDFURL {
            NSWorkspace.shared.activateFileViewerSelecting([monoPDFURL])
        }
    }

    // MARK: - Engine Construction & Connection Test

    public func buildCurrentEngine() -> any TranslationEngine {
        switch selectedEngineKind {
        case .appleSystem:
            return AppleSystemTranslationEngine()
        case .deepseek, .siliconflow, .openai, .ollama:
            let requiresKey = (selectedEngineKind != .ollama)
            let config = OpenAICompatibleConfiguration(
                providerID: selectedEngineKind.rawValue,
                displayName: selectedEngineKind.displayName,
                baseURLString: customBaseURL,
                modelName: customModelName,
                requiresAPIKey: requiresKey
            )
            let key = currentAPIKey()
            return OpenAICompatibleEngine(configuration: config, apiKey: key)
        }
    }

    public func testCurrentEngineConnection() async {
        isTestingConnection = true
        connectionTestStatus = nil
        defer { isTestingConnection = false }

        do {
            let engine = buildCurrentEngine()
            let probe = TranslationUnit(text: "Hello {v1} world.")
            let results = try await engine.translate(
                [probe],
                from: Locale.Language(identifier: "en"),
                to: Locale.Language(identifier: targetLanguageIdentifier),
                glossary: []
            )
            let sample = results.first?.text ?? ""
            connectionTestStatus = "连接成功！测试输出：\(sample)"
        } catch {
            connectionTestStatus = "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Cache & Recent History Management

    public func refreshCacheCount() async {
        cachedEntryCount = await TranslationCache.shared.count()
    }

    public func clearTranslationCache() async {
        await TranslationCache.shared.clearAll()
        await refreshCacheCount()
    }

    private func recordRecentDocument(_ report: JobCompletionReport) {
        let entry = RecentDocumentRecord(
            fileName: report.sourceURL.lastPathComponent,
            sourcePath: report.sourceURL.path,
            monoPath: report.monoURL.path,
            dualPath: report.dualURL.path,
            pageCount: report.totalPages
        )
        recentDocuments.removeAll { $0.sourcePath == entry.sourcePath }
        recentDocuments.insert(entry, at: 0)
        if recentDocuments.count > 15 {
            recentDocuments = Array(recentDocuments.prefix(15))
        }
        if let data = try? JSONEncoder().encode(recentDocuments) {
            UserDefaults.standard.set(data, forKey: "history.recentDocs")
        }
    }

    private func loadRecentDocuments() {
        guard let data = UserDefaults.standard.data(forKey: "history.recentDocs"),
              let decoded = try? JSONDecoder().decode([RecentDocumentRecord].self, from: data) else {
            return
        }
        recentDocuments = decoded
    }

    public func openRecentRecord(_ record: RecentDocumentRecord) {
        let srcURL = URL(fileURLWithPath: record.sourcePath)
        let monoURL = URL(fileURLWithPath: record.monoPath)
        let dualURL = URL(fileURLWithPath: record.dualPath)

        if FileManager.default.fileExists(atPath: srcURL.path) &&
           FileManager.default.fileExists(atPath: monoURL.path) {
            sourcePDFURL = srcURL
            monoPDFURL = monoURL
            dualPDFURL = FileManager.default.fileExists(atPath: dualURL.path) ? dualURL : nil
            phase = .completed
        } else if FileManager.default.fileExists(atPath: srcURL.path) {
            handleIncomingURL(srcURL)
        } else {
            errorBannerMessage = "文件已被移动或删除：\(record.fileName)"
        }
    }

    public func revealRecentRecordInFinder(_ record: RecentDocumentRecord) {
        let monoURL = URL(fileURLWithPath: record.monoPath)
        let dualURL = URL(fileURLWithPath: record.dualPath)
        let srcURL = URL(fileURLWithPath: record.sourcePath)
        var urlsToSelect: [URL] = []
        if FileManager.default.fileExists(atPath: monoURL.path) { urlsToSelect.append(monoURL) }
        if FileManager.default.fileExists(atPath: dualURL.path) { urlsToSelect.append(dualURL) }
        if urlsToSelect.isEmpty, FileManager.default.fileExists(atPath: srcURL.path) {
            urlsToSelect.append(srcURL)
        }
        if !urlsToSelect.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urlsToSelect)
        }
    }

    public func clearRecentDocuments() {
        recentDocuments.removeAll()
        UserDefaults.standard.removeObject(forKey: "history.recentDocs")
    }
}
