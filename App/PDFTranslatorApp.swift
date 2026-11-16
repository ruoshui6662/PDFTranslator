import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Translation)
@preconcurrency import Translation
#endif
import PDFTranslateKit
import TranslationEngines

@main
struct PDFTranslatorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup(LocalizedStringResource("窗口标题", comment: "Window title")) {
            Group {
                if appState.isFirstLaunch {
                    FirstLaunchGuideView(appState: appState)
                } else {
                    MainContentView(appState: appState)
                }
            }
            .frame(minWidth: appState.isFirstLaunch ? 520 : 980, minHeight: appState.isFirstLaunch ? 420 : 660)
            .onAppear {
                // 确保窗口启动后出现在前台，避免用户需要去搜索才能找到软件
                NSApplication.shared.activate(ignoringOtherApps: true)
                // 首次启动时把窗口调整为引导窗尺寸，避免大窗口套小内容；否则调整为主内容尺寸
                DispatchQueue.main.async {
                    let target = appState.isFirstLaunch ? NSSize(width: 520, height: 420) : NSSize(width: 980, height: 660)
                    let window = NSApplication.shared.keyWindow
                        ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                        ?? NSApplication.shared.windows.first
                    guard let window else { return }
                    if appState.isFirstLaunch {
                        window.setContentSize(target)
                        window.minSize = target
                        window.maxSize = target
                    } else {
                        window.setContentSize(target)
                        window.minSize = NSSize(width: 700, height: 500)
                        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    }
                }
            }
            .onOpenURL { url in
                appState.handleIncomingURL(url)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(LocalizedStringResource("打开 PDF 文件…", comment: "Menu item")) {
                    appState.isShowingFileImporter = true
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(LocalizedStringResource("返回欢迎主页", comment: "Menu item")) {
                    appState.closeCurrentDocument()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState.phase == .empty)

                Button(LocalizedStringResource("粘贴 PDF 链接并翻译", comment: "Menu item")) {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        appState.urlInputString = pasted
                        appState.submitURLInput()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button(LocalizedStringResource("导出译文版 PDF (-zh.pdf)…", comment: "Menu item")) {
                    appState.exportOutputPDF(preferDual: false)
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(appState.monoPDFURL == nil)

                Button(LocalizedStringResource("导出双语对照版 PDF (-dual.pdf)…", comment: "Menu item")) {
                    appState.exportOutputPDF(preferDual: true)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.dualPDFURL == nil)
            }

            CommandGroup(after: .appInfo) {
                Button(LocalizedStringResource("开源致谢与许可证 (Acknowledgments)…", comment: "Menu item")) {
                    appState.isShowingAcknowledgments = true
                }
            }
        }

        Settings {
            SettingsView(appState: appState)
        }
    }
}

struct MainContentView: View {
    @Bindable var appState: AppState

    private var targetLanguageShortLabel: String {
        switch appState.targetLanguageIdentifier {
        case "zh-Hans": return "简中"
        case "zh-Hant": return "繁中"
        case "ja": return "日本語"
        case "en": return "EN"
        default: return "简中"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. 统一顶栏
            unifiedTopHeaderBar
            Divider()

            // 2. 错误提示横幅
            if let errorMessage = appState.errorBannerMessage {
                errorBanner(message: errorMessage)
                Divider()
            }

            // 3. 主内容区
            switch appState.phase {
            case .empty:
                ImportEmptyStateView(appState: appState)
            case .translating, .completed, .failed:
                SynchronizedPDFComparisonView(appState: appState)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowTrafficLightsConfigurator())
        .fileImporter(
            isPresented: $appState.isShowingFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                _ = first.startAccessingSecurityScopedResource()
                appState.handleIncomingURL(first)
            }
        }
        .sheet(isPresented: $appState.isShowingPasswordPrompt) {
            passwordPromptSheet
        }
        .sheet(isPresented: $appState.isShowingAcknowledgments) {
            AcknowledgmentsSheet()
        }
        .alert(LocalizedStringResource("云端翻译隐私提示", comment: "Alert title"), isPresented: $appState.isShowingCloudPrivacyNotice) {
            Button(LocalizedStringResource("同意并继续翻译", comment: "Alert action")) {
                appState.confirmCloudPrivacyAndContinue()
            }
            Button(LocalizedStringResource("取消", comment: "Alert cancel"), role: .cancel) {
                appState.pendingTranslationURLAfterPrivacy = nil
            }
        } message: {
            Text(LocalizedStringResource("文档文字将直接发送到你配置的翻译服务商（\(appState.selectedEngineKind.displayName)）。本应用自身不设任何中转服务器，不收集或存储你的文档内容。", comment: "Alert message"))
        }
        .modifier(AppleTranslationTaskModifier(targetLanguageIdentifier: appState.targetLanguageIdentifier))
    }

