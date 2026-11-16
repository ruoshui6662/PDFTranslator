import SwiftUI
import AppKit

// MARK: - Design Tokens (Unified visual language)

// 统一的色彩体系：参考 macOS 系统色调 + 精心调校的品牌色
enum DesignColor {
    // 品牌主色（蓝调系，更柔和，与系统蓝不冲突）
    static let brand = Color.accentColor

    // 背景层级
    static let backgroundWindow = Color(nsColor: .windowBackgroundColor)
    static let backgroundApp = Color(nsColor: .controlBackgroundColor)
    static let backgroundElevated = Color(nsColor: .controlBackgroundColor).opacity(0.65)
    static let backgroundInput = Color(nsColor: .textBackgroundColor)
    static let underPage = Color(nsColor: .underPageBackgroundColor)

    // 表面与卡片
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardHover = Color(nsColor: .controlBackgroundColor).opacity(0.85)
    static let cardPressed = Color(nsColor: .controlBackgroundColor).opacity(0.75)

    // 边框与分割线
    static let hairline = Color.primary.opacity(0.08)
    static let border = Color.primary.opacity(0.12)
    static let borderFocus = Color.accentColor.opacity(0.5)

    // 文字层级
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.6)

    // 状态色
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
}

// MARK: - 间距

enum DesignSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - 圆角

enum DesignRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 14
    static let xxl: CGFloat = 16
}

// MARK: - 字体规模

enum DesignType {
    // 标题
    static let title = Font.system(size: 20, weight: .semibold, design: .default)
    static let subtitle = Font.system(size: 17, weight: .medium, design: .default)

    // 正文
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let bodyMedium = Font.system(size: 13, weight: .medium, design: .default)

    // 辅助文字
    static let caption = Font.system(size: 11, weight: .regular, design: .default)
    static let captionMedium = Font.system(size: 11, weight: .medium, design: .default)
    static let smallCaption = Font.system(size: 10, weight: .medium, design: .default)

    // 按钮文字
    static let button = Font.system(size: 13.5, weight: .medium, design: .default)
    static let buttonSmall = Font.system(size: 12, weight: .medium, design: .default)
}

// MARK: - 动画

enum DesignAnimation {
    static let quick = Animation.easeInOut(duration: 0.15)
    static let smooth = Animation.easeInOut(duration: 0.25)
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
}

// MARK: - 阴影

enum DesignShadow {
    static let card = Color.black.opacity(0.06)
    static let elevated = Color.black.opacity(0.10)
}

// MARK: - 可复用视图修饰符

extension View {
    /// 卡片容器：用于重要内容块，带轻微阴影和圆角边框
    func cardStyle(cornerRadius: CGFloat = DesignRadius.lg) -> some View {
        self
            .background(DesignColor.card)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(DesignColor.border, lineWidth: 1)
            )
            .shadow(color: DesignShadow.card, radius: 8, x: 0, y: 2)
    }

    /// 输入框容器：用于文本输入区域
    func inputContainerStyle() -> some View {
        self
            .background(DesignColor.backgroundInput)
            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .stroke(DesignColor.hairline, lineWidth: 1)
            )
    }

    /// 次要按钮样式：文字 + 浅色背景 + 细边框
    func secondaryButtonStyle(width: CGFloat? = nil, height: CGFloat = 32) -> some View {
        self
            .font(DesignType.buttonSmall)
            .foregroundStyle(DesignColor.textPrimary)
            .frame(width: width, height: height)
            .background(DesignColor.backgroundApp)
            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .stroke(DesignColor.border, lineWidth: 1)
            )
    }

    /// 主按钮样式：填充品牌色
    func primaryButtonStyle(width: CGFloat? = nil, height: CGFloat = 36) -> some View {
        self
            .font(DesignType.button)
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(DesignColor.brand)
            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    /// 顶栏控件样式：统一高度、圆角、悬停反馈
    func toolbarControlStyle(prominent: Bool = false, isDisabled: Bool = false) -> some View {
        self
            .font(DesignType.buttonSmall)
            .foregroundStyle(
                isDisabled ? DesignColor.textSecondary.opacity(0.5)
                    : (prominent ? .white : DesignColor.textPrimary)
            )
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(
                        prominent
                            ? (isDisabled ? DesignColor.brand.opacity(0.35) : DesignColor.brand)
                            : DesignColor.backgroundApp
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .strokeBorder(
                        prominent ? Color.clear : DesignColor.border,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
    }

    /// 顶栏图标按钮样式：正方形，无文字
    func toolbarIconStyle(prominent: Bool = false, isDisabled: Bool = false) -> some View {
        self
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(
                isDisabled ? DesignColor.textSecondary.opacity(0.45)
                    : (prominent ? .white : DesignColor.textPrimary)
            )
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(
                        prominent
                            ? (isDisabled ? DesignColor.brand.opacity(0.35) : DesignColor.brand)
                            : DesignColor.backgroundApp
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .strokeBorder(
                        prominent ? Color.clear : DesignColor.border,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
    }

    /// 微交互：按下时轻微缩放
    func pressable() -> some View {
        self.buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
    }
}

// MARK: - 状态指示小圆点

struct StatusDot: View {
    let color: Color
    let size: CGFloat

    init(color: Color = DesignColor.success, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}
