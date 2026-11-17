#!/bin/zsh
set -euo pipefail

# 修复 Launchpad / 系统「应用程序」菜单中找不到「墨译」的问题。
#
# 症状：App 在 Finder 的 /Applications 中可见、Spotlight 也能搜到，但 Launchpad
# 和系统应用菜单里没有入口。
#
# 原因：macOS 的 LaunchServices 数据库里，同一个 CFBundleIdentifier 会残留多条
# 注册记录（旧副本、废纸篓、已卸载的 DMG 卷、build 目录）。记录数量过多时，
# 系统 API 会解析到错误的 app 路径，Launchpad 因此不显示入口。
#
# 用法：把 PDFTranslator.app 放入 /Applications 后运行：
#   ./Scripts/fix-launchpad.sh

BUNDLE_ID="com.pdftranslator.app"
APP_PATH="/Applications/PDFTranslator.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

if [ ! -d "$APP_PATH" ]; then
    echo "错误：未找到 $APP_PATH，请先把 PDFTranslator.app 放入 /Applications。"
    exit 1
fi

echo "修复 $BUNDLE_ID 的 LaunchServices 注册……"

# 从 lsregister dump 中解析出所有同 bundle id 的 app 路径
OLD_PATHS=$("$LSREG" -dump 2>/dev/null | grep -B50 "identifier: *$BUNDLE_ID" \
    | grep '^path:' \
    | sed 's/^path: *//' \
    | sed 's/ (0x[0-9a-fA-F]*).*$//' \
    | sort -u || true)

UNREGISTERED=0
while IFS= read -r p; do
    [ -z "$p" ] && continue
    # 保留正式的 /Applications 安装
    [ "$p" = "$APP_PATH" ] && continue
    # 只处理 app bundle 路径（排除 HTTPStorages/Caches 等容器目录）
    case "$p" in
        *.app)
            "$LSREG" -u "$p" >/dev/null 2>&1 || true
            UNREGISTERED=$((UNREGISTERED + 1))
            echo "  已注销旧记录: $p"
            ;;
    esac
done <<< "$OLD_PATHS"

# 强制重新注册正式安装
"$LSREG" -f "$APP_PATH" >/dev/null 2>&1 || true

# 重启 Dock 让 Launchpad 重建缓存
killall Dock >/dev/null 2>&1 || true

echo "完成：已注销 $UNREGISTERED 条冲突记录，并重新注册 $APP_PATH"
echo "如果 Launchpad 仍未刷新，请注销并重新登录 macOS。"
