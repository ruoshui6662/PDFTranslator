#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/build-app.sh" release

DMG_STAGING="$ROOT_DIR/build/dmg-staging"
export DMG_STAGING
DMG_OUTPUT="$ROOT_DIR/build/PDFTranslator-1.0.dmg"

rm -rf "$DMG_STAGING" "$DMG_OUTPUT"
mkdir -p "$DMG_STAGING"

# Copy app to staging
cp -R "$ROOT_DIR/build/PDFTranslator.app" "$DMG_STAGING/PDFTranslator.app"

# Create Applications symlink (standard macOS install pattern)
ln -s /Applications "$DMG_STAGING/Applications"

# Create a .DS_Store file that instructs Finder to show a compact window
# when this DMG is mounted
python3 << 'PYTHON_EOF'
import struct
import os

ds_path = os.environ['DMG_STAGING'] + '/.DS_Store'

def create_ds_store(path):
    """Create a .DS_Store file with custom window settings for a compact install window."""

    # Start with the magic bytes
    data = bytearray(b'Bud1')
    data += struct.pack('>I', 1)  # Version

    # Page table (1 page)
    data += struct.pack('>I', 1)  # Page count
    data += struct.pack('>I', 4096)  # Page 0 offset
    data += struct.pack('>I', 0)  # No next page

    # Pad to page boundary
    while len(data) < 4096:
        data += b'\x00'

    # Page 0 header
    data += struct.pack('>I', 0)  # Page number
    data += struct.pack('>I', 0)  # Reserved
    data += struct.pack('>H', 0)  # Unknown
    data += struct.pack('>I', 2)  # Entry count

    # Add DSWindowRect entry (window position and size: left, top, right, bottom)
    # Position: (100, 100), Size: (520, 360) -> right=620, bottom=460
    window_rect_data = struct.pack('>4d', 100.0, 100.0, 620.0, 460.0)
    window_hash = 0xDEADBEEF
    window_offset = len(data)
    window_entry = struct.pack('>IIII', window_hash, window_offset, 0x0A, len(window_rect_data))
    data += window_entry + window_rect_data

    # Add icon position for PDFTranslator.app
    app_pos_data = struct.pack('>2d', 120.0, 380.0)
    app_hash = 0x12345678
    app_offset = len(data)
    app_entry = struct.pack('>IIII', app_hash, app_offset, 0x0A, len(app_pos_data))
    data += app_entry + app_pos_data

    # Pad to 16-byte alignment
    while len(data) % 16 != 0:
        data += b'\x00'

    # Write to file
    with open(path, 'wb') as f:
        f.write(data)

    print(f'Created .DS_Store at {path} ({len(data)} bytes)')

create_ds_store(ds_path)
PYTHON_EOF

# Create the DMG with appropriate size
hdiutil create \
    -volname "墨译" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_STAGING"

echo "Successfully created release DMG at: $DMG_OUTPUT"
echo ""
echo "DMG details:"
ls -lh "$DMG_OUTPUT"
echo ""
echo "To install:"
echo "  1. Double-click the DMG file to mount it"
echo "  2. Drag PDFTranslator.app to the Applications folder"
echo "  3. Eject the DMG"
