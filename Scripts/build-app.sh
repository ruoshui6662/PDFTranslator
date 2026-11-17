#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-release}"
echo "Building PDFTranslatorApp ($CONFIG)..."
export CLANG_MODULE_CACHE_PATH="/tmp/clang-module-cache"
swift build --build-system native --disable-sandbox --cache-path /tmp/swiftpm-cache -c "$CONFIG" --product PDFTranslatorApp

BIN_DIR="$(swift build --build-system native --disable-sandbox --cache-path /tmp/swiftpm-cache -c "$CONFIG" --show-bin-path)"
APP_BUNDLE="$ROOT_DIR/build/PDFTranslator.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"

cp "$BIN_DIR/PDFTranslatorApp" "$APP_BUNDLE/Contents/MacOS/PDFTranslatorApp"
cp "$ROOT_DIR/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy PDFium dylib if available
if [ -f "$ROOT_DIR/Packages/CPDFium/PDFium.xcframework/macos-arm64/libpdfium.dylib" ]; then
    cp "$ROOT_DIR/Packages/CPDFium/PDFium.xcframework/macos-arm64/libpdfium.dylib" "$APP_BUNDLE/Contents/Frameworks/libpdfium.dylib"
    codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/libpdfium.dylib"
fi

# Copy License files
if [ -f "$ROOT_DIR/Packages/CPDFium/LICENSE" ]; then
    cp "$ROOT_DIR/Packages/CPDFium/LICENSE" "$APP_BUNDLE/Contents/Resources/PDFium-LICENSE.txt"
fi

# Copy Localizable.xcstrings into zh-Hans.lproj
if [ -f "$ROOT_DIR/App/Resources/Localizable.xcstrings" ]; then
    cp "$ROOT_DIR/App/Resources/Localizable.xcstrings" "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj/Localizable.xcstrings"
fi

# Copy app icon. macOS resolves CFBundleIconFile against the .icns file (an .iconset
# bundle is only an iconutil intermediate and renders as a blank image), so the plist
# must keep pointing at "AppIcon".
if [ -f "$ROOT_DIR/App/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/App/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

    # Update Info.plist to reference the icns file
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons dict" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon dict" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFile AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

# Sign app bundle
codesign --force --sign - "$APP_BUNDLE"

# Avoid polluting LaunchServices with a second registration for the same bundle id.
# A build-directory copy can otherwise become the app Launchpad resolves, making the
# real /Applications install disappear from the system app menu.
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREG" -u "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Successfully built macOS app bundle at: $APP_BUNDLE"
