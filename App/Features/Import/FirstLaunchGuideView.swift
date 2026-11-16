import SwiftUI
import PDFTranslateKit

/// 首次安装引导视图：小窗口，直接引导用户拖入 PDF 或打开文件
public struct FirstLaunchGuideView: View {
    @Bindable var appState: AppState
    @State private var isDropTargeted: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶栏（简化版，仅标题 + 关闭区域）
            HStack(spacing: DesignSpacing.md) {
                Image(systemName: "drop")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignColor.brand)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                            .fill(DesignColor.brand.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                    Text("墨译")
                        .font(DesignType.bodyMedium)
                        .foregroundStyle(DesignColor.textPrimary)
                    Text("PDF 保版式双语翻译")
                        .font(DesignType.smallCaption)
                        .foregroundStyle(DesignColor.textSecondary)
                }
                Spacer()

                Button {
                    // 标记首次启动已完成，进入主窗口
                    appState.isFirstLaunch = false
                    // 将窗口调整为主内容尺寸
                    DispatchQueue.main.async {
                        if let window = NSApplication.shared.keyWindow
                            ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                            ?? NSApplication.shared.windows.first {
                            window.setContentSize(NSSize(width: 980, height: 660))
                            window.minSize = NSSize(width: 700, height: 500)
                            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                        }
                    }
                } label: {
                    Text(LocalizedStringResource("跳过", comment: "Skip guide button"))
                        .font(DesignType.buttonSmall)
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .pressable()
            }
            .padding(.horizontal, DesignSpacing.md)
            .frame(height: 44)
            .background(DesignColor.backgroundWindow)

            Divider()

            // 主体：拖放 Hero Card
            VStack(spacing: DesignSpacing.lg) {
                VStack(spacing: DesignSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                            .fill(DesignColor.brand.opacity(0.10))
                            .frame(width: 64, height: 64)

                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(DesignColor.brand)
                            .symbolEffect(
                                .bounce,
                                value: isDropTargeted
                            )
                    }

                    VStack(spacing: DesignSpacing.sm) {
                        Text("拖入 PDF 文档，开始翻译")
                            .font(DesignType.title)
                            .foregroundStyle(DesignColor.textPrimary)

                        Text("原文件永不修改 · 自动保留数学公式与双栏学术排版")
                            .font(DesignType.caption)
                            .foregroundStyle(DesignColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                HStack(spacing: DesignSpacing.md) {
                    Button {
                        appState.isFirstLaunch = false
                        appState.isShowingFileImporter = true
                    } label: {
                        HStack(spacing: DesignSpacing.xs) {
                            Image(systemName: "folder.fill.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                            Text(LocalizedStringResource("选择 PDF 文件", comment: "Button label"))
                                .font(DesignType.buttonSmall)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                .fill(DesignColor.brand)
                        )
                    }
                    .buttonStyle(.plain)
                    .pressable()
                }

                Divider()

                HStack(spacing: DesignSpacing.md) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignColor.textSecondary)

                    Text("本应用支持拖入 PDF、粘贴 arXiv 链接、或打开本地文件。")
                        .font(DesignType.caption)
                        .foregroundStyle(DesignColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DesignSpacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, DesignSpacing.lg)
            .background(DesignColor.backgroundWindow)
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                appState.handleIncomingURL(first)
                appState.isFirstLaunch = false
                return true
            } isTargeted: { targeted in
                withAnimation(DesignAnimation.smooth) {
                    isDropTargeted = targeted
                }
            }
        }
        .frame(width: 520, height: 420)
        .background(DesignColor.backgroundWindow)
    }
}
