import SwiftUI
import PDFTranslateKit
import TranslationEngines
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var apiKeyInput: String = ""
    @State private var isRevealingAPIKey: Bool = false
    @State private var isImportingCSV: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        TabView {
            translationServiceTab
                .tabItem {
                    Label(LocalizedStringResource("翻译服务", comment: "Settings tab 1 title"), systemImage: "sparkles")
                }

            outputSettingsTab
                .tabItem {
                    Label(LocalizedStringResource("输出与版式", comment: "Settings tab 2 title"), systemImage: "doc.richtext")
                }

            advancedSettingsTab
                .tabItem {
                    Label(LocalizedStringResource("词库与高级", comment: "Settings tab 3 title"), systemImage: "slider.horizontal.3")
                }
        }
        .frame(width: 680, height: 560)
        .onAppear {
            apiKeyInput = appState.currentAPIKey()
            Task {
                await appState.refreshCacheCount()
            }
        }
        .onChange(of: appState.selectedEngineKind) { _, _ in
            apiKeyInput = appState.currentAPIKey()
            appState.connectionTestStatus = nil
        }
    }

    // MARK: - Tab 1: 翻译服务

    private var translationServiceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.lg) {
                // 1. Engine Selection Card Grid
                settingsCard(
                    title: LocalizedStringResource("翻译引擎与目标语言", comment: "Card title"),
                    subtitle: LocalizedStringResource("选择本地免配置神经翻译或高性价比大模型服务", comment: "Card subtitle"),
                    icon: "globe"
                ) {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: DesignSpacing.sm),
                                GridItem(.flexible(), spacing: DesignSpacing.sm)
                            ],
                            spacing: DesignSpacing.sm
                        ) {
                            ForEach(SelectedEngineKind.allCases) { kind in
                                engineSelectionCard(for: kind)
                            }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("默认目标语言", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                    .foregroundStyle(DesignColor.textPrimary)
                                Text(LocalizedStringResource("文档翻译后的输出语言", comment: "Hint text"))
                                    .font(DesignType.smallCaption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            Picker("", selection: $appState.targetLanguageIdentifier) {
                                Text(LocalizedStringResource("简体中文 (zh-Hans)", comment: "Language option")).tag("zh-Hans")
                                Text(LocalizedStringResource("繁體中文 (zh-Hant)", comment: "Language option")).tag("zh-Hant")
                                Text(LocalizedStringResource("日本語 (ja)", comment: "Language option")).tag("ja")
                                Text(LocalizedStringResource("English (en)", comment: "Language option")).tag("en")
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                    }
                }

                // 2. Model & Credentials Card (or Apple System Offline Card)
                if appState.selectedEngineKind == .appleSystem {
                    settingsCard(
                        title: LocalizedStringResource("本机离线神经翻译", comment: "Card title"),
                        subtitle: LocalizedStringResource("零配置 · 免费无限制 · 隐私不出本机", comment: "Card subtitle"),
                        icon: "checkmark.shield.fill"
                    ) {
                        HStack(alignment: .top, spacing: DesignSpacing.md) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(DesignColor.brand)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                                        .fill(DesignColor.brand.opacity(0.12))
                                )

                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("已启用 macOS 原生系统翻译 + 学术离线语料引擎", comment: "Body text"))
                                    .font(DesignType.bodyMedium)
                                Text(LocalizedStringResource("无需填写任何 API Key，所有段落、数学公式保护与版面重构均在本地 Apple Silicon 芯片上完成，文档内容绝不上传云端。", comment: "Body text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                } else {
                    settingsCard(
                        title: LocalizedStringResource("\(appState.selectedEngineKind.shortDisplayName) 模型与接口配置", comment: "Engine card title"),
                        subtitle: LocalizedStringResource(stringLiteral: appState.selectedEngineKind.subtitle),
                        icon: "cpu"
                    ) {
                        VStack(alignment: .leading, spacing: DesignSpacing.md) {
                            // Base URL row
                            HStack {
                                Text(LocalizedStringResource("接口地址 (Base URL)", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                    .frame(width: 136, alignment: .leading)
                                TextField("https://api.deepseek.com/v1", text: $appState.customBaseURL)
                                    .textFieldStyle(.plain)
                                    .font(DesignType.body)
                                    .inputContainerStyle()
                            }

                            // Model row + Quick Preset Chips
                            VStack(alignment: .leading, spacing: DesignSpacing.sm) {
                                HStack {
                                    Text(LocalizedStringResource("模型名称 (Model)", comment: "Label"))
                                        .font(DesignType.captionMedium)
                                        .frame(width: 136, alignment: .leading)
                                    TextField("deepseek-v4.1-flash", text: $appState.customModelName)
                                        .textFieldStyle(.plain)
                                        .font(DesignType.body)
                                        .inputContainerStyle()
                                }

                                let presets = appState.selectedEngineKind.recommendedModels
                                if !presets.isEmpty {
                                    HStack(spacing: DesignSpacing.xs) {
                                        Text(LocalizedStringResource("快速切换推荐模型：", comment: "Label"))
                                            .font(DesignType.caption)
                                            .foregroundStyle(DesignColor.textSecondary)
                                            .frame(width: 130, alignment: .leading)

                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: DesignSpacing.xs) {
                                                ForEach(presets, id: \.id) { preset in
                                                    let isCurrent = (appState.customModelName == preset.id)
                                                    Button {
                                                        appState.customModelName = preset.id
                                                    } label: {
                                                        HStack(spacing: DesignSpacing.xs) {
                                                            if isCurrent {
                                                                Image(systemName: "checkmark.circle.fill")
                                                                    .font(.system(size: 10))
                                                            }
                                                            Text(preset.label)
                                                                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                                        }
                                                        .padding(.horizontal, DesignSpacing.sm)
                                                        .padding(.vertical, DesignSpacing.xs)
                                                        .foregroundStyle(isCurrent ? DesignColor.brand : DesignColor.textPrimary)
                                                        .background(
                                                            Capsule()
                                                                .fill(isCurrent ? DesignColor.brand.opacity(0.14) : DesignColor.textPrimary.opacity(0.06))
                                                        )
                                                        .overlay(
                                                            Capsule()
                                                                .strokeBorder(isCurrent ? DesignColor.brand.opacity(0.45) : Color.clear, lineWidth: 1)
                                                        )
                                                    }
                                                    .buttonStyle(.plain)
                                                    .pressable()
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // API Key row
                            if appState.selectedEngineKind != .ollama {
                                Divider()
                                HStack {
                                    VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                        Text(LocalizedStringResource("API 密钥 (Keychain)", comment: "Label"))
                                            .font(DesignType.captionMedium)
                                        Text(LocalizedStringResource("加密存储于 macOS 钥匙串", comment: "Hint text"))
                                            .font(DesignType.smallCaption)
                                            .foregroundStyle(DesignColor.textSecondary)
                                    }
                                    .frame(width: 136, alignment: .leading)

                                    HStack(spacing: DesignSpacing.xs) {
                                        Group {
                                            if isRevealingAPIKey {
                                                TextField("sk-...", text: $apiKeyInput)
                                            } else {
                                                SecureField(LocalizedStringResource("输入 API Key（例如 sk-...）", comment: "Placeholder"), text: $apiKeyInput)
                                            }
                                        }
                                        .textFieldStyle(.plain)
                                        .font(DesignType.body)
                                        .inputContainerStyle()
                                        .onChange(of: apiKeyInput) { _, newValue in
                                            appState.saveCurrentAPIKey(newValue)
                                        }

                                        Button {
                                            isRevealingAPIKey.toggle()
                                        } label: {
                                            Image(systemName: isRevealingAPIKey ? "eye.slash" : "eye")
                                                .font(.system(size: 12))
                                                .foregroundStyle(DesignColor.textSecondary)
                                                .frame(width: 26, height: 24)
                                        }
                                        .buttonStyle(.bordered)
                                        .help(LocalizedStringResource(isRevealingAPIKey ? "隐藏密钥" : "显示密钥", comment: "Tooltip"))
                                        .pressable()
                                    }
                                }
                            } else {
                                HStack(spacing: DesignSpacing.sm) {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundStyle(DesignColor.textSecondary)
                                    Text(LocalizedStringResource("Ollama 默认连接本机 http://localhost:11434/v1，文档不出本机，无需填写 API Key。", comment: "Hint text"))
                                        .font(DesignType.caption)
                                        .foregroundStyle(DesignColor.textSecondary)
                                }
                            }
                        }
                    }
                }

                // 3. Concurrency & Connection Test Card
                settingsCard(
                    title: LocalizedStringResource("并发性能与连通性检测", comment: "Card title"),
                    subtitle: LocalizedStringResource("控制并发请求线程数并验证当前翻译引擎是否可用", comment: "Card subtitle"),
                    icon: "bolt.horizontal.circle"
                ) {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("并发翻译请求上限", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                Text(LocalizedStringResource("较高并发可显著加快长篇论文翻译速度", comment: "Hint text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            HStack(spacing: DesignSpacing.md) {
                                Text("\(appState.maxConcurrency) 线程")
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(DesignColor.brand)
                                    .padding(.horizontal, DesignSpacing.md)
                                    .padding(.vertical, DesignSpacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                                            .fill(DesignColor.brand.opacity(0.12))
                                    )
                                Stepper("", value: $appState.maxConcurrency, in: 1...12)
                                    .labelsHidden()
                            }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("服务连通性检测", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                if let status = appState.connectionTestStatus {
                                    HStack(spacing: DesignSpacing.xs) {
                                        Image(systemName: status.contains("成功") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        Text(status)
                                            .lineLimit(1)
                                    }
                                    .font(DesignType.caption)
                                    .foregroundStyle(status.contains("成功") ? DesignColor.success : DesignColor.error)
                                } else {
                                    Text(LocalizedStringResource("发送一条带公式占位符 {v1} 的测试语句验证引擎响应", comment: "Hint text"))
                                        .font(DesignType.caption)
                                        .foregroundStyle(DesignColor.textSecondary)
                                }
                            }

                            Spacer()

                            Button {
                                Task {
                                    await appState.testCurrentEngineConnection()
                                }
                            } label: {
                                if appState.isTestingConnection {
                                    HStack(spacing: DesignSpacing.xs) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text(LocalizedStringResource("正在测试…", comment: "Button label"))
                                    }
                                } else {
                                    Label(LocalizedStringResource("测试连接", comment: "Button label"), systemImage: "bolt.horizontal.fill")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(appState.isTestingConnection)
                            .pressable()
                        }
                    }
                }
            }
            .padding(DesignSpacing.lg)
        }
    }

    // MARK: - Tab 2: 输出与版式

    private var outputSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.lg) {
                // 1. Font & Typography Card
                settingsCard(
                    title: LocalizedStringResource("译文字体与排版样式", comment: "Card title"),
                    subtitle: LocalizedStringResource("直接调用 macOS 系统与本机已安装字体（含思源宋体、思源黑体等），零体积膨胀并自动子集化", comment: "Card subtitle"),
                    icon: "textformat"
                ) {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("推荐译文字体方案", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                Text(LocalizedStringResource("默认智能识别原文衬线/无衬线与加粗样式，标题用思源黑体、正文用思源宋体", comment: "Hint text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            Picker("", selection: $appState.fontStyle) {
                                ForEach(CJKFontStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }

                        if !SystemFontCatalog.installedCJKFonts.isEmpty {
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                    Text(LocalizedStringResource("自选本机已安装中文字体", comment: "Label"))
                                        .font(DesignType.captionMedium)
                                    Text(LocalizedStringResource("已自动扫描到本机 \(SystemFontCatalog.installedCJKFonts.count) 款可用中文字体", comment: "Hint text"))
                                        .font(DesignType.caption)
                                        .foregroundStyle(DesignColor.textSecondary)
                                }
                                Spacer()
                                Picker("", selection: $appState.customFontPostScriptName) {
                                    Text(LocalizedStringResource("跟随上方推荐方案（\(appState.fontStyle.shortName)）", comment: "Picker option")).tag("")
                                    Divider()
                                    ForEach(SystemFontCatalog.installedCJKFonts) { item in
                                        Text("\(item.displayName) (\(item.postScriptName))").tag(item.postScriptName)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 250)
                            }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("双语对照版式 (-dual.pdf)", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                Text(LocalizedStringResource("控制导出的双语对照 PDF 页面拼接方式", comment: "Hint text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            Picker("", selection: $appState.dualLayoutMode) {
                                ForEach(DualLayoutMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("自适应排版最小字号比例", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                Text(LocalizedStringResource("当译文较长时按阶梯微调行距与字号，防止双栏段落重叠", comment: "Hint text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            HStack(spacing: DesignSpacing.md) {
                                Slider(value: $appState.minFontScaleRatio, in: 0.45...0.90, step: 0.05)
                                    .frame(width: 170)
                                Text("\(Int(round(appState.minFontScaleRatio * 100)))%")
                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(DesignColor.brand)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }

                // 2. File Export Location Card
                settingsCard(
                    title: LocalizedStringResource("输出文件保存位置", comment: "Card title"),
                    subtitle: LocalizedStringResource("软件始终只读解析原 PDF 文档，绝不修改或覆盖你的源文件", comment: "Card subtitle"),
                    icon: "folder.badge.gearshape"
                ) {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        Picker(LocalizedStringResource("保存位置策略", comment: "Picker label"), selection: $appState.saveNextToSourceFile) {
                            Text(LocalizedStringResource("与原 PDF 相同文件夹（自动生成 -zh.pdf 与 -dual.pdf）", comment: "Picker option")).tag(true)
                            Text(LocalizedStringResource("统一保存到指定文件夹", comment: "Picker option")).tag(false)
                        }
                        .pickerStyle(.radioGroup)

                        if !appState.saveNextToSourceFile {
                            Divider()
                            HStack(spacing: DesignSpacing.md) {
                                Text(LocalizedStringResource("目标文件夹", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                TextField("未选择文件夹", text: $appState.customOutputDirectoryPath)
                                    .textFieldStyle(.plain)
                                    .font(DesignType.body)
                                    .inputContainerStyle()
                                Button(LocalizedStringResource("选择文件夹…", comment: "Button label")) {
                                    let initial = URL(fileURLWithPath: appState.customOutputDirectoryPath.isEmpty ? NSHomeDirectory() : appState.customOutputDirectoryPath)
                                    if let chosen = BookmarkService.shared.promptForDirectoryAuthorization(initialDirectory: initial) {
                                        appState.customOutputDirectoryPath = chosen.path
                                    }
                                }
                                .secondaryButtonStyle(width: nil, height: 32)
                                .pressable()
                            }
                        }
                    }
                }
            }
            .padding(DesignSpacing.lg)
        }
    }

    // MARK: - Tab 3: 词库与高级

    private var advancedSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.lg) {
                // 1. Glossary Card
                settingsCard(
                    title: LocalizedStringResource("自定义专业术语表 (Glossary)", comment: "Card title"),
                    subtitle: LocalizedStringResource("在翻译提示词与离线引擎中强制固定专业词汇译法", comment: "Card subtitle"),
                    icon: "character.book.closed"
                ) {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        HStack {
                            Text(LocalizedStringResource("每行一条术语映射，格式：`英文术语,中文译名`", comment: "Hint text"))
                                .font(DesignType.caption)
                                .foregroundStyle(DesignColor.textSecondary)
                            Spacer()
                            Button {
                                isImportingCSV = true
                            } label: {
                                Label(LocalizedStringResource("导入 CSV 词库…", comment: "Button label"), systemImage: "square.and.arrow.down")
                            }
                            .controlSize(.small)
                            .secondaryButtonStyle(width: nil, height: 32)
                            .pressable()
                        }

                        TextEditor(text: $appState.glossaryCSVText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                            .padding(DesignSpacing.sm)
                            .background(DesignColor.backgroundInput)
                            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                    .strokeBorder(DesignColor.border, lineWidth: 1)
                            )
                    }
                }

                // 2. FormulaGuard Card
                settingsCard(
                    title: LocalizedStringResource("公式与符号无损保护 (FormulaGuard)", comment: "Card title"),
                    subtitle: LocalizedStringResource("命中数学字体、希腊字母、运算符号或上下标几何特征的字符将自动转为 {vN} 占位符并保留原始字形", comment: "Card subtitle"),
                    icon: "function"
                ) {
                    HStack {
                        Text(LocalizedStringResource("数学字体匹配规则", comment: "Label"))
                            .font(DesignType.captionMedium)
                            .frame(width: 130, alignment: .leading)
                        TextField("CMMI, CMSY, CMEX, MSBM, Symbol, Math", text: $appState.customMathFontRegexesText)
                            .textFieldStyle(.plain)
                            .font(DesignType.body)
                            .inputContainerStyle()
                    }
                }

                // 3. Cache & Acknowledgments Card
                settingsCard(
                    title: LocalizedStringResource("缓存管理与开源致谢", comment: "Card title"),
                    subtitle: LocalizedStringResource("管理本地 SQLite 段落级翻译缓存与查看第三方开源组件许可", comment: "Card subtitle"),
                    icon: "internaldrive"
                ) {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("SQLite 本地译文缓存", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                Text(LocalizedStringResource("相同段落重复翻译或切换字体时可直接秒级复用", comment: "Hint text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            HStack(spacing: DesignSpacing.md) {
                                Text("已缓存 \(appState.cachedEntryCount) 条段落")
                                    .font(DesignType.captionMedium)
                                    .foregroundStyle(DesignColor.textSecondary)
                                Button(LocalizedStringResource("清空缓存", comment: "Button label"), role: .destructive) {
                                    Task {
                                        await appState.clearTranslationCache()
                                    }
                                }
                                .secondaryButtonStyle(width: nil, height: 32)
                                .pressable()
                            }
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                                Text(LocalizedStringResource("开源许可与致谢", comment: "Label"))
                                    .font(DesignType.captionMedium)
                                Text(LocalizedStringResource("PDFium、CoreText 及相关开源项目许可证声明", comment: "Hint text"))
                                    .font(DesignType.caption)
                                    .foregroundStyle(DesignColor.textSecondary)
                            }
                            Spacer()
                            Button(LocalizedStringResource("查看开源组件许可证…", comment: "Button label")) {
                                appState.isShowingAcknowledgments = true
                            }
                            .secondaryButtonStyle(width: nil, height: 32)
                            .pressable()
                        }
                    }
                }
            }
            .padding(DesignSpacing.lg)
        }
        .fileImporter(
            isPresented: $isImportingCSV,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                if let str = try? String(contentsOf: url, encoding: .utf8) {
                    appState.glossaryCSVText = str
                }
            }
        }
    }

    // MARK: - Reusable Card Components

    private func engineSelectionCard(for kind: SelectedEngineKind) -> some View {
        let isSelected = (appState.selectedEngineKind == kind)
        return Button {
            withAnimation(DesignAnimation.quick) {
                appState.selectedEngineKind = kind
            }
        } label: {
            HStack(spacing: DesignSpacing.md) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : DesignColor.brand)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                            .fill(isSelected ? DesignColor.brand : DesignColor.brand.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                    HStack(spacing: DesignSpacing.xs) {
                        Text(kind.shortDisplayName)
                            .font(DesignType.bodyMedium)
                            .foregroundStyle(DesignColor.textPrimary)
                        if kind == .deepseek {
                            Text("V4.1 Flash")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(DesignColor.brand)
                                .padding(.horizontal, DesignSpacing.sm)
                                .padding(.vertical, DesignSpacing.xs)
                                .background(
                                    Capsule()
                                        .fill(DesignColor.brand.opacity(0.14))
                                )
                        } else if kind == .appleSystem {
                            Text("免 Key")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(DesignColor.success)
                                .padding(.horizontal, DesignSpacing.sm)
                                .padding(.vertical, DesignSpacing.xs)
                                .background(
                                    Capsule()
                                        .fill(DesignColor.success.opacity(0.14))
                                )
                        }
                    }
                    Text(kind.subtitle)
                        .font(DesignType.smallCaption)
                        .foregroundStyle(DesignColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? DesignColor.brand : DesignColor.textTertiary)
            }
            .padding(DesignSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                    .fill(isSelected ? DesignColor.brand.opacity(0.08) : DesignColor.backgroundInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? DesignColor.brand : DesignColor.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pressable()
    }

    private func settingsCard<Content: View>(
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
            HStack(spacing: DesignSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignColor.brand)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                            .fill(DesignColor.brand.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                    Text(title)
                        .font(DesignType.bodyMedium)
                    Text(subtitle)
                        .font(DesignType.smallCaption)
                        .foregroundStyle(DesignColor.textSecondary)
                }
                Spacer()
            }

            Divider()

            content()
        }
        .padding(DesignSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .fill(DesignColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .strokeBorder(DesignColor.border, lineWidth: 1)
        )
        .shadow(color: DesignShadow.card, radius: 8, x: 0, y: 2)
    }
}
