import AppKit
import PDFKit
import SwiftUI

/// Coordinates scroll position, page selection, and zoom scale between two `PDFView` instances.
@MainActor
public final class PDFSyncCoordinator: NSObject {
    public weak var leftPDFView: PDFView?
    public weak var rightPDFView: PDFView?
    private var isSyncing: Bool = false
    public var onPageChanged: ((Int) -> Void)?

    public func attach(left: PDFView, right: PDFView) {
        self.leftPDFView = left
        self.rightPDFView = right

        NotificationCenter.default.removeObserver(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: left
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: right
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: left
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: right
        )

        observeScrollBounds(for: left)
        observeScrollBounds(for: right)
    }

    private func observeScrollBounds(for pdfView: PDFView) {
        guard let scrollView = pdfView.enclosingScrollView ?? findScrollView(in: pdfView) else {
            return
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    @objc private func handlePageChanged(_ notification: Notification) {
        guard !isSyncing,
              let sourceView = notification.object as? PDFView,
              let currentPage = sourceView.currentPage,
              let srcDoc = sourceView.document else {
            return
        }
        let pageIdx = srcDoc.index(for: currentPage)
        onPageChanged?(pageIdx)

        let targetView = (sourceView === leftPDFView) ? rightPDFView : leftPDFView
        guard let targetView,
              let dstDoc = targetView.document,
              pageIdx >= 0,
              pageIdx < dstDoc.pageCount,
              let dstPage = dstDoc.page(at: pageIdx) else {
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        if targetView.currentPage !== dstPage {
            targetView.go(to: dstPage)
        }
    }

    @objc private func handleScaleChanged(_ notification: Notification) {
        guard !isSyncing,
              let sourceView = notification.object as? PDFView else {
            return
        }
        let targetView = (sourceView === leftPDFView) ? rightPDFView : leftPDFView
        guard let targetView else { return }

        isSyncing = true
        defer { isSyncing = false }
        if abs(targetView.scaleFactor - sourceView.scaleFactor) > 0.01 {
            targetView.scaleFactor = sourceView.scaleFactor
        }
    }

    @objc private func handleScrollBoundsChanged(_ notification: Notification) {
        guard !isSyncing,
              let clipView = notification.object as? NSClipView,
              let left = leftPDFView,
              let right = rightPDFView,
              let leftScroll = findScrollView(in: left),
              let rightScroll = findScrollView(in: right) else {
            return
        }

        let isLeftSource = (clipView === leftScroll.contentView)
        let srcScroll = isLeftSource ? leftScroll : rightScroll
        let dstScroll = isLeftSource ? rightScroll : leftScroll

        guard let srcDocView = srcScroll.documentView,
              let dstDocView = dstScroll.documentView else {
            return
        }

        let srcMaxY = max(1.0, srcDocView.bounds.height - srcScroll.contentView.bounds.height)
        let dstMaxY = max(1.0, dstDocView.bounds.height - dstScroll.contentView.bounds.height)
        let ratioY = srcScroll.contentView.bounds.origin.y / srcMaxY

        isSyncing = true
        defer { isSyncing = false }
        var dstOrigin = dstScroll.contentView.bounds.origin
        dstOrigin.y = ratioY * dstMaxY
        dstScroll.contentView.scroll(to: dstOrigin)
        dstScroll.reflectScrolledClipView(dstScroll.contentView)
    }
}

public struct BridgedPDFView: NSViewRepresentable {
    public let url: URL?
    public let isLeftPane: Bool
    public let syncCoordinator: PDFSyncCoordinator

    public init(url: URL?, isLeftPane: Bool, syncCoordinator: PDFSyncCoordinator) {
        self.url = url
        self.isLeftPane = isLeftPane
        self.syncCoordinator = syncCoordinator
    }

    public func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        if let url {
            pdfView.document = PDFDocument(url: url)
        }
        DispatchQueue.main.async {
            if isLeftPane {
                syncCoordinator.leftPDFView = pdfView
            } else {
                syncCoordinator.rightPDFView = pdfView
            }
            if let l = syncCoordinator.leftPDFView, let r = syncCoordinator.rightPDFView {
                syncCoordinator.attach(left: l, right: r)
            }
        }
        return pdfView
    }

    public func updateNSView(_ pdfView: PDFView, context: Context) {
        if let url {
            if pdfView.document?.documentURL != url {
                pdfView.document = PDFDocument(url: url)
                DispatchQueue.main.async {
                    if let l = syncCoordinator.leftPDFView, let r = syncCoordinator.rightPDFView {
                        syncCoordinator.attach(left: l, right: r)
                    }
                }
            }
        } else {
            pdfView.document = nil
        }
    }
}

/// 对照阅读器主视图：原文 / 译文 并排，支持模式切换与同步滚动
public struct SynchronizedPDFComparisonView: View {
    @Bindable var appState: AppState
    @State private var syncCoordinator = PDFSyncCoordinator()

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - 1. 主阅读画布
            GeometryReader { geo in
                switch appState.readerViewMode {
                case .sideBySide:
                    HStack(spacing: 0) {
                        // 左窗格：原文
                        VStack(spacing: 0) {
                            paneCaptionStrip(
                                badge: LocalizedStringResource("原文", comment: "Pane badge"),
                                fileName: appState.sourcePDFURL?.lastPathComponent ?? "",
                                isAccent: false
                            )
                            Divider()
                            BridgedPDFView(
                                url: appState.sourcePDFURL,
                                isLeftPane: true,
                                syncCoordinator: syncCoordinator
                            )
                        }
                        .frame(width: geo.size.width * 0.5)

                        Divider()

                        // 右窗格：译文
                        VStack(spacing: 0) {
                            paneCaptionStrip(
                                badge: LocalizedStringResource("译文", comment: "Pane badge"),
                                fileName: appState.monoPDFURL?.lastPathComponent ?? "译文生成中…",
                                isAccent: true
                            )
                            Divider()
                            translatedPaneContent
                        }
                        .frame(width: geo.size.width * 0.5)
                    }

                case .translatedOnly:
                    VStack(spacing: 0) {
                        paneCaptionStrip(
                            badge: LocalizedStringResource("译文视图", comment: "Pane badge"),
                            fileName: appState.monoPDFURL?.lastPathComponent ?? "",
                            isAccent: true
                        )
                        Divider()
                        translatedPaneContent
                    }

                case .originalOnly:
                    VStack(spacing: 0) {
                        paneCaptionStrip(
                            badge: LocalizedStringResource("原文视图", comment: "Pane badge"),
                            fileName: appState.sourcePDFURL?.lastPathComponent ?? "",
                            isAccent: false
                        )
                        Divider()
                        BridgedPDFView(
                            url: appState.sourcePDFURL,
                            isLeftPane: true,
                            syncCoordinator: syncCoordinator
                        )
                    }
                }
            }

            Divider()

            // MARK: - 2. 底部状态栏
            minimalStatusFooterBar
        }
        .onAppear {
            syncCoordinator.onPageChanged = { idx in
                appState.currentPageIndex = idx
            }
        }
    }

