<<<<<<< HEAD
# PDFTranslator
PDFTranslator for mac
=======
# PDFTranslator · 墨译

macOS 原生 PDF 保版式双语翻译应用，基于 Swift 6 / SwiftUI 开发。开发手册见 [`macos-pdf-translator-handbook.md`](./macos-pdf-translator-handbook.md)。

## 特性

- **不动原文**：原 PDF 只读打开，自动输出保留原版式的译文版（`-zh.pdf`）与双语对照版（`-dual.pdf`）。
- **七步版式保留管线**：解析 → 版面检测 → 段落组装 → 公式与样式保护 → AI 翻译调度 → 排版 → 写出。
- **多引擎支持**：Apple 系统翻译（免 Key 离线）、DeepSeek、硅基流动、OpenAI 兼容接口、Ollama 本地模型。
- **公式与版面保护**：数学公式、希腊字母、上下标自动识别为占位符，翻译后原样还原，不与译文混排。
- **SQLite 缓存**：段落级翻译缓存，相同段落秒级复用，默认 6 小时自动过期清理。
- **双窗格同步滚动**：原文 / 译文并排阅读，支持页码、缩放、滚动位置同步。
- **首次启动引导**：520×420 小窗口引导，拖入 PDF 或选择本地文件即可开始。

## 目录结构

```text
PDFTranslator/
├── Package.swift                # Swift 6 严格并发多模块配置
├── App/                         # macOS SwiftUI 主应用目标
│   ├── Features/                # Import · Reader · Settings
│   ├── Services/                # Keychain · Bookmark · Notification
│   ├── Info.plist
│   ├── PDFTranslator.entitlements
│   └── Resources/
│       ├── AppIcon.icns
│       └── Localizable.xcstrings
├── Packages/
│   ├── PDFTranslateKit/         # 七步管线与 DocumentIR（无 UI 依赖）
│   ├── TranslationEngines/      # 引擎实现、SQLite 缓存、并发调度
│   └── CPDFium/                 # PDFium xcframework 与 C 桥接
├── Tools/pdftranslate-cli/      # 命令行翻译工具
├── Scripts/                     # build-app.sh 与 build-dmg.sh 打包脚本
├── Tests/                       # Swift Testing 单元与端到端测试
├── Tests/Fixtures/              # 测试用例 PDF
├── build-app.sh / build-dmg.sh  # 打包脚本
└── README.md
```

## 构建与运行

### 先决条件

- macOS 15.0+
- Xcode 16+ / Swift 6.0+

### 1. 构建 macOS 原生应用

```bash
# 构建 Release 版
./Scripts/build-app.sh release

# 启动应用
open build/PDFTranslator.app
```

### 2. 生成 DMG 分发包

```bash
./Scripts/build-dmg.sh
# 输出：build/PDFTranslator-0.0.1.dmg
```

### 3. 命令行工具

```bash
swift build --build-system native --product pdftranslate-cli

# 翻译本地 PDF
.build/arm64-apple-macosx/debug/pdftranslate-cli <input.pdf> --engine apple

# 翻译 arXiv 链接
.build/arm64-apple-macosx/debug/pdftranslate-cli https://arxiv.org/abs/2311.09735 --engine deepseek
```

### 4. 运行测试套件

```bash
swift test --build-system native
```

## 缓存策略

翻译缓存存储于 `~/Library/Caches/com.pdftranslator.app/translation_cache.sqlite3`，默认 **6 小时后自动过期清理**。也可在“设置 → 缓存管理与开源致谢”中手动清空。

## 签名与公证

当前构建脚本使用 ad-hoc 签名（`codesign --sign -`）。如需提交 App Store 或分发给外部用户，需要：

1. Apple Developer 账号
2. 在 `Scripts/build-app.sh` 中替换为正式签名证书
3. 完成公证（Notarization）后再分发 DMG

## 贡献

欢迎提交 Issue 和 Pull Request。在提交代码前，请先运行 `swift test --build-system native` 确保测试通过。

## 许可证

[MIT License](LICENSE)
>>>>>>> 0067cad (chore: 初始化仓库，整理标准项目结构)
