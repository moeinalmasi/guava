#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_VERSION="1.0.0"
BUILD_NUMBER="1"

# Machine/user-specific values live in the gitignored local.config (see local.config.example).
BUNDLE_ID="com.example.guava"
COPYRIGHT=""
DEFAULT_HIDDEN_APPS=()
if [ -f "$SCRIPT_DIR/local.config" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/local.config"
fi

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

HIDDEN_APPS_XML=""
for app in "${DEFAULT_HIDDEN_APPS[@]}"; do
    HIDDEN_APPS_XML+="        <string>$(xml_escape "$app")</string>"$'\n'
done

echo "Building Guava $APP_VERSION..."
swift build -c release 2>&1

APP_DIR="$SCRIPT_DIR/build/Guava.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/Guava "$APP_DIR/Contents/MacOS/Guava"
cp "$SCRIPT_DIR/Guava.entitlements" "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp "$SCRIPT_DIR/build/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true

cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Guava</string>
    <key>CFBundleIdentifier</key>
    <string>$(xml_escape "$BUNDLE_ID")</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Guava</string>
    <key>CFBundleDisplayName</key>
    <string>Guava</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>NSHumanReadableCopyright</key>
    <string>$(xml_escape "$COPYRIGHT")</string>
    <key>GuavaDefaultHiddenApps</key>
    <array>
${HIDDEN_APPS_XML}    </array>
</dict>
</plist>
EOF

echo "✅ Built: $APP_DIR"
echo "Run with: open $APP_DIR"
