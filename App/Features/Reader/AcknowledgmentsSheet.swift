import SwiftUI

public struct AcknowledgmentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            // MARK: - Header
            HStack(alignment: .top, spacing: DesignSpacing.md) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DesignColor.brand)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                            .fill(DesignColor.brand.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                    Text(LocalizedStringResource("关于与开源致谢 (Acknowledgments)", comment: "Sheet title"))
                        .font(DesignType.bodyMedium)
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(LocalizedStringResource("墨译 · 墨鸽出品 · 合同号：com.pdftranslator.app", comment: "App branding line"))
                        .font(DesignType.smallCaption)
                        .foregroundStyle(DesignColor.textSecondary)
                }
                Spacer()

                Button(LocalizedStringResource("关闭", comment: "Close button")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .font(DesignType.buttonSmall)
                .foregroundStyle(.white)
                .frame(width: 64, height: 30)
                .background(DesignColor.brand)
                .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                .pressable()
            }

            Divider()

            // MARK: - Privacy statement card
            settingsInfoCard(
                title: LocalizedStringResource("隐私说明", comment: "Card title"),
                body: LocalizedStringResource("本应用仅使用宽松开源许可证（Apache-2.0 / BSD-3-Clause / MIT / SIL OFL）组件，并严格遵循隐私优先原则：不设立中转服务器，不收集任何文档内容。版面检测采用纯规则聚类实现，无需下载外部 AI 模型，全部计算在本地完成。", comment: "Privacy statement body"),
                icon: "lock.shield"
            )

            // MARK: - Third-party licenses
            Text(LocalizedStringResource("第三方开源组件许可证", comment: "Section title"))
                .font(DesignType.captionMedium)
                .foregroundStyle(DesignColor.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpacing.md) {
                    licenseBlock(
                        name: LocalizedStringResource("PDFium (Google / Foxit)", comment: "Library name"),
                        license: LocalizedStringResource("Apache-2.0 / BSD-3-Clause", comment: "License identifier"),
                        copyright: """
                        Copyright 2014 The PDFium Authors. All rights reserved.
                        Redistribution and use in source and binary forms, with or without modification, are permitted provided that the BSD-3-Clause conditions are met.
                        Prebuilt binaries provided by bblanchon/pdfium-binaries (Apache-2.0).
                        """
                    )

                    licenseBlock(
                        name: LocalizedStringResource("Source Han Sans / Source Han Serif (思源黑体 / 思源宋体)", comment: "Font name"),
                        license: LocalizedStringResource("SIL Open Font License 1.1 (OFL-1.1)", comment: "License identifier"),
                        copyright: """
                        Copyright 2014-2024 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'.
                        Licensed under the SIL Open Font License, Version 1.1.
                        """
                    )
                }
                .padding(.vertical, DesignSpacing.xs)
            }

            // MARK: - Inspiration card
            settingsInfoCard(
                title: LocalizedStringResource("架构思路致敬", comment: "Card title"),
                body: LocalizedStringResource("PDFMathTranslate (pdf2zh) 与 BabelDOC 公开论文与文档（零代码拷贝，纯 Swift 6 独立实现）", comment: "Inspiration attribution body"),
                icon: "sparkles"
            )

            Spacer(minLength: DesignSpacing.xl)
        }
        .padding(DesignSpacing.lg)
        .frame(width: 600, height: 560)
    }

    // MARK: - Reusable license card

    private func licenseBlock(name: LocalizedStringResource, license: LocalizedStringResource, copyright: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
            HStack(spacing: DesignSpacing.md) {
                Text(name)
                    .font(DesignType.bodyMedium)
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
                Text(license)
                    .font(DesignType.smallCaption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSpacing.md)
                    .padding(.vertical, DesignSpacing.xs)
                    .background(
                        Capsule()
                            .fill(DesignColor.brand.opacity(0.95))
                    )
            }

            Text(copyright)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(DesignColor.textSecondary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .fill(DesignColor.backgroundApp)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .strokeBorder(DesignColor.border, lineWidth: 1)
        )
    }

    // MARK: - Reusable info card

    private func settingsInfoCard(title: LocalizedStringResource, body: LocalizedStringResource, icon: String) -> some View {
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
                        .font(DesignType.captionMedium)
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(body)
                        .font(DesignType.caption)
                        .foregroundStyle(DesignColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .padding(DesignSpacing.md)
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