    // MARK: - 面板顶部标题条

    private func paneCaptionStrip(badge: LocalizedStringResource, fileName: String, isAccent: Bool) -> some View {
        HStack(spacing: DesignSpacing.sm) {
            Circle()
                .fill(isAccent ? DesignColor.brand : DesignColor.textTertiary)
                .frame(width: 6, height: 6)
            Text(badge)
                .font(DesignType.captionMedium)
                .foregroundStyle(isAccent ? DesignColor.textPrimary : DesignColor.textSecondary)
            if !fileName.isEmpty {
                Text("· \(fileName)")
                    .font(DesignType.smallCaption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, DesignSpacing.md)
        .frame(height: 24)
        .background(DesignColor.underPage.opacity(0.35))
    }

    // MARK: - 译文窗格内容（翻译中占位或 PDF 内容）

    @ViewBuilder
    private var translatedPaneContent: some View {
        if let monoURL = appState.monoPDFURL {
            BridgedPDFView(
                url: monoURL,
                isLeftPane: false,
                syncCoordinator: syncCoordinator
            )
        } else {
            VStack(spacing: DesignSpacing.lg) {
                ProgressView()
                    .controlSize(.regular)
                    .scaleEffect(0.9)

                VStack(spacing: DesignSpacing.xs) {
                    Text(LocalizedStringResource("\(appState.currentStage.rawValue)（第 \(max(1, appState.progressPage)) / \(max(1, appState.progressTotalPages)) 页）", comment: "Progress text"))
                        .font(DesignType.bodyMedium)
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(LocalizedStringResource("正在为您保留公式、矢量图表与双栏版式生成译文…", comment: "Placeholder text"))
                        .font(DesignType.caption)
                        .foregroundStyle(DesignColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignColor.underPage)
        }
    }

    // MARK: - 底部状态栏（极简 Finder 风格）

    private var minimalStatusFooterBar: some View {
        let totalPages = appState.lastCompletionReport?.totalPages ?? max(1, appState.progressTotalPages)

        return HStack(spacing: DesignSpacing.lg) {
            // 左侧：任务状态
            statusGroup

            Spacer()

            // 中间：页码指示
            pageIndicator(totalPages: totalPages)

            Spacer()

            // 右侧：操作按钮
            actionGroup
        }
        .padding(.horizontal, DesignSpacing.lg)
        .frame(height: 32)
        .background(DesignColor.backgroundWindow)
        .overlay(
            Divider().padding(.horizontal, -DesignSpacing.lg),
            alignment: .top
        )
    }

    @ViewBuilder
    private var statusGroup: some View {
        if appState.phase == .translating {
            HStack(spacing: DesignSpacing.md) {
                ProgressView(value: appState.progressFraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                    .controlSize(.small)

                Text(LocalizedStringResource("\(appState.currentStage.rawValue) · 第 \(max(1, appState.progressPage))/\(max(1, appState.progressTotalPages)) 页", comment: "Status text"))
                    .font(DesignType.captionMedium)
                    .foregroundStyle(DesignColor.textSecondary)

                if appState.estimatedCharacters > 0 {
                    Text(LocalizedStringResource("(\(appState.estimatedCharacters) 字符)", comment: "Character count"))
                        .font(DesignType.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
        } else if appState.phase == .failed {
            HStack(spacing: DesignSpacing.md) {
                StatusDot(color: DesignColor.error)
                Text(LocalizedStringResource("翻译失败", comment: "Status text"))
                    .font(DesignType.captionMedium)
                    .foregroundStyle(DesignColor.error)
            }
        } else if let report = appState.lastCompletionReport {
            HStack(spacing: DesignSpacing.md) {
                StatusDot(color: DesignColor.success)
                Text(LocalizedStringResource("已完成 · 共 \(report.totalPages) 页 · 耗时 \(String(format: "%.1f", report.elapsedSeconds)) 秒", comment: "Status text"))
                    .font(DesignType.captionMedium)
                    .foregroundStyle(DesignColor.textSecondary)

                if !report.skippedScannedPages.isEmpty {
                    Text(LocalizedStringResource("· 已跳过扫描页：\(report.skippedScannedPages.map { String($0 + 1) }.joined(separator: ","))", comment: "Skipped pages notice"))
                        .font(DesignType.caption)
                        .foregroundStyle(DesignColor.warning)
                }
            }
        }
    }

    @ViewBuilder
    private func pageIndicator(totalPages: Int) -> some View {
        Text(LocalizedStringResource("第 \(appState.currentPageIndex + 1) / \(totalPages) 页", comment: "Page indicator"))
            .font(DesignType.captionMedium)
            .monospacedDigit()
            .foregroundStyle(DesignColor.textSecondary)
    }

    @ViewBuilder
    private var actionGroup: some View {
        if appState.phase == .translating {
            Button(LocalizedStringResource("取消翻译", comment: "Button label")) {
                appState.cancelCurrentJob()
            }
            .buttonStyle(.plain)
            .font(DesignType.buttonSmall)
            .foregroundStyle(DesignColor.error)
            .pressable()
        } else if appState.phase == .failed {
            Button(LocalizedStringResource("重试", comment: "Button label")) {
                if let src = appState.sourcePDFURL {
                    appState.startTranslation(for: src)
                }
            }
            .buttonStyle(.plain)
            .font(DesignType.buttonSmall)
            .foregroundStyle(DesignColor.brand)
            .pressable()
        } else {
            Button {
                appState.revealInFinder()
            } label: {
                HStack(spacing: DesignSpacing.xs) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(LocalizedStringResource("在访达中定位输出文件", comment: "Button label"))
                        .font(DesignType.captionMedium)
                }
                .foregroundStyle(DesignColor.textSecondary)
            }
            .buttonStyle(.plain)
            .pressable()
            .help(LocalizedStringResource("在 Finder 中查看自动生成的 -zh.pdf 与 -dual.pdf", comment: "Tooltip"))
        }
    }
}
