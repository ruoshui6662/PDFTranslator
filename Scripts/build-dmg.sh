#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/build-app.sh" release

DMG_STAGING="$ROOT_DIR/build/dmg-staging"
DMG_OUTPUT="$ROOT_DIR/build/PDFTranslator-0.0.1.dmg"

rm -rf "$DMG_STAGING" "$DMG_OUTPUT"
mkdir -p "$DMG_STAGING"

cp -R "$ROOT_DIR/build/PDFTranslator.app" "$DMG_STAGING/PDFTranslator.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "PDFTranslator 1.0" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_STAGING"
echo "Successfully created release DMG at: $DMG_OUTPUT"
