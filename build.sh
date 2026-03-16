#!/bin/bash

# Configuration
APP_NAME="MagicMiddle"
SWIFT_SOURCE="MagicMiddle.swift"
DMG_NAME="${APP_NAME}.dmg"
BUILD_DIR="${APP_NAME}_build"
ICONS_DIR="assets/icons"
STATUS_ICONS_DIR="assets/statusicons"
# Icon source file
ICON_DARK="${ICONS_DIR}/Icons-macOS-Dark-1024x1024@1x.png"

# Logical sizes and scales for a macOS app icon
ICON_SIZES=("16 1" "16 2" "32 1" "32 2" "128 1" "128 2" "256 1" "256 2" "512 1" "512 2")

if [ ! -f "$SWIFT_SOURCE" ]; then
    echo "Error: $SWIFT_SOURCE not found in the current directory."
    exit 1
fi

echo "🚀 Starting Build Process for $APP_NAME..."

# 1. Clean up previous builds
rm -rf "${APP_NAME}.app" "$DMG_NAME" "$BUILD_DIR"

# 2. Create App Bundle Directory Structure
echo "📂 Creating App Bundle Structure..."
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

# 3. Copy status bar icons
echo "🖼️ Copying status bar icons..."
cp "${STATUS_ICONS_DIR}/mmstatus@1x.png" "${APP_NAME}.app/Contents/Resources/mmstatus.png"
cp "${STATUS_ICONS_DIR}/mmstatus@2x.png" "${APP_NAME}.app/Contents/Resources/mmstatus@2x.png"

# 4. Generate App Icon
if [ ! -f "$ICON_DARK" ]; then
    echo "⚠️  Icon source not found at $ICON_DARK — skipping icon."
    ICON_PLIST_KEY=""
else
    echo "🎨 Generating App Icon..."
    ICONSET_DIR="${APP_NAME}.iconset"
    mkdir -p "$ICONSET_DIR"
    for entry in "${ICON_SIZES[@]}"; do
        base=$(echo "$entry" | awk '{print $1}')
        scale=$(echo "$entry" | awk '{print $2}')
        px=$(( base * scale ))
        [ "$scale" -eq 1 ] && name="icon_${base}x${base}.png" || name="icon_${base}x${base}@${scale}x.png"
        sips -z "$px" "$px" "$ICON_DARK" --out "${ICONSET_DIR}/${name}" > /dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "${APP_NAME}.app/Contents/Resources/${APP_NAME}.icns"
    rm -rf "$ICONSET_DIR"
    ICON_PLIST_KEY="
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>"
fi

# 5. Compile the Swift Code
echo "🔨 Compiling Swift Code..."
swiftc "$SWIFT_SOURCE" -o "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed."
    exit 1
fi

# 6. Generate Info.plist
echo "📝 Generating Info.plist..."
cat > "${APP_NAME}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.opensource.${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>${ICON_PLIST_KEY}
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 7. Code Signing
echo "🔏 Signing the Application..."
xattr -cr "${APP_NAME}.app"
codesign --force --deep --sign - "${APP_NAME}.app"

# 8. Prepare DMG staging
echo "🔗 Creating Applications shortcut..."
mkdir "$BUILD_DIR"
cp -r "${APP_NAME}.app" "$BUILD_DIR/"
ln -s /Applications "$BUILD_DIR/Applications"

# 9. Package the DMG
echo "📦 Bundling DMG..."
hdiutil create -volname "${APP_NAME}" -srcfolder "$BUILD_DIR" -ov -format UDZO "$DMG_NAME"

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "✅ Build Complete!"