    // MARK: - 错误横幅（失败时红色，普通时橙色）

    @ViewBuilder
    private func errorBanner(message: String) -> some View {
        let isFailure = appState.phase == .failed
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
            HStack(spacing: DesignSpacing.md) {
                Image(systemName: isFailure ? "exclamationmark.icloud.fill" : "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(isFailure ? DesignColor.error : DesignColor.warning)
                Text(message)
                    .font(DesignType.body)
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
                if message.contains("设置") || message.contains("Key") || message.contains("引擎") {
                    SettingsLink {
                        Text(LocalizedStringResource("打开设置", comment: "Button label"))
                            .font(DesignType.captionMedium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    appState.errorBannerMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .pressable()
            }
            if isFailure, let src = appState.sourcePDFURL {
                HStack {
                    Spacer()
                    Button(LocalizedStringResource("重试翻译", comment: "Button label")) {
                        appState.startTranslation(for: src)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pressable()
                }
            }
        }
        .padding(.horizontal, DesignSpacing.lg)
        .padding(.vertical, DesignSpacing.md)
        .background((isFailure ? DesignColor.error : DesignColor.warning).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        .padding(.horizontal, DesignSpacing.lg)
    }

    // MARK: - 统一顶栏（三区布局：左导航 / 中状态 / 右操作）

    private var unifiedTopHeaderBar: some View {
        HStack(spacing: 0) {
            // Zone 1 (Left): 导航与导入 —— 固定宽度，优先布局
            leftNavigationZone
                .layoutPriority(1)

            Spacer(minLength: 0)

            // Zone 2 (Center): 阅读模式切换 或 应用标题
            centerZone

            Spacer(minLength: 0)

            // Zone 3 (Right): 操作图标菜单 —— 固定宽度，右对齐
            rightActionZone
                .layoutPriority(1)
        }
        .padding(.leading, 96)
        .padding(.trailing, DesignSpacing.lg)
        .frame(height: 46)
        .background(DesignColor.backgroundWindow)
    }

    // MARK: - Zone 1: 左导航与导入（紧凑图标按钮）

    @ViewBuilder
    private var leftNavigationZone: some View {
        HStack(spacing: DesignSpacing.sm) {
            if appState.phase != .empty {
                Button {
                    appState.closeCurrentDocument()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                        .frame(width: 30, height: 30)
                        .toolbarControlStyle()
                }
                .buttonStyle(.plain)
                .help(LocalizedStringResource("返回欢迎主页 (⇧⌘W)", comment: "Tooltip"))
                .pressable()
            }

            Button {
                appState.isShowingFileImporter = true
            } label: {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                    .frame(width: 30, height: 30)
                    .toolbarControlStyle()
            }
            .buttonStyle(.plain)
            .help(LocalizedStringResource("导入本地 PDF 文档进行翻译 (⌘O)", comment: "Tooltip"))
            .pressable()
        }
    }

    // MARK: - Zone 2: 中间状态（阅读模式切换 / 应用标题）

    @ViewBuilder
    private var centerZone: some View {
        if appState.phase != .empty {
            HStack(spacing: DesignSpacing.xs) {
                ForEach(ReaderViewMode.allCases) { mode in
                    let isSelected = (appState.readerViewMode == mode)
                    Button {
                        withAnimation(DesignAnimation.quick) {
                            appState.readerViewMode = mode
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? DesignColor.textPrimary : DesignColor.textSecondary)
                            .frame(width: 66, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                                    .fill(isSelected ? DesignColor.backgroundApp : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .pressable()
                }
            }
            .padding(DesignSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(DesignColor.textPrimary.opacity(0.05))
            )
        } else {
            Text(LocalizedStringResource("PDF 保版式双语翻译", comment: "App title in empty state"))
                .font(DesignType.bodyMedium)
                .foregroundStyle(DesignColor.textSecondary)
        }
    }

    // MARK: - Zone 3: 右侧操作图标菜单

    @ViewBuilder
    private var rightActionZone: some View {
        HStack(spacing: DesignSpacing.sm) {
            // 1. 翻译引擎与目标语言
            Menu {
                Section(LocalizedStringResource("当前翻译引擎", comment: "Menu section")) {
                    Picker(LocalizedStringResource("翻译引擎", comment: "Picker label"), selection: $appState.selectedEngineKind) {
                        ForEach(SelectedEngineKind.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                }

                Section(LocalizedStringResource("目标语言", comment: "Menu section")) {
                    Picker(LocalizedStringResource("目标语言", comment: "Picker label"), selection: $appState.targetLanguageIdentifier) {
                        Text(LocalizedStringResource("简体中文", comment: "Language option")).tag("zh-Hans")
                        Text(LocalizedStringResource("繁體中文", comment: "Language option")).tag("zh-Hant")
                        Text(LocalizedStringResource("日本語", comment: "Language option")).tag("ja")
                        Text(LocalizedStringResource("English", comment: "Language option")).tag("en")
                    }
                }

                if appState.phase == .completed {
                    Divider()
                    Button {
                        appState.retranslateCurrentPage()
                    } label: {
                        Label("重新翻译当前页（第 \(appState.currentPageIndex + 1) 页）", systemImage: "arrow.clockwise")
                    }

                    if let src = appState.sourcePDFURL {
                        Button {
                            appState.startTranslation(for: src)
                        } label: {
                            Label(LocalizedStringResource("重新翻译整篇文档", comment: "Menu item"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
            } label: {
                Image(systemName: "translate")
                    .toolbarIconStyle()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(LocalizedStringResource("翻译引擎与目标语言（当前：\(appState.selectedEngineKind.shortDisplayName) · \(targetLanguageShortLabel)）", comment: "Tooltip"))

            // 2. 译文字体与版式
            Menu {
                Section(LocalizedStringResource("推荐译文字体与排版样式", comment: "Menu section")) {
                    ForEach(CJKFontStyle.allCases) { style in
                        Button {
                            appState.customFontPostScriptName = ""
                            appState.fontStyle = style
                        } label: {
                            HStack {
                                Text(style.displayName)
                                if appState.customFontPostScriptName.isEmpty && appState.fontStyle == style {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                if !SystemFontCatalog.installedCJKFonts.isEmpty {
                    Menu(LocalizedStringResource("更多本机已安装中文字体 (\(SystemFontCatalog.installedCJKFonts.count) 款)", comment: "Menu item")) {
                        ForEach(SystemFontCatalog.installedCJKFonts) { item in
                            Button {
                                appState.customFontPostScriptName = item.postScriptName
                            } label: {
                                HStack {
                                    Text("\(item.displayName) (\(item.postScriptName))")
                                    if appState.customFontPostScriptName == item.postScriptName {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                Section(LocalizedStringResource("双语对照版式 (-dual.pdf)", comment: "Menu section")) {
                    Picker(LocalizedStringResource("双语对照版式", comment: "Picker label"), selection: $appState.dualLayoutMode) {
                        ForEach(DualLayoutMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            } label: {
                Image(systemName: "textformat")
                    .toolbarIconStyle()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(LocalizedStringResource("选择译文字体与版式（当前：\(appState.customFontPostScriptName.isEmpty ? appState.fontStyle.shortName : appState.customFontPostScriptName)）", comment: "Tooltip"))

            // 3. 导出与分享
            let canExport = (appState.monoPDFURL != nil)
            Menu {
                Button {
                    appState.revealInFinder()
                } label: {
                    Label(LocalizedStringResource("在访达 (Finder) 中显示输出文件", comment: "Menu item"), systemImage: "folder")
                }

                Divider()

                Button {
                    appState.exportOutputPDF(preferDual: false)
                } label: {
                    Label(LocalizedStringResource("另存纯译文版 PDF (-zh.pdf)…", comment: "Menu item"), systemImage: "doc.text")
                }

                Button {
                    appState.exportOutputPDF(preferDual: true)
                } label: {
                    Label(LocalizedStringResource("另存双语对照版 PDF (-dual.pdf)…", comment: "Menu item"), systemImage: "rectangle.split.2x1")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .toolbarIconStyle(prominent: canExport, isDisabled: !canExport)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!canExport)
            .help(canExport ? LocalizedStringResource("导出译文版、双语对照版或在访达中定位文件 (⌘E)", comment: "Tooltip") : LocalizedStringResource("导入并完成翻译后即可导出 PDF", comment: "Tooltip"))

            // 4. 设置
            SettingsLink {
                Image(systemName: "gearshape")
                    .toolbarIconStyle()
            }
            .buttonStyle(.plain)
            .help(LocalizedStringResource("打开偏好设置 (⌘,)", comment: "Tooltip"))
        }
    }

    // MARK: - 密码输入弹窗

    private var passwordPromptSheet: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            HStack(spacing: DesignSpacing.md) {
                Image(systemName: "lock.doc.fill")
                    .font(.title2)
                    .foregroundStyle(DesignColor.brand)
                Text(LocalizedStringResource("该 PDF 文档受密码保护", comment: "Sheet title"))
                    .font(.headline.weight(.semibold))
            }
            Text(LocalizedStringResource("请输入打开密码以解析并翻译该文档（密码仅在本次内存解析中使用，不会保存）：", comment: "Sheet hint"))
                .font(DesignType.body)
                .foregroundStyle(DesignColor.textSecondary)
            SecureField(LocalizedStringResource("输入 PDF 密码", comment: "Placeholder"), text: $appState.pendingPasswordInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitPassword()
                }
            HStack {
                Spacer()
                Button(LocalizedStringResource("取消", comment: "Button label")) {
                    appState.isShowingPasswordPrompt = false
                    appState.pendingPasswordInput = ""
                }
                .buttonStyle(.plain)
                .pressable()
                Button(LocalizedStringResource("解锁并翻译", comment: "Button label")) {
                    submitPassword()
                }
                .buttonStyle(.borderedProminent)
                .pressable()
            }
            .padding(.top, DesignSpacing.xs)
        }
        .padding(DesignSpacing.xl)
        .frame(width: 380)
        .background(DesignColor.backgroundWindow)
    }

    private func submitPassword() {
        let pwd = appState.pendingPasswordInput
        appState.isShowingPasswordPrompt = false
        appState.pendingPasswordInput = ""
        if let src = appState.sourcePDFURL {
            appState.startTranslation(for: src, password: pwd)
        }
    }
}

/// 确保 macOS 窗口交通灯按钮（关闭、最小化、缩放）始终可见，并与自定义 46pt 顶栏无缝集成。
struct WindowTrafficLightsConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(nsView.window)
        }
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}

/// 桥接 SwiftUI 的 `.translationTask` 会话到 `SystemTranslationSessionCoordinator.shared`
struct AppleTranslationTaskModifier: ViewModifier {
    let targetLanguageIdentifier: String

    func body(content: Content) -> some View {
        #if canImport(Translation)
        content.translationTask(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: targetLanguageIdentifier)
        ) { session in
            try? await session.prepareTranslation()
            await SystemTranslationSessionCoordinator.shared.registerHandler { strings, _, _ in
                let requests = strings.enumerated().map { idx, text in
                    TranslationSession.Request(sourceText: text, clientIdentifier: "\(idx)")
                }
                let responses = try await session.translations(from: requests)
                var ordered = Array(repeating: "", count: strings.count)
                for (idx, resp) in responses.enumerated() {
                    if let cid = resp.clientIdentifier, let origIdx = Int(cid), origIdx >= 0, origIdx < ordered.count {
                        ordered[origIdx] = resp.targetText
                    } else if idx < ordered.count {
                        ordered[idx] = resp.targetText
                    }
                }
                for i in 0..<ordered.count where ordered[i].isEmpty {
                    ordered[i] = strings[i]
                }
                return ordered
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        #else
        content
        #endif
    }
}
