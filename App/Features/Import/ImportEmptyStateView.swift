import AppKit
import SwiftUI
import PDFTranslateKit
import UniformTypeIdentifiers

/// 欢迎空状态页：拖放、链接导入、最近文档
public struct ImportEmptyStateView: View {
    @Bindable var appState: AppState
    @State private var isDropTargeted: Bool = false
    @State private var isHoveringPrimary: Bool = false
    @State private var isHoveringSecondary: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: DesignSpacing.xl) {
                // MARK: - 1. 拖放 Hero Card
                VStack(spacing: DesignSpacing.lg) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                            .fill(DesignColor.brand.opacity(0.10))
                            .frame(width: 56, height: 56)

                        Image(systemName: "doc.viewfinder.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(DesignColor.brand)
                            .symbolEffect(
                                .bounce,
                                value: isDropTargeted
                            )
                    }

                    VStack(spacing: DesignSpacing.sm) {
                        Text(isDropTargeted ? LocalizedStringResource("松开即可开始翻译", comment: "Drop target text") : LocalizedStringResource("拖入 PDF 文档，开始双语对照阅读", comment: "Hero title"))
                            .font(DesignType.title)
                            .foregroundStyle(isDropTargeted ? DesignColor.brand : DesignColor.textPrimary)

                        Text(LocalizedStringResource("原文件永不修改 · 自动保留数学公式、矢量图表与双栏学术排版", comment: "Hero subtitle"))
                            .font(DesignType.caption)
                            .foregroundStyle(DesignColor.textSecondary)
                    }

                    HStack(spacing: DesignSpacing.md) {
                        Button {
                            appState.isShowingFileImporter = true
                        } label: {
                            HStack(spacing: DesignSpacing.xs) {
                                Image(systemName: "folder.fill.badge.plus")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(LocalizedStringResource("选择本地 PDF 文件", comment: "Button label"))
                                    .font(DesignType.buttonSmall)
                            }
                            .foregroundStyle(.white)
                            .frame(width: 200, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                    .fill(DesignColor.brand)
                            )
                            .scaleEffect(isHoveringPrimary ? 0.98 : 1.0)
                            .animation(DesignAnimation.quick, value: isHoveringPrimary)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringPrimary = $0 }
                    }
                    .padding(.top, DesignSpacing.xs)
                }
                .frame(maxWidth: 640)
                .padding(.vertical, DesignSpacing.xxl)
                .padding(.horizontal, DesignSpacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                        .fill(isDropTargeted ? DesignColor.brand.opacity(0.06) : DesignColor.backgroundApp)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? DesignColor.brand : DesignColor.hairline,
                            style: StrokeStyle(
                                lineWidth: isDropTargeted ? 2 : 1,
                                dash: isDropTargeted ? [8, 5] : []
                            )
                        )
                )
                .dropDestination(for: URL.self) { urls, _ in
                    guard let first = urls.first else { return false }
                    appState.handleIncomingURL(first)
                    return true
                } isTargeted: { targeted in
                    withAnimation(DesignAnimation.smooth) {
                        isDropTargeted = targeted
                    }
                }

                // MARK: - 2. 链接输入区
                HStack(spacing: DesignSpacing.sm) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignColor.textSecondary)

                    TextField("粘贴 arXiv 或 PDF 链接（例如 https://arxiv.org/abs/2311.09735）", text: $appState.urlInputString)
                        .textFieldStyle(.plain)
                        .font(DesignType.body)
                        .onSubmit {
                            appState.submitURLInput()
                        }

                    if !appState.urlInputString.isEmpty {
                        Button {
                            appState.urlInputString = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DesignColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .pressable()
                    }

                    Button {
                        if let pasted = NSPasteboard.general.string(forType: .string) {
                            appState.urlInputString = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text(LocalizedStringResource("粘贴", comment: "Button label"))
                            .font(DesignType.buttonSmall)
                            .frame(width: 56, height: 32)
                    }
                    .secondaryButtonStyle(width: 56, height: 32)
                    .pressable()
                    .onHover { hovering in
                        // 可选：添加悬停反馈
                        _ = hovering
                    }

                    let linkEmpty = appState.urlInputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        appState.submitURLInput()
                    } label: {
                        Text(LocalizedStringResource("翻译链接", comment: "Button label"))
                            .font(DesignType.buttonSmall)
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 32)
                    }
                    .primaryButtonStyle(width: 80, height: 32)
                    .disabled(linkEmpty)
                    .pressable()
                    .opacity(linkEmpty ? 0.45 : 1.0)
                    .animation(DesignAnimation.quick, value: linkEmpty)
                }
                .padding(.horizontal, DesignSpacing.md)
                .padding(.vertical, DesignSpacing.md)
                .frame(maxWidth: 640)
                .background(DesignColor.backgroundInput)
                .clipShape(RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                        .stroke(DesignColor.hairline, lineWidth: 1)
                )

                // MARK: - 3. 最近文档
                if !appState.recentDocuments.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSpacing.md) {
                        HStack {
                            Text(LocalizedStringResource("最近文档", comment: "Section title"))
                                .font(DesignType.captionMedium)
                                .foregroundStyle(DesignColor.textSecondary)
                            Spacer()
                            Button(LocalizedStringResource("清空", comment: "Button label")) {
                                appState.clearRecentDocuments()
                            }
                            .buttonStyle(.plain)
                            .font(DesignType.smallCaption)
                            .foregroundStyle(DesignColor.textSecondary)
                        }
                        .padding(.horizontal, DesignSpacing.sm)

                        VStack(spacing: DesignSpacing.sm) {
                            ForEach(appState.recentDocuments.prefix(6)) { doc in
                                recentDocumentRow(doc)
                            }
                        }
                    }
                    .frame(maxWidth: 640)
                }
            }
            .padding(.horizontal, DesignSpacing.lg)
            .padding(.vertical, DesignSpacing.xl)
            .frame(maxWidth: .infinity)
        }
        .background(DesignColor.backgroundWindow)
    }

    // MARK: - 最近文档行

    private func recentDocumentRow(_ doc: RecentDocumentRecord) -> some View {
        HStack(spacing: DesignSpacing.md) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 16))
                .foregroundStyle(DesignColor.brand)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                        .fill(DesignColor.brand.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                Text(doc.fileName)
                    .font(DesignType.bodyMedium)
                    .lineLimit(1)
                    .foregroundStyle(DesignColor.textPrimary)
                Text("\(doc.pageCount) 页 · \(doc.translatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(DesignType.smallCaption)
                    .foregroundStyle(DesignColor.textSecondary)
            }

            Spacer()

            Button {
                appState.revealRecentRecordInFinder(doc)
            } label: {
                Text("访达定位")
                    .font(DesignType.buttonSmall)
                    .frame(width: 80, height: 28)
            }
            .secondaryButtonStyle(width: 80, height: 28)
            .pressable()

            Button {
                appState.openRecentRecord(doc)
            } label: {
                Text("打开阅读")
                    .font(DesignType.buttonSmall)
                    .frame(width: 80, height: 28)
                    .foregroundStyle(DesignColor.brand)
                    .background(DesignColor.brand.opacity(0.10))
            }
            .secondaryButtonStyle(width: 80, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(DesignColor.brand.opacity(0.10))
            )
            .pressable()
        }
        .padding(.horizontal, DesignSpacing.md)
        .padding(.vertical, DesignSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .fill(DesignColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .stroke(DesignColor.hairline, lineWidth: 1)
        )
    }
}
